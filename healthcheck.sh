#!/usr/bin/env bash
set -Eeuo pipefail

test -S /run/tailscale/tailscaled.sock
pgrep -x tailscaled >/dev/null
pgrep -x dbus-daemon >/dev/null
test "$(dpkg-query -W -f='${Version}' chatgpt)" = "${CODEX_DESKTOP_CHATGPT_VERSION}"
test "$(dpkg-query -W -f='${Version}' chrome-remote-desktop)" = "${CODEX_DESKTOP_CRD_VERSION}"
test "$(dpkg-query -W -f='${Version}' google-chrome-stable)" = "${CODEX_DESKTOP_CHROME_VERSION}"
test -x /usr/bin/chatgpt
test -x /opt/google/chrome-remote-desktop/start-host
test -x /opt/google/chrome-remote-desktop/start-host.real
test "$(passwd -S codex | cut -d ' ' -f2)" = "L"
grep -Fqx 'account sufficient pam_succeed_if.so quiet user = codex' \
  /etc/pam.d/chrome-remote-desktop
/usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock status --json >/dev/null
