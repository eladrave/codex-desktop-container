#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  exec setpriv \
    --reuid=10001 \
    --regid=10001 \
    --init-groups \
    env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
    /usr/local/bin/configure-codex-novnc
fi

if [[ "$(id -u)" -ne 10001 ]]; then
  echo "Run this command as root or local user codex." >&2
  exit 1
fi

password_dir=/home/codex/.vnc
password_file=${password_dir}/passwd

if [[ -L "${password_dir}" || -L "${password_file}" ]]; then
  echo "The noVNC password path must not be a symbolic link." >&2
  exit 1
fi

install -d -m 0700 "${password_dir}"
umask 077
/usr/bin/x11vnc -storepasswd

[[ -f "${password_file}" && ! -L "${password_file}" ]] || {
  echo "x11vnc did not create the expected password file." >&2
  exit 1
}
chmod 0600 "${password_file}"
[[ "$(stat -c '%u:%g:%a' "${password_file}")" == '10001:10001:600' ]] || {
  echo "The noVNC password file has unexpected ownership or permissions." >&2
  exit 1
}
pkill -u 10001 -TERM -x x11vnc 2>/dev/null || true
echo "noVNC password configured."
