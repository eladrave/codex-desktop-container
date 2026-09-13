#!/usr/bin/env bash
set -Eeuo pipefail

install -d -m 0755 /run/dbus /run/tailscale /var/lib/tailscale
install -d -m 0700 /var/lib/codex-desktop-persistent
test -d /home/codex

machine_id_file=/var/lib/codex-desktop-persistent/machine-id
if [[ ! -s "${machine_id_file}" ]]; then
  dbus-uuidgen > "${machine_id_file}"
  chmod 0600 "${machine_id_file}"
fi
install -o root -g root -m 0444 "${machine_id_file}" /etc/machine-id

if [[ ! -e /home/codex/.codex-desktop-initialized ]]; then
  setpriv --reuid=10001 --regid=10001 --init-groups \
    cp -R /opt/codex-desktop-home-skel/. /home/codex/
  setpriv --reuid=10001 --regid=10001 --init-groups \
    touch /home/codex/.codex-desktop-initialized
fi

setpriv --reuid=10001 --regid=10001 --init-groups \
  install -d -m 0700 \
  /home/codex/.cache \
  /home/codex/.codex \
  /home/codex/.config \
  /home/codex/.config/chrome-remote-desktop \
  /home/codex/.local \
  /home/codex/.local/share \
  /home/codex/Projects

exec /usr/bin/supervisord --nodaemon --configuration /etc/supervisor/supervisord.conf
