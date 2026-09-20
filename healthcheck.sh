#!/usr/bin/env bash
set -Eeuo pipefail

test -S /run/tailscale/tailscaled.sock
pgrep -x tailscaled >/dev/null
pgrep -x dbus-daemon >/dev/null
test "$(dpkg-query -W -f='${Version}' chatgpt)" = "${CODEX_DESKTOP_CHATGPT_VERSION}"
test "$(dpkg-query -W -f='${Architecture}' chatgpt)" = "${CODEX_DESKTOP_IMAGE_ARCH}"
test "$(dpkg-query -W -f='${Version}' google-chrome-stable)" = "${CODEX_DESKTOP_CHROME_VERSION}"
test "$(dpkg-query -W -f='${Architecture}' google-chrome-stable)" = "${CODEX_DESKTOP_IMAGE_ARCH}"
test -x /usr/bin/chatgpt
test -x /usr/bin/google-chrome-stable
test -x /usr/bin/xdg-mime
test -x /usr/bin/websockify
test -x /usr/bin/x11vnc
test -x /usr/bin/Xvfb
test -x /usr/local/bin/node
test -x /usr/local/bin/playwright-mcp
test -x /usr/bin/caddy
test -x /usr/bin/python3
test "$(id -u remote-guest)" = 10002
test "$(playwright-mcp --version)" = "Version ${PLAYWRIGHT_MCP_VERSION}"
case "${CODEX_DESKTOP_IMAGE_ARCH}" in
  amd64) expected_node_arch=x64 ;;
  arm64) expected_node_arch=arm64 ;;
  *) exit 1 ;;
esac
test "$(node --print 'process.arch')" = "${expected_node_arch}"
case "${CODEX_DESKTOP_CRD_ENABLED}" in
  1)
    test "$(dpkg-query -W -f='${Version}' chrome-remote-desktop)" = \
      "${CODEX_DESKTOP_CRD_VERSION}"
    test -x /opt/google/chrome-remote-desktop/start-host
    test -x /opt/google/chrome-remote-desktop/start-host.real
    grep -Fqx 'account sufficient pam_succeed_if.so quiet user = codex' \
      /etc/pam.d/chrome-remote-desktop
    ;;
  0)
    ! dpkg-query -W chrome-remote-desktop >/dev/null 2>&1
    test ! -e /opt/google/chrome-remote-desktop
    test ! -e /usr/local/sbin/run-codex-crd
    test ! -e /usr/local/bin/configure-chrome-remote-desktop
    ;;
  *) exit 1 ;;
esac
test "$(od -An -tx1 -j18 -N2 /usr/local/bin/tailscale | tr -d ' \n')" = \
  "${CODEX_DESKTOP_TAILSCALE_ELF_MACHINE_HEX}"
test "$(od -An -tx1 -j18 -N2 /usr/local/bin/tailscaled | tr -d ' \n')" = \
  "${CODEX_DESKTOP_TAILSCALE_ELF_MACHINE_HEX}"
test "$(passwd -S codex | cut -d ' ' -f2)" = "L"
for mime_type in text/html x-scheme-handler/http x-scheme-handler/https; do
  test "$(setpriv --reuid=10001 --regid=10001 --init-groups \
    env HOME=/home/codex USER=codex LOGNAME=codex \
      XDG_CONFIG_HOME=/home/codex/.config \
    xdg-mime query default "${mime_type}")" = google-chrome.desktop
done
test "$(setpriv --reuid=10001 --regid=10001 --init-groups \
  env HOME=/home/codex USER=codex LOGNAME=codex \
    XDG_CONFIG_HOME=/home/codex/.config \
  xdg-mime query default x-scheme-handler/codex)" = chatgpt.desktop
# A fresh node is intentionally healthy before enrollment so the operator can
# reach the guided Tailscale step. Running state is enforced by deployment
# verification after enrollment; liveness here requires the daemon and socket.
tailscale_status="$(
  /usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock \
    status --json 2>/dev/null || true
)"
if [[ -n "${tailscale_status}" ]]; then
  printf '%s' "${tailscale_status}" | jq -e 'type == "object"' >/dev/null
fi

chrome_main_running() {
  local candidate command_line count=0
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    command_line="$(tr '\0' ' ' <"/proc/${candidate}/cmdline" 2>/dev/null || true)"
    [[ "${command_line}" == *'--user-data-dir=/home/codex/.config/remote-browser/chrome-profile'* ]] || continue
    [[ "${command_line}" == *' --type='* ]] && continue
    [[ "${command_line}" != *'--disable-extensions'* ]]
    [[ "${command_line}" != *'--no-sandbox'* ]]
    [[ "${command_line}" != *'--disable-setuid-sandbox'* ]]
    [[ "${command_line}" != *'--remote-debugging-port'* ]]
    ((count += 1))
  done < <(pgrep -u 10001 -f 'user-data-dir=/home/codex/.config/remote-browser/chrome-profile' || true)
  [[ "${count}" == 1 ]]
}

supervisorctl status remote-browser-gateway | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
supervisorctl status remote-browser-guest-access | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
supervisorctl status playwright-mcp | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
supervisorctl status remote-browser-owner | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
supervisorctl status remote-browser-keeper | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
supervisorctl status novnc | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
curl --fail --silent --show-error --max-time 5 \
  "http://127.0.0.2:6081/" | grep -qi noVNC
curl --fail --silent --show-error --max-time 5 \
  "http://127.0.0.1:8443/healthz" | grep -qx ready
[[ "$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  http://127.0.0.1:8445/login/)" == 404 ]]

supervisorctl status desktop-session | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
desktop_ready=0
if [[ "${CODEX_DESKTOP_CRD_ENABLED}" == 1 ]] && \
  compgen -G '/home/codex/.config/chrome-remote-desktop/host#*.json' >/dev/null; then
  setpriv --reuid=10001 --regid=10001 --init-groups \
    env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
    /opt/google/chrome-remote-desktop/chrome-remote-desktop --get-status | \
    grep -qx STARTED
  desktop_ready=1
elif [[ "${CODEX_DESKTOP_CRD_ENABLED}" == 1 ]]; then
  # Before CRD registration, run-session deliberately selects the local Xvfb
  # fallback so noVNC and MCP are immediately usable.
  pgrep -u 10001 -x Xvfb >/dev/null
  desktop_ready=1
elif [[ "${CODEX_DESKTOP_CRD_ENABLED}" == 0 ]]; then
  pgrep -u 10001 -x Xvfb >/dev/null
  desktop_ready=1
fi

if ((desktop_ready == 1)); then
  [[ -f /run/codex-desktop/desktop.env && \
    ! -L /run/codex-desktop/desktop.env ]]
  [[ "$(stat -c '%u:%g:%a' /run/codex-desktop/desktop.env)" == \
    '10001:10001:600' ]]
  display="$(sed -n 's/^DISPLAY=//p' /run/codex-desktop/desktop.env | head -n 1)"
  xauthority="$(sed -n 's/^XAUTHORITY=//p' /run/codex-desktop/desktop.env | head -n 1)"
  [[ "${display}" =~ ^:[0-9]+$ && -r "${xauthority}" ]]
  chrome_main_running
  pgrep -u 10001 -f '/usr/lib/chatgpt/ChatGPT' >/dev/null
  setpriv --reuid=10001 --regid=10001 --init-groups \
    test -w /home/codex/.config/remote-browser/chrome-profile
  supervisorctl status x11vnc | \
    grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
  pgrep -u 10001 -x x11vnc >/dev/null
  x11vnc_command="$(pgrep -u 10001 -x x11vnc | head -n 1)"
  x11vnc_command="$(tr '\0' ' ' <"/proc/${x11vnc_command}/cmdline")"
  [[ "${x11vnc_command}" == *"-display ${display}"* ]]
  [[ "${x11vnc_command}" == *"-auth ${xauthority}"* ]]
  [[ "${x11vnc_command}" == *' -nopw '* ]]
  [[ "${x11vnc_command}" == *' -noipv6 '* ]]
  exec 3<>/dev/tcp/127.0.0.2/5900
  IFS= read -r -t 2 rfb_banner <&3
  exec 3>&-
  [[ "${rfb_banner}" == RFB* ]]
fi

listeners="$(ss -H -lnt)"
grep -Eq '127[.]0[.]0[.]2:5900[[:space:]]' <<<"${listeners}"
grep -Eq '127[.]0[.]0[.]2:6081[[:space:]]' <<<"${listeners}"
grep -Eq '127[.]0[.]0[.]2:8932[[:space:]]' <<<"${listeners}"
grep -Eq '127[.]0[.]0[.]1:8443[[:space:]]' <<<"${listeners}"
if grep -Eq '(^|[[:space:]])(0[.]0[.]0[.]0|\[::\]|:::|\*):(5900|6081|8443|8444|9222)([[:space:]]|$)' \
  <<<"${listeners}"; then
  echo 'Remote browser service is listening on an unrestricted address.' >&2
  exit 1
fi

guest_socket=/run/remote-browser/guest-control.sock
guest_status=/run/remote-browser/guest-status.json
[[ -S "${guest_socket}" && ! -L "${guest_socket}" ]]
[[ "$(stat -c '%u:%g:%a' "${guest_socket}")" == '0:10001:660' ]]
[[ -f "${guest_status}" && ! -L "${guest_status}" ]]
[[ "$(stat -c '%u:%g:%a' "${guest_status}")" == '0:10001:440' ]]
guest_state="$(jq -er '.state | select(. == "CLOSED" or . == "STARTING" or . == "ISSUED" or . == "REDEEMED" or . == "CLOSING" or . == "BLOCKED")' "${guest_status}")"
if [[ "${guest_state}" == ISSUED || "${guest_state}" == REDEEMED ]]; then
  grep -Eq '127[.]0[.]0[.]1:8444[[:space:]]' <<<"${listeners}"
elif grep -Eq '[[:space:]]127[.]0[.]0[.]1:8444[[:space:]]' <<<"${listeners}"; then
  echo 'Guest proxy listener remained active without an issued session.' >&2
  exit 1
fi

edge_compat="${REMOTE_BROWSER_EDGE_COMPAT:-0}"
if [[ "${edge_compat}" == 1 ]]; then
  grep -Eq '(^|[[:space:]])(0[.]0[.]0[.]0|\*):6080[[:space:]]' \
    <<<"${listeners}"
  grep -Eq '(^|[[:space:]])(0[.]0[.]0[.]0|\*):8931[[:space:]]' \
    <<<"${listeners}"
else
  if grep -Eq '(^|[[:space:]])(0[.]0[.]0[.]0|\[::\]|:::|\*):(6080|8931)([[:space:]]|$)' \
    <<<"${listeners}"; then
    echo 'CodexGUI compatibility listener is active outside edge mode.' >&2
    exit 1
  fi
fi
if grep -Eq '(^|:|\])9222([[:space:]]|$)' <<<"${listeners}"; then
  echo 'A forbidden Chrome debugging listener is active on port 9222.' >&2
  exit 1
fi

browser_runtime=/run/remote-browser/browser
browser_endpoint=${browser_runtime}/endpoint.sock
[[ -d "${browser_runtime}" && ! -L "${browser_runtime}" ]]
[[ "$(stat -c '%u:%g:%a' "${browser_runtime}")" == '10001:10001:700' ]]
[[ -L "${browser_endpoint}" ]]
browser_endpoint_target="$(readlink -f "${browser_endpoint}")"
[[ -n "${browser_endpoint_target}" && -S "${browser_endpoint_target}" ]]
[[ "$(stat -c '%u:%g:%a' "${browser_endpoint_target}")" == '10001:10001:600' ]]
setpriv --reuid=10002 --regid=10002 --clear-groups \
  test ! -x /run/remote-browser
