#!/usr/bin/env bash
set -Eeuo pipefail

password_file="${CODEX_NOVNC_PASSWORD_FILE:-/home/codex/.vnc/passwd}"
session_file="${CODEX_DESKTOP_SESSION_FILE:-/run/codex-desktop/desktop.env}"

while true; do
  if [[ ! -f "${password_file}" || -L "${password_file}" || \
    "$(stat -c '%u:%g:%a' "${password_file}" 2>/dev/null || true)" != \
      '10001:10001:600' ]]; then
    sleep 5
    continue
  fi
  if [[ ! -f "${session_file}" || -L "${session_file}" || \
    "$(stat -c '%u:%g:%a' "${session_file}" 2>/dev/null || true)" != \
      '10001:10001:600' ]]; then
    sleep 5
    continue
  fi

  display="$(sed -n 's/^DISPLAY=//p' "${session_file}" 2>/dev/null | head -n 1)"
  xauthority="$(sed -n 's/^XAUTHORITY=//p' "${session_file}" 2>/dev/null | head -n 1)"
  if [[ ! "${display}" =~ ^:[0-9]+$ || \
    ! "${xauthority}" =~ ^/ || ! -r "${xauthority}" ]]; then
    sleep 5
    continue
  fi
  display_number="${display#:}"
  if [[ ! -S "/tmp/.X11-unix/X${display_number}" ]]; then
    sleep 5
    continue
  fi
  break
done

exec /usr/bin/x11vnc \
  -display "${display}" \
  -auth "${xauthority}" \
  -rfbauth "${password_file}" \
  -rfbport 5900 \
  -listen 127.0.0.1 \
  -no6 \
  -forever \
  -shared
