#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  local reason="$3"
  grep -Fq -- "${literal}" "${file}" || fail "${reason} (${file})"
}

require_regex() {
  local file="$1"
  local pattern="$2"
  local reason="$3"
  grep -Eiq -- "${pattern}" "${file}" || fail "${reason} (${file})"
}

remote_dir=lib/remote-browser
caddyfile="${remote_dir}/Caddyfile"
credentials="${remote_dir}/prepare-credentials.sh"
injector="${remote_dir}/inject-instructions.cjs"
playbook="${remote_dir}/browser-playbook.md"
edge_caddyfile="${remote_dir}/edge-compat.caddy"
guest_broker="${remote_dir}/guest-access-broker.py"
guest_proxy="${remote_dir}/guest-session-proxy.cjs"

for file in "${caddyfile}" "${edge_caddyfile}" "${credentials}" "${injector}" \
  "${playbook}" "${guest_broker}" "${guest_proxy}"; do
  [[ -f "${file}" ]] || fail "required file is missing: ${file}"
done

require_literal "${caddyfile}" 'import /run/remote-browser/edge-compat.caddy' \
  'the main gateway must import the generated edge compatibility fragment'
require_regex "${edge_caddyfile}" 'http://:8931' \
  'the private edge MCP compatibility port is missing'
require_regex "${edge_caddyfile}" 'http://:6080' \
  'the private edge noVNC compatibility port is missing'
require_literal "${edge_caddyfile}" 'output discard' \
  'edge compatibility access logs must be disabled'

# Caddy is a route/auth gateway, not another public edge. Its only listener is
# the loopback target selected by Tailscale Serve, and access logs are discarded
# because both compatibility URLs contain password-equivalent material.
require_regex "${caddyfile}" 'http://:8443([[:space:]]|$|\{)' \
  'the gateway must accept the Tailscale HTTPS proxy host on port 8443'
require_regex "${caddyfile}" 'bind[[:space:]]+127\.0\.0\.1' \
  'the gateway must explicitly bind its listener to IPv4 loopback'
require_literal "${caddyfile}" 'output discard' \
  'gateway access logs must be disabled'
if rg -n '(^|[[:space:]])(:80|:443|0\.0\.0\.0|\[::\])([[:space:]]|$|\{)' \
  "${caddyfile}"; then
  fail 'the in-container gateway must not listen on a public or wildcard address'
fi

# MCP has two compatible authentication forms: bearer /mcp and exact
# /<token>/mcp. Both accept protocol-changing POST/DELETE only. Authenticated
# GET must be 405 rather than becoming an accidental streaming/log endpoint.
require_regex "${caddyfile}" 'path[[:space:]]+/mcp([[:space:]]|$)' \
  'the canonical MCP route is missing'
require_regex "${caddyfile}" 'Authorization.*Bearer.*REMOTE_BROWSER_MCP_TOKEN' \
  'canonical MCP requests must require the bearer token'
require_regex "${caddyfile}" 'REMOTE_BROWSER_MCP_TOKEN.*/mcp|/\{env\.REMOTE_BROWSER_MCP_TOKEN\}/mcp' \
  'the exact token-path compatibility route is missing'
require_regex "${caddyfile}" 'method[[:space:]]+(POST[[:space:]]+DELETE|DELETE[[:space:]]+POST)' \
  'MCP must allow only POST and DELETE'
require_regex "${caddyfile}" 'respond.*405|status.*405' \
  'unsupported authenticated MCP methods must return 405'
require_regex "${caddyfile}" 'reverse_proxy[[:space:]]+127\.0\.0\.2:8932' \
  'MCP must proxy only to the non-forwarded backend'
if rg -n 'reverse_proxy.*(localhost|127\.0\.0\.1):(8932|8931)' \
  "${caddyfile}"; then
  fail 'the MCP backend must not use the Tailscale-forwarded localhost address'
fi

# A noVNC token is exchanged immediately for a clean strict cookie. The query
# token may not survive in Location, response bodies, referrers, or caches.
require_regex "${caddyfile}" 'query[[:space:]]+token=\{env\.REMOTE_BROWSER_LOGIN_TOKEN\}|query[[:space:]]+token.*REMOTE_BROWSER_LOGIN_TOKEN' \
  'the noVNC handoff-token matcher is missing'
require_regex "${caddyfile}" 'Set-Cookie.*remote_chrome_login=' \
  'the noVNC handoff must establish a session cookie'
for attribute in HttpOnly Secure 'SameSite=Strict'; do
  require_literal "${caddyfile}" "${attribute}" \
    "the noVNC session cookie must include ${attribute}"
done
require_regex "${caddyfile}" \
  'redir.*/login/\?autoconnect=1&resize=scale.*303' \
  'a valid token must redirect with HTTP 303 to a clean auto-connect URL'
require_regex "${caddyfile}" 'Cache-Control.*no-store' \
  'token exchange responses must not be cached'
require_regex "${caddyfile}" 'Referrer-Policy.*no-referrer' \
  'token exchange responses must not disclose their referrer'
require_regex "${caddyfile}" 'remote_chrome_login.*REMOTE_BROWSER_LOGIN_TOKEN|REMOTE_BROWSER_LOGIN_TOKEN.*remote_chrome_login' \
  'the clean noVNC route must authenticate the strict session cookie'
require_regex "${caddyfile}" 'basic_auth|basicauth' \
  'noVNC must preserve Basic Auth fallback compatibility'
require_regex "${caddyfile}" 'REMOTE_BROWSER_LOGIN_USERNAME|REMOTE_BROWSER_LOGIN_PASSWORD_HASH' \
  'Basic Auth must use protected configured credentials'
require_regex "${caddyfile}" 'reverse_proxy[[:space:]]+127\.0\.0\.2:6081' \
  'authenticated noVNC HTTP and WebSocket traffic must use the private backend'

# Credentials are stable across image replacement and private at rest. They are
# generated without printing them and are loaded from the persistent home.
require_literal "${credentials}" '/var/lib/codex-desktop-persistent/remote-browser' \
  'remote-browser credentials must live in persistent machine state'
require_literal "${credentials}" 'credentials.env' \
  'gateway credentials must have a stable persistent file'
require_regex "${credentials}" 'install.*-d.*-m[[:space:]]+0700|chmod[[:space:]]+0700' \
  'the credential directory must be mode 0700'
require_regex "${credentials}" 'install.*-m[[:space:]]+0600|chmod[[:space:]]+0600' \
  'credential files must be mode 0600'
require_regex "${credentials}" 'REMOTE_BROWSER_MCP_TOKEN' \
  'a persistent MCP bearer token must be generated'
require_regex "${credentials}" 'REMOTE_BROWSER_LOGIN_TOKEN' \
  'a separate persistent noVNC handoff token must be generated'
require_regex "${credentials}" 'REMOTE_BROWSER_LOGIN_(USERNAME|PASSWORD_HASH)' \
  'persistent Basic Auth fallback credentials must be prepared'
require_regex "${credentials}" '(openssl.*(rand|-hex)|/dev/urandom|node:crypto.*randomBytes)' \
  'tokens must come from an operating-system cryptographic random source'
if rg -n '(^|[^#])(echo|printf).*REMOTE_BROWSER_(MCP|LOGIN|EXTENSION)_(TOKEN|PASSWORD)' \
  "${credentials}" "${remote_dir}/run-gateway.sh" \
  "${remote_dir}/run-playwright-mcp.sh"; then
  fail 'runtime scripts must never print browser-control credentials'
fi

# The two human-handoff tools remain MCP-visible, accept no fields, and return
# only the action/link template. No token or credential value may be included in
# tool descriptions, diagnostic errors, or playbook prose.
for tool in \
  remote_chrome_request_human_intervention \
  get_novnc_link \
  create_temporary_novnc_link \
  revoke_temporary_novnc_link; do
  require_literal "${injector}" "${tool}" \
    "human-handoff tool is missing: ${tool}"
  require_literal "${playbook}" "${tool}" \
    "the browser playbook must explain ${tool}"
done
require_literal "${injector}" 'properties: {}' \
  'human-handoff tools must declare an empty input schema'
require_regex "${injector}" 'additionalProperties[[:space:]]*:[[:space:]]*false' \
  'human-handoff tools must reject arbitrary arguments'
require_regex "${injector}" 'Object\.keys\([^)]*(args|arguments|request)' \
  'human-handoff handlers must actively reject supplied arguments'
if rg -n '(^|[^[:xdigit:]])[[:xdigit:]]{64}([^[:xdigit:]]|$)' \
  "${injector}" "${playbook}"; then
  fail 'handoff tools and instructions must not contain literal credentials'
fi
require_regex "${playbook}" 'accept(s)? no arguments' \
  'the playbook must state the no-argument handoff contract'
require_literal "${playbook}" 'Never clear cookies' \
  'the playbook must preserve the authenticated persistent profile'

# Temporary public access is a separate guest-only trust path. The MCP client
# can request only fixed create/revoke operations over a local Unix socket.
require_literal "${injector}" '/run/remote-browser/guest-control.sock' \
  'guest tools must use only the fixed local control socket'
require_literal "${guest_broker}" 'SO_PEERCRED' \
  'the root broker must verify Unix peer credentials'
require_literal "${guest_broker}" 'PRODUCTION_TTL = 1800.0' \
  'guest access must have a fixed 30-minute production deadline'
require_literal "${guest_broker}" 'GUEST_PORT = 10000' \
  'Funnel must use the dedicated external guest port'
require_literal "${guest_broker}" 'ThreadPoolExecutor' \
  'pdeath-protected guest children need a persistent Linux parent thread'
require_literal "${guest_broker}" 'thread_name_prefix="guest-child-owner"' \
  'guest child ownership must use the dedicated persistent executor'
require_literal "${guest_broker}" 'PROXY_PORT = 8444' \
  'Funnel must target the dedicated local guest proxy'
require_literal "${guest_broker}" '"funnel"' \
  'the broker must use Tailscale Funnel explicitly'
if rg -n -- '--bg|funnel[[:space:]]+reset|"reset"' "${guest_broker}"; then
  fail 'guest access must use foreground Funnel and never reset shared Serve state'
fi
for fixed_endpoint in \
  "listenHost: '127.0.0.1'" \
  'listenPort: 8444' \
  "upstreamHost: '127.0.0.2'" \
  'upstreamPort: 6081'; do
  require_literal "${guest_proxy}" "${fixed_endpoint}" \
    'guest proxy production endpoints must be fixed'
done
require_literal "${guest_proxy}" "const COOKIE_NAME = 'remote_chrome_guest'" \
  'guest access must use a cookie distinct from the permanent login cookie'
require_literal "${guest_proxy}" "parsedUrl.pathname !== '/guest/websockify'" \
  'guest WebSocket upgrades must use the guest-only path'
if rg -n '/mcp|basic_auth|remote_chrome_login' "${guest_proxy}"; then
  fail 'guest proxy must not contain MCP, Basic Auth, or permanent-login routes'
fi

printf 'PASS: remote browser gateway and handoff contracts\n'
