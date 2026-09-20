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
image_crd="$(docker image inspect --format \
  '{{index .Config.Labels "io.google.chrome-remote-desktop.enabled"}}' \
  "${image_id}")"
runtime_crd="$(docker exec "${container}" printenv CODEX_DESKTOP_CRD_ENABLED)"
[[ "${image_crd}" == 0 || "${image_crd}" == 1 ]] ||
  fail "invalid image CRD label: ${image_crd}"
[[ "${runtime_crd}" == "${image_crd}" ]] ||
  fail 'runtime CRD mode does not match the image package mode'
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

for program in desktop-session x11vnc novnc remote-browser-owner playwright-mcp \
  remote-browser-keeper \
  remote-browser-gateway remote-browser-guest-access; do
  supervisorctl status "${program}" |
    grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)' ||
    fail "supervisor program is not running: ${program}"
done

listeners="$(ss -lntH)"
for endpoint in \
  127.0.0.1:8443 \
  127.0.0.2:6081 \
  127.0.0.2:5900 \
  127.0.0.2:8932; do
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
  [[ "${command_line}" == *'--user-data-dir=/home/codex/.config/remote-browser/chrome-profile'* ]] || continue
  [[ "${command_line}" == *' --type='* ]] && continue
  ((chrome_processes += 1))
  chrome_main_pid="${pid}"
  if [[ "${command_line}" == *'--remote-debugging-port'* ||
    "${command_line}" == *'--remote-debugging-address'* ]]; then
    fail 'the visible Chrome was started with a TCP remote-debugging flag'
  fi
  [[ "${command_line}" != *'--disable-extensions'* ]] ||
    fail 'the visible Chrome disabled installed extensions'
  [[ "${command_line}" != *'--no-sandbox'* ]] ||
    fail 'the visible Chrome disabled its sandbox'
  [[ "${command_line}" != *'--disable-setuid-sandbox'* ]] ||
    fail 'the visible Chrome disabled its setuid sandbox'
done < <(pgrep -u 10001 -f 'user-data-dir=/home/codex/.config/remote-browser/chrome-profile' || true)
[[ "${chrome_processes}" == 1 ]] ||
  fail "expected one visible persistent Chrome, found ${chrome_processes}"

credential_dir=/var/lib/codex-desktop-persistent/remote-browser
credential_file="${credential_dir}/credentials.env"
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
browser_runtime=/run/remote-browser/browser
browser_endpoint=${browser_runtime}/endpoint.sock
[[ -d "${browser_runtime}" && ! -L "${browser_runtime}" ]] ||
  fail 'private browser runtime directory is unavailable'
[[ "$(stat -c '%u:%g:%a' "${browser_runtime}")" == '10001:10001:700' ]] ||
  fail 'private browser runtime permissions are invalid'
[[ -L "${browser_endpoint}" ]] || fail 'stable browser endpoint symlink is unavailable'
browser_endpoint_target="$(readlink -f "${browser_endpoint}")"
[[ -S "${browser_endpoint_target}" ]] || fail 'bound browser endpoint is not a Unix socket'
[[ "$(stat -c '%u:%g:%a' "${browser_endpoint_target}")" == '10001:10001:600' ]] ||
  fail 'bound browser endpoint permissions are invalid'
setpriv --reuid=10002 --regid=10002 --clear-groups \
  test ! -x /run/remote-browser ||
  fail 'guest proxy can traverse the private browser endpoint directory'

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
restart_independently remote-browser-guest-access
kill -0 "${chrome_main_pid}" || fail 'browser backend restart replaced Chrome'
current_chrome_main="$(
  pgrep -u 10001 -f 'user-data-dir=/home/codex/.config/remote-browser/chrome-profile' |
    while IFS= read -r pid; do
      command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
      [[ "${command_line}" == *' --type='* ]] || printf '%s\n' "${pid}"
    done
)"
[[ "${current_chrome_main}" == "${chrome_main_pid}" ]] ||
  fail 'backend restart changed the visible Chrome/profile owner'
CONTAINER

token_file=/run/remote-browser/runtime-contract-token
profile_marker=/home/codex/.config/remote-browser/chrome-profile/.codex-runtime-contract-persistence

cleanup_runtime_contract() {
  docker exec "${container}" rm -f -- "${token_file}" "${profile_marker}" \
    >/dev/null 2>&1 || true
}
trap cleanup_runtime_contract EXIT HUP INT TERM

chrome_main_pid() {
  docker exec "${container}" bash -Eeuo pipefail -c '
    count=0
    selected=
    for pid in $(pgrep -u 10001 -f "user-data-dir=/home/codex/.config/remote-browser/chrome-profile" || true); do
      command_line=$(tr "\\0" " " <"/proc/$pid/cmdline" 2>/dev/null || true)
      [[ "$command_line" == *" --type="* ]] && continue
      count=$((count + 1))
      selected=$pid
    done
    [[ $count == 1 ]]
    printf "%s\\n" "$selected"
  '
}

wait_healthy() {
  local state
  for _ in $(seq 1 120); do
    state="$(docker inspect --format \
      '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
      "${container}" 2>/dev/null || true)"
    [[ "${state}" == 'running healthy' ]] && return 0
    sleep 1
  done
  fail 'container did not become healthy'
}

run_mcp_canary() {
  docker exec "${container}" sh -eu -c '
    credential_file=/var/lib/codex-desktop-persistent/remote-browser/credentials.env
    token_file=$1
    test -f "$credential_file" && test ! -L "$credential_file"
    test "$(stat -c "%u:%g:%a" "$credential_file")" = 0:0:600
    umask 077
    awk -F= '\''$1 == "MCP_TOKEN" { print substr($0, index($0, "=") + 1); exit }'\'' \
      "$credential_file" >"$token_file"
    test -s "$token_file"
  ' sh "${token_file}"
  docker exec -i "${container}" node - \
    --endpoint http://127.0.0.1:8443/mcp \
    --bearer-token-file "${token_file}" \
    --snapshot-only \
    --timeout-seconds 60 \
    <tests/mcp-session-regression.cjs
  docker exec "${container}" rm -f -- "${token_file}"
}

# A real initialize, tools/list, browser_snapshot, and DELETE must leave the
# persistent Chrome process intact.
initial_chrome_pid="$(chrome_main_pid)"
run_mcp_canary
[[ "$(chrome_main_pid)" == "${initial_chrome_pid}" ]] ||
  fail 'external MCP session deletion replaced the persistent Chrome'

# MCP recovers independently against the same browser endpoint.
docker exec "${container}" supervisorctl restart playwright-mcp >/dev/null
wait_healthy
[[ "$(chrome_main_pid)" == "${initial_chrome_pid}" ]] ||
  fail 'MCP restart replaced the persistent Chrome'
run_mcp_canary

# A browser crash must create a new endpoint and become usable without
# restarting the container or losing the persistent profile.
docker exec "${container}" kill -KILL "${initial_chrome_pid}"
replacement_chrome_pid=
for _ in $(seq 1 120); do
  replacement_chrome_pid="$(chrome_main_pid 2>/dev/null || true)"
  if [[ "${replacement_chrome_pid}" =~ ^[1-9][0-9]*$ &&
    "${replacement_chrome_pid}" != "${initial_chrome_pid}" ]]; then
    if docker exec "${container}" test -S \
      /run/remote-browser/browser/endpoint.sock 2>/dev/null; then
      break
    fi
  fi
  sleep 1
done
[[ "${replacement_chrome_pid}" =~ ^[1-9][0-9]*$ &&
  "${replacement_chrome_pid}" != "${initial_chrome_pid}" ]] ||
  fail 'browser owner did not recover after a Chrome crash'
wait_healthy
run_mcp_canary

# Container restart must retain profile state and restore the browser endpoint
# and MCP service without extension-token reprovisioning.
docker exec "${container}" sh -c \
  "umask 077; : >'${profile_marker}'; chown 10001:10001 '${profile_marker}'"
docker restart "${container}" >/dev/null
wait_healthy
docker exec "${container}" test -f "${profile_marker}" ||
  fail 'persistent Chrome profile marker did not survive container restart'
docker exec "${container}" test -S /run/remote-browser/browser/endpoint.sock ||
  fail 'private browser endpoint was not recreated after container restart'
run_mcp_canary

printf 'PASS: running unified container contracts (%s)\n' "${image_arch}"
