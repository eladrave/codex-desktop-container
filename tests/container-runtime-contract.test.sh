#!/usr/bin/env bash
set -Eeuo pipefail

container="${CODEX_REMOTE_BROWSER_CONTAINER:-}"
if [[ -z "${container}" ]]; then
  printf 'SKIP: set CODEX_REMOTE_BROWSER_CONTAINER to test a running unified container\n'
  exit 0
fi

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail 'docker is required'
docker inspect "${container}" >/dev/null 2>&1 || fail 'container is not inspectable'

running="$(docker inspect --format '{{.State.Running}}' "${container}")"
[[ "${running}" == true ]] || fail 'container is not running'

image_id="$(docker inspect --format '{{.Image}}' "${container}")"
image_arch="$(docker image inspect --format '{{.Architecture}}' "${image_id}")"
case "${image_arch}" in
  amd64|arm64) ;;
  *) fail "unsupported image architecture: ${image_arch}" ;;
esac
if [[ -n "${CODEX_REMOTE_BROWSER_EXPECTED_ARCH:-}" &&
  "${image_arch}" != "${CODEX_REMOTE_BROWSER_EXPECTED_ARCH}" ]]; then
  fail "expected ${CODEX_REMOTE_BROWSER_EXPECTED_ARCH}, got ${image_arch}"
fi

# Every exposed-container port must be unbound on the host. An empty mapping or
# JSON null is acceptable; any HostPort would bypass the tailnet gateway.
published="$({
  docker inspect --format \
    '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{$port}}={{.HostIp}}:{{.HostPort}}{{println}}{{end}}{{end}}' \
    "${container}"
} 2>/dev/null)"
[[ -z "${published}" ]] || fail 'the container publishes host ports'

docker exec -i "${container}" bash -Eeuo pipefail <<'CONTAINER'
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "$(playwright-mcp --version)" == 'Version 0.0.82' ]] ||
  fail 'running Playwright MCP is not exactly 0.0.82'

case "${CODEX_DESKTOP_IMAGE_ARCH}" in
  amd64) expected_node=x64 ;;
  arm64) expected_node=arm64 ;;
  *) fail 'invalid CODEX_DESKTOP_IMAGE_ARCH' ;;
esac
[[ "$(node --print process.arch)" == "${expected_node}" ]] ||
  fail 'Node architecture does not match the native image architecture'

for program in desktop-session x11vnc novnc playwright-mcp \
  remote-browser-gateway remote-browser-guest-access; do
  supervisorctl status "${program}" |
    grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)' ||
    fail "supervisor program is not running: ${program}"
done

listeners="$(ss -lntH)"
for endpoint in \
  127.0.0.1:8443 \
  127.0.0.2:6081 \
  127.0.0.2:5900; do
  grep -Eq "[[:space:]]${endpoint}[[:space:]]" <<<"${listeners}" ||
    fail "expected private listener is missing: ${endpoint}"
done
if grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):(5900|6081|8932|8443|8444)([[:space:]]|$)' \
  <<<"${listeners}"; then
  fail 'a browser-control listener is bound to a wildcard address'
fi
if grep -Eq '(^|[[:space:]])(127\.[0-9.]+|\[::1\]|::1):9222([[:space:]]|$)' \
  <<<"${listeners}"; then
  fail 'Chrome CDP port 9222 is listening'
fi
if grep -Eq '\[::[01]?\]:(5900|6081|8932|8444)' <<<"${listeners}"; then
  fail 'a private backend regressed to a bracketed IPv6 listener'
fi

chrome_processes=0
chrome_main_pid=
while IFS= read -r pid; do
  [[ -n "${pid}" ]] || continue
  command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "${command_line}" == *'--user-data-dir=/home/codex/.config/google-chrome'* ]] || continue
  [[ "${command_line}" == *' --type='* ]] && continue
  ((chrome_processes += 1))
  chrome_main_pid="${pid}"
  if [[ "${command_line}" == *'--remote-debugging-port'* ||
    "${command_line}" == *'--remote-debugging-address'* ]]; then
    fail 'the visible Chrome was started with a remote-debugging flag'
  fi
done < <(pgrep -u 10001 -f 'user-data-dir=/home/codex/.config/google-chrome' || true)
[[ "${chrome_processes}" == 1 ]] ||
  fail "expected one visible persistent Chrome, found ${chrome_processes}"

credential_dir=/var/lib/codex-desktop-persistent/remote-browser
credential_file="${credential_dir}/credentials.env"
extension_file=/home/codex/.config/remote-browser/extension-token
[[ "$(stat -c '%u:%g:%a' "${credential_dir}")" == '0:0:700' ]] ||
  fail 'credential directory is not root-owned mode 0700'
[[ "$(stat -c '%u:%g:%a' "${credential_file}")" == '0:0:600' ]] ||
  fail 'gateway credential file is not root-owned mode 0600'
guest_socket=/run/remote-browser/guest-control.sock
guest_status=/run/remote-browser/guest-status.json
[[ -S "${guest_socket}" && ! -L "${guest_socket}" ]] ||
  fail 'guest-access control socket is unavailable'
[[ "$(stat -c '%u:%g:%a' "${guest_socket}")" == '0:10001:660' ]] ||
  fail 'guest-access control socket permissions are invalid'
[[ -f "${guest_status}" && ! -L "${guest_status}" ]] ||
  fail 'guest-access status is unavailable'
[[ "$(stat -c '%u:%g:%a' "${guest_status}")" == '0:10001:440' ]] ||
  fail 'guest-access status permissions are invalid'
jq -e 'keys == ["expiresAt", "redeemed", "state"] and
  (.state == "CLOSED" or .state == "STARTING" or .state == "ISSUED" or
   .state == "REDEEMED" or .state == "CLOSING" or .state == "BLOCKED")' \
  "${guest_status}" >/dev/null || fail 'guest-access status schema is invalid'
if [[ -e "${extension_file}" ]]; then
  [[ "$(stat -c '%u:%g:%a' "${extension_file}")" == '10001:10001:600' ]] ||
    fail 'extension token file is not codex-owned mode 0600'
  grep -Eq '[[:space:]]127[.]0[.]0[.]2:8932[[:space:]]' <<<"${listeners}" ||
    fail 'configured Playwright MCP backend listener is missing'
elif grep -Eq '[[:space:]]127[.]0[.]0[.]2:8932[[:space:]]' <<<"${listeners}"; then
  fail 'Playwright MCP listened before extension-token provisioning'
fi

# Read only the expected values without evaluating the credential file as shell
# code. No values, URLs, response bodies, headers, or cookies are printed.
MCP_TOKEN=
LOGIN_TOKEN=
LOGIN_USERNAME=
LOGIN_PASSWORD=
while IFS='=' read -r key value; do
  case "${key}" in
    MCP_TOKEN) MCP_TOKEN="${value}" ;;
    LOGIN_TOKEN) LOGIN_TOKEN="${value}" ;;
    LOGIN_USERNAME) LOGIN_USERNAME="${value}" ;;
    LOGIN_PASSWORD) LOGIN_PASSWORD="${value}" ;;
    LOGIN_PASSWORD_HASH|'') ;;
    *) fail 'credential file contains an unexpected field' ;;
  esac
done <"${credential_file}"
[[ -n "${MCP_TOKEN}" && -n "${LOGIN_TOKEN}" &&
  -n "${LOGIN_USERNAME}" && -n "${LOGIN_PASSWORD}" ]] ||
  fail 'credential file omitted a required field'
health_code="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8443/healthz)"
[[ "${health_code}" == 200 ]] || fail 'gateway health endpoint is unavailable'
unauthorized="$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data '{}' http://127.0.0.1:8443/mcp)"
[[ "${unauthorized}" == 401 ]] || fail 'anonymous MCP request was not rejected'
get_code="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${MCP_TOKEN}" \
  http://127.0.0.1:8443/mcp)"
[[ "${get_code}" == 405 ]] || fail 'authenticated MCP GET did not return 405'

headers="$(mktemp)"
trap 'rm -f -- "${headers}"' EXIT
query_code="$(curl -sS -o /dev/null -D "${headers}" -w '%{http_code}' \
  "http://127.0.0.1:8443/login/?token=${LOGIN_TOKEN}")"
[[ "${query_code}" == 303 ]] || fail 'valid noVNC handoff token did not return 303'
grep -Eiq '^Location:[[:space:]]*/login/\?autoconnect=1&resize=scale[[:space:]]*$' \
  "${headers}" || fail 'handoff redirect did not remove the token and enable noVNC auto-connect'
cookie="$(grep -i '^Set-Cookie:' "${headers}" | head -n 1)"
for attribute in HttpOnly Secure 'SameSite=Strict'; do
  [[ "${cookie}" == *"${attribute}"* ]] ||
    fail "handoff cookie omitted ${attribute}"
done
grep -Eiq '^Cache-Control:[[:space:]]*no-store' "${headers}" ||
  fail 'handoff response omitted Cache-Control: no-store'
grep -Eiq '^Referrer-Policy:[[:space:]]*no-referrer' "${headers}" ||
  fail 'handoff response omitted Referrer-Policy: no-referrer'

basic_code="$(curl -sS -o /dev/null -w '%{http_code}' \
  --user "${LOGIN_USERNAME}:${LOGIN_PASSWORD}" \
  http://127.0.0.1:8443/login/)"
[[ "${basic_code}" == 200 ]] || fail 'Basic Auth noVNC fallback is unavailable'

/usr/local/sbin/codex-desktop-healthcheck

# A failed gateway or MCP is recovered independently. Neither recovery may
# replace the persistent visible Chrome or bounce the desktop session.
restart_independently() {
  local program="$1"
  local previous_pid replacement_pid=
  previous_pid="$(supervisorctl pid "${program}")"
  [[ "${previous_pid}" =~ ^[1-9][0-9]*$ ]] ||
    fail "could not identify ${program} PID"
  kill -TERM "${previous_pid}"
  for _ in $(seq 1 100); do
    replacement_pid="$(supervisorctl pid "${program}" 2>/dev/null || true)"
    if [[ "${replacement_pid}" =~ ^[1-9][0-9]*$ &&
      "${replacement_pid}" != "${previous_pid}" ]]; then
      supervisorctl status "${program}" |
        grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)' && return 0
    fi
    sleep 0.1
  done
  fail "${program} did not restart independently"
}

restart_independently remote-browser-gateway
restart_independently playwright-mcp
restart_independently remote-browser-guest-access
kill -0 "${chrome_main_pid}" || fail 'browser backend restart replaced Chrome'
current_chrome_main="$(
  pgrep -u 10001 -f 'user-data-dir=/home/codex/.config/google-chrome' |
    while IFS= read -r pid; do
      command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
      [[ "${command_line}" == *' --type='* ]] || printf '%s\n' "${pid}"
    done
)"
[[ "${current_chrome_main}" == "${chrome_main_pid}" ]] ||
  fail 'backend restart changed the visible Chrome/profile owner'
CONTAINER

printf 'PASS: running unified container contracts (%s)\n' "${image_arch}"
