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
  local candidate command_line
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    command_line="$(tr '\0' ' ' <"/proc/${candidate}/cmdline" 2>/dev/null || true)"
    [[ "${command_line}" == *'--user-data-dir=/home/codex/.config/google-chrome'* ]] || continue
    [[ "${command_line}" == *' --type='* ]] && continue
    return 0
  done < <(pgrep -u 10001 -f 'user-data-dir=/home/codex/.config/google-chrome' || true)
  return 1
}

tailscale_ip="$(
  /usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock \
    ip -4 2>/dev/null | head -n 1 || true
)"
if [[ -n "${tailscale_ip}" ]]; then
  supervisorctl status novnc | grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
  curl --fail --silent --show-error --max-time 5 \
    "http://127.0.0.1:6080/vnc.html" | grep -qi noVNC
fi

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
    test -w /home/codex/.config/google-chrome
  if [[ -s /home/codex/.vnc/passwd ]]; then
    [[ -f /home/codex/.vnc/passwd && ! -L /home/codex/.vnc/passwd ]]
    [[ "$(stat -c '%u:%g:%a' /home/codex/.vnc/passwd)" == \
      '10001:10001:600' ]]
    supervisorctl status x11vnc | grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
    pgrep -u 10001 -x x11vnc >/dev/null
    x11vnc_command="$(pgrep -u 10001 -x x11vnc | head -n 1)"
    x11vnc_command="$(tr '\0' ' ' <"/proc/${x11vnc_command}/cmdline")"
    [[ "${x11vnc_command}" == *"-display ${display}"* ]]
    [[ "${x11vnc_command}" == *"-auth ${xauthority}"* ]]
    exec 3<>/dev/tcp/127.0.0.2/5900
    IFS= read -r -t 2 rfb_banner <&3
    exec 3>&-
    [[ "${rfb_banner}" == RFB* ]]
  fi
fi
