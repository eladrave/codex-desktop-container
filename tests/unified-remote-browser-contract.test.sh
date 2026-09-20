#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "required file is missing: $1"
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
  grep -Eq -- "${pattern}" "${file}" || fail "${reason} (${file})"
}

remote_dir=lib/remote-browser
required_files=(
  "${remote_dir}/Caddyfile"
  "${remote_dir}/browser-owner.cjs"
  "${remote_dir}/mcp-keeper.cjs"
  "${remote_dir}/migrate-chrome-profile.sh"
  "${remote_dir}/run-playwright-mcp.sh"
  "${remote_dir}/run-gateway.sh"
  "${remote_dir}/prepare-credentials.sh"
  "${remote_dir}/browser-playbook.md"
  "${remote_dir}/inject-instructions.cjs"
  "${remote_dir}/guest-access-broker.py"
  "${remote_dir}/guest-session-proxy.cjs"
  "${remote_dir}/verify-upstream-playwright-lifecycle.cjs"
  "${remote_dir}/remote-browser-credentials"
)
for file in "${required_files[@]}"; do
  require_file "${file}"
done

# The unified image uses the stock, exact MCP release. It must not carry the
# remotechromemcp 0.0.78 bundle mutation or any replacement Playwright patch.
require_regex Dockerfile 'PLAYWRIGHT_MCP_VERSION="?0\.0\.82"?' \
  'Playwright MCP must be pinned exactly to 0.0.82'
require_regex Dockerfile '@playwright/mcp@\$\{?PLAYWRIGHT_MCP_VERSION\}?' \
  'the pinned Playwright MCP package must be installed by version'
require_regex Dockerfile 'npm.*(install|view|list)|PLAYWRIGHT_MCP_VERSION' \
  'the image must install and verify the pinned MCP package'
if find . -path './.git' -prune -o -path './tests' -prune -o \
  \( -iname '*patch*playwright*' -o -iname '*playwright*patch*' \) -print | \
  grep -q .; then
  fail 'the stock Playwright MCP runtime must not include a project patch file'
fi
if rg -n 'patch-playwright|PLAYWRIGHT_MCP_PATCH|node_modules/[^ ]+\.js.*(sed|perl|python)' \
  --glob '!tests/**' --glob '!docs/**' --glob '!.git/**' .; then
  fail 'the stock Playwright MCP package must not be rewritten after installation'
fi
require_literal Dockerfile 'verify-upstream-playwright-lifecycle.cjs' \
  'the image build must fail closed if upstream lifecycle recovery changes'
for lifecycle_fragment in \
  'shared2.browser.once("disconnected", () => {' \
  'browser.contexts()[0] ?? await browser.newContext' \
  'browser.on("disconnected", () => relay.stop());'; do
  require_literal "${remote_dir}/verify-upstream-playwright-lifecycle.cjs" \
    "${lifecycle_fragment}" \
    'the verifier must cover the upstream browser recovery lifecycle'
done
require_literal "${remote_dir}/verify-upstream-playwright-lifecycle.cjs" \
  'REMOTE_CHROME_MCP_LIFECYCLE_PATCH=1' \
  'the verifier must reject the legacy lifecycle patch marker'

require_literal "${remote_dir}/run-playwright-mcp.sh" '--endpoint' \
  'Playwright MCP must attach to the owned visible Chrome endpoint'
require_literal "${remote_dir}/run-playwright-mcp.sh" \
  'endpoint.sock' \
  'Playwright MCP must use the protected stable Unix endpoint'
require_regex "${remote_dir}/run-playwright-mcp.sh" \
  '--host([=[:space:]]+)127\.0\.0\.2' \
  'the MCP HTTP backend must bind only to the non-forwarded loopback alias'
require_regex "${remote_dir}/run-playwright-mcp.sh" \
  '--port([=[:space:]]+)8932' \
  'the MCP HTTP backend must use the private port 8932'
if rg -n -- '--extension|EXTENSION_TOKEN|extension-token' \
  "${remote_dir}/run-playwright-mcp.sh" Dockerfile supervisord.conf; then
  fail 'remote MCP must not require a Playwright extension or extension token'
fi

require_literal "${remote_dir}/browser-owner.cjs" \
  "chromium.launchPersistentContext(profileDir" \
  'the browser owner must launch one persistent headed context'
require_literal "${remote_dir}/browser-owner.cjs" 'headless: false' \
  'the browser owner must launch the visible headed browser'
require_literal "${remote_dir}/browser-owner.cjs" 'chromiumSandbox: true' \
  'the browser owner must retain the Chromium sandbox'
require_literal "${remote_dir}/browser-owner.cjs" \
  "ignoreDefaultArgs: ['--disable-extensions']" \
  'the persistent browser must keep installed extensions enabled'
require_regex "${remote_dir}/browser-owner.cjs" \
  'browser\.bind\([^,]+,[[:space:]]*\{' \
  'the browser owner must bind a private pipe endpoint without a TCP host or port'
require_literal "${remote_dir}/browser-owner.cjs" 'chmod(endpoint, 0o600)' \
  'the private browser socket must be owner-only'
require_literal entrypoint.sh \
  'install -d -o codex -g codex -m 0700 /run/remote-browser/browser' \
  'the private browser runtime must deny the guest UID'
require_literal compose.yaml \
  'CODEX_CHROME_PROFILE_DIR: /home/codex/.config/remote-browser/chrome-profile' \
  'the browser owner must use a nondefault persistent profile'
require_literal "${remote_dir}/mcp-keeper.cjs" \
  "name: 'browser_tabs'" \
  'the keeper must establish the shared browser with a nonmutating tool'
require_literal "${remote_dir}/mcp-keeper.cjs" \
  "arguments: { action: 'list' }" \
  'the keeper must not navigate or edit the browser'

# There is no Chrome CDP listener at all. Exclude prose and tests so the
# prohibition can be documented and asserted without tripping itself.
if rg -n -- '--remote-debugging-(port|address)|(^|[^0-9])9222([^0-9]|$)' \
  Dockerfile compose.yaml compose.macos.yaml supervisord.conf entrypoint.sh \
  run-*.sh lib bootstrap.sh deploy.env.example; then
  fail 'the unified runtime must not configure or probe a Chrome CDP listener'
fi
require_literal "${remote_dir}/browser-owner.cjs" \
  "'/home/codex/.config/remote-browser/chrome-profile'" \
  'the visible Chrome must retain the nondefault persistent desktop profile'
if rg -n --glob '!browser-owner.cjs' \
  --glob '!verify-upstream-playwright-lifecycle.cjs' -- \
  '--headless|newContext\(|launchPersistentContext|chromium\.launch' \
  "${remote_dir}"; then
  fail 'only the dedicated owner may launch the persistent browser'
fi

# Node and the MCP runtime must be native to the selected image architecture.
require_regex Dockerfile 'CODEX_DESKTOP_(NODE_ARCH|IMAGE_ARCH)' \
  'the image must record the expected Node architecture'
require_regex Dockerfile \
  'process\.arch|dpkg-query.*nodejs|dpkg.*--print-architecture' \
  'the image build must verify the Node runtime architecture'
require_regex healthcheck.sh 'node.*process\.arch|CODEX_DESKTOP_NODE_ARCH' \
  'runtime health must verify the Node architecture'
require_regex Dockerfile 'DESKTOP_ARCH="amd64"|ARG DESKTOP_ARCH' \
  'the image must retain AMD64 build arguments'
require_regex compose.macos.yaml 'platform:[[:space:]]+linux/arm64' \
  'the macOS override must select native ARM64'
require_regex scripts/install-macos.sh \
  'DESKTOP_ARCH=arm64|TAILSCALE_BINARY_PLATFORM=linux/arm64' \
  'the macOS builder must provide native ARM64 arguments'
if rg -n -- '--platform[= ]+linux/amd64|softwareupdate.*--install-rosetta|arch[[:space:]]+-x86_64' \
  compose.macos.yaml scripts/install-macos.sh; then
  fail 'the Apple-silicon path must never use AMD64 emulation or Rosetta'
fi

# One container, no Docker-published ingress, and only the authenticated
# gateway is presented to Tailscale Serve. Backend services remain loopback.
service_count="$(
  awk '
    /^services:/ { in_services=1; next }
    in_services && /^[^[:space:]]/ { in_services=0 }
    in_services && /^  [[:alnum:]_.-]+:$/ { count++ }
    END { print count + 0 }
  ' compose.yaml
)"
[[ "${service_count}" == 1 ]] || fail 'compose.yaml must define exactly one service'
if grep -Eq '^[[:space:]]+(ports|network_mode):' compose.yaml compose.macos.yaml; then
  fail 'Compose must not publish ports or join the host network'
fi
require_literal "${remote_dir}/run-gateway.sh" '127.0.0.1:8443' \
  'Tailscale Serve must target only the authenticated gateway'
require_literal "${remote_dir}/run-gateway.sh" '127.0.0.1:8445' \
  'public Funnel must target only the dedicated MCP listener'
require_literal "${remote_dir}/run-gateway.sh" 'serve' \
  'the gateway runner must configure Tailscale Serve'
require_literal "${remote_dir}/run-gateway.sh" 'REMOTE_BROWSER_PUBLIC_MCP_FUNNEL' \
  'public MCP Funnel must be an explicit opt-in'
require_regex "${remote_dir}/run-gateway.sh" \
  'funnel.*|--https=443' \
  'the gateway runner must support public MCP Funnel HTTPS 443'
if rg -n 'tailscale.*serve.*(5900|6081|8932)' \
  "${remote_dir}" supervisord.conf; then
  fail 'Tailscale Serve must not expose VNC, noVNC, or the MCP backend directly'
fi
if rg -n '0\.0\.0\.0:(5900|6080|6081|8931|8932)|\[::\]:(5900|6080|6081|8931|8932)' \
  "${remote_dir}/Caddyfile" "${remote_dir}/run-gateway.sh" \
  "${remote_dir}/run-playwright-mcp.sh" run-x11vnc.sh run-novnc.sh \
  supervisord.conf; then
  fail 'legacy compatibility must not create unauthenticated wildcard listeners'
fi

# CodexGUI compatibility is explicitly opt-in. Its two unauthenticated
# listeners exist only inside Docker's external edge network, where the central
# Caddy owns authentication. The override may expose but must never publish
# them, must disable Tailscale Serve, and must use the established alias.
require_file compose.codexgui.yaml
require_file "${remote_dir}/edge-compat.caddy"
require_regex compose.codexgui.yaml 'REMOTE_BROWSER_EDGE_COMPAT:[[:space:]]+"1"' \
  'the CodexGUI override must opt into compatibility explicitly'
require_regex compose.codexgui.yaml 'REMOTE_BROWSER_TAILSCALE_SERVE:[[:space:]]+"0"' \
  'the CodexGUI override must disable the competing Tailscale ingress'
require_regex compose.codexgui.yaml 'aliases:([[:space:]]|$)' \
  'the CodexGUI override must declare the central-edge alias'
require_literal compose.codexgui.yaml 'remote-chrome' \
  'the CodexGUI override must preserve the existing upstream alias'
require_literal compose.codexgui.yaml '/var/lib/remote-chrome/profile' \
  'the CodexGUI override must reuse the existing browser profile in place'
require_literal compose.codexgui.yaml \
  'target: /home/codex/.config/remote-browser/chrome-profile' \
  'the CodexGUI profile bind must target the managed nondefault profile directly'
require_literal compose.codexgui.yaml '/etc/remote-chrome/credentials.env' \
  'the CodexGUI override must preserve the existing public handoff identity'
require_literal compose.codexgui.yaml 'read_only: true' \
  'legacy edge credentials must be mounted read-only'
if grep -Eq '^[[:space:]]+ports:' compose.codexgui.yaml; then
  fail 'the CodexGUI override must not publish compatibility ports'
fi
for port in 6080 8931; do
  require_regex compose.codexgui.yaml "-[[:space:]]*\"?${port}\"?" \
    "the CodexGUI override must expose private port ${port}"
done
require_regex "${remote_dir}/edge-compat.caddy" 'http://:8931' \
  'the edge MCP compatibility listener is missing'
require_regex "${remote_dir}/edge-compat.caddy" 'http://:6080' \
  'the edge noVNC compatibility listener is missing'
require_regex "${remote_dir}/edge-compat.caddy" \
  'reverse_proxy[[:space:]]+127\.0\.0\.2:8932' \
  'the edge MCP listener must proxy to the private backend'
require_regex "${remote_dir}/edge-compat.caddy" \
  'reverse_proxy[[:space:]]+127\.0\.0\.2:6081' \
  'the edge noVNC listener must proxy to the private backend'
if rg -n 'basic_auth|Authorization|REMOTE_BROWSER_(MCP|LOGIN)_TOKEN' \
  "${remote_dir}/edge-compat.caddy"; then
  fail 'edge compatibility must not duplicate central Caddy credentials'
fi
require_literal "${remote_dir}/run-gateway.sh" \
  'REMOTE_BROWSER_EDGE_CREDENTIALS_FILE' \
  'edge mode must validate the existing root-only handoff source'
require_literal "${remote_dir}/run-gateway.sh" 'edge_handoff_url' \
  'edge mode must preserve the existing public noVNC handoff URL'

# VNC is gateway-only and IPv4-only. The extra flags cover the historical
# x11vnc regression that produced a bracketed IPv6 listener despite -no6.
require_literal run-x11vnc.sh '-listen 127.0.0.2' \
  'raw VNC must bind only to the non-forwarded loopback alias'
require_literal run-x11vnc.sh '-nopw' \
  'the outer authenticated gateway replaces the inner VNC password prompt'
require_literal run-x11vnc.sh '-noipv6' \
  'x11vnc must explicitly disable IPv6 sockets'
require_literal run-x11vnc.sh '-no6' \
  'x11vnc must disable IPv6 protocol support'
require_regex run-x11vnc.sh '-rfbportv6([=[:space:]]+)-1' \
  'x11vnc must disable its IPv6 RFB port'
require_literal run-novnc.sh '127.0.0.2:6081' \
  'the noVNC backend must bind only to the non-forwarded loopback alias'
require_literal run-novnc.sh '127.0.0.2:5900' \
  'noVNC must reach only the private raw VNC backend'
if rg -n '\[::[01]?\]:(5900|6081|8932)|(^|[^[:alnum:]]):::(5900|6081|8932)' \
  run-x11vnc.sh run-novnc.sh "${remote_dir}" supervisord.conf; then
  fail 'private browser backends must not create bracketed IPv6 listeners'
fi

# Supervisor owns each recoverable process independently. MCP/gateway failure
# must not restart the desktop session or browser owner.
require_literal supervisord.conf '[program:remote-browser-owner]' \
  'the persistent browser must have a dedicated supervisor owner'
require_literal supervisord.conf '[program:playwright-mcp]' \
  'Playwright MCP must have an independent supervisor program'
require_literal supervisord.conf '[program:remote-browser-keeper]' \
  'the shared browser must have a reconnecting keeper'
require_literal supervisord.conf '[program:remote-browser-gateway]' \
  'the authenticated gateway must have an independent supervisor program'
require_literal supervisord.conf '[program:remote-browser-guest-access]' \
  'the root guest broker must have an independent supervisor program'
for program in remote-browser-owner playwright-mcp remote-browser-keeper \
  remote-browser-gateway remote-browser-guest-access; do
  stanza="$(awk -v program="${program}" '
    $0 == "[program:" program "]" { found=1 }
    found && /^\[/ && $0 != "[program:" program "]" { exit }
    found { print }
  ' supervisord.conf)"
  grep -Fq 'autorestart=true' <<<"${stanza}" || \
    fail "${program} must restart independently"
  grep -Eq '^stopasgroup=true$|^killasgroup=true$' <<<"${stanza}" || \
    fail "${program} must terminate its own process group cleanly"
done
require_regex Dockerfile 'useradd.*--uid[=[:space:]]+10002.*remote-guest|useradd.*10002' \
  'the public guest proxy must run as a dedicated unprivileged account'
require_literal compose.codexgui.yaml 'REMOTE_BROWSER_GUEST_ACCESS_ENABLED: "0"' \
  'CodexGUI edge mode must disable the local Funnel guest broker'

# Docker health is a non-mutating liveness check. It may issue GET against the
# public health endpoint, but must never initialize/delete MCP sessions, open a
# browser tab, or invoke browser tools.
require_regex healthcheck.sh 'supervisorctl status (playwright-mcp|remote-browser-gateway)' \
  'health must validate both remote-browser supervisor programs'
require_regex healthcheck.sh 'healthz|127\.0\.0\.1:8443' \
  'health must probe the gateway health endpoint'
if rg -n '"method"[[:space:]]*:[[:space:]]*"initialize"|tools/(call|list)|Mcp-Session-Id|curl.*-X[[:space:]]*(POST|DELETE)' \
  healthcheck.sh; then
  fail 'Docker health must not mutate MCP or browser state'
fi

printf 'PASS: unified remote browser contracts\n'
