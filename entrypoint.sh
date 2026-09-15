#!/usr/bin/env bash
set -Eeuo pipefail

install -d -m 0755 /run/dbus /run/tailscale /var/lib/tailscale
install -d -o codex -g codex -m 0700 /run/codex-desktop
install -d -m 0700 /var/lib/codex-desktop-persistent
test -d /home/codex
# Linux installs pre-create the bind source as UID 10001. Docker Desktop uses
# a named volume whose root is initially owned by root. Normalize only the
# mount root so both persistence backends present the same private home.
chown codex:codex /home/codex
setpriv --reuid=10001 --regid=10001 --init-groups chmod 0700 /home/codex
chrome_profile_dir=/home/codex/.config/google-chrome

machine_id_file=/var/lib/codex-desktop-persistent/machine-id
if [[ ! -s "${machine_id_file}" ]]; then
  dbus-uuidgen > "${machine_id_file}"
  chmod 0600 "${machine_id_file}"
fi
install -o root -g root -m 0444 "${machine_id_file}" /etc/machine-id

if [[ ! -e /home/codex/.codex-desktop-initialized ]]; then
  # Docker named volumes are populated from the image before first start, and
  # intermediate directories can retain root ownership. This runs only for a
  # fresh home; established credential state is never recursively rewritten.
  chown -R codex:codex /home/codex
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
  /home/codex/.config/autostart \
  /home/codex/.config/chrome-remote-desktop \
  "${chrome_profile_dir}" \
  /home/codex/.local \
  /home/codex/.local/share \
  /home/codex/.vnc \
  /home/codex/Projects

# This is a service-managed autostart contract. Refresh it on image upgrades so
# existing persistent homes gain the supervised Codex launcher.
setpriv --reuid=10001 --regid=10001 --init-groups install -m 0644 \
  /opt/codex-desktop-home-skel/.config/autostart/codex.desktop \
  /home/codex/.config/autostart/codex.desktop

test -w "${chrome_profile_dir}"
# Chrome can leave these process locks after an unclean container stop. At this
# point no user session or Chrome process exists, so removing only Singleton*
# is safe and preserves cookies, extensions, and all other authenticated state.
rm -f -- "${chrome_profile_dir}"/Singleton*

exec /usr/bin/supervisord --nodaemon --configuration /etc/supervisor/supervisord.conf
