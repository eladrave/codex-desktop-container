#!/usr/bin/env bash
set -Eeuo pipefail

install -d -m 0755 /run/dbus /run/tailscale /var/lib/tailscale
install -d -o codex -g codex -m 0700 /run/codex-desktop
install -d -m 0700 /var/lib/codex-desktop-persistent
install -d -o root -g codex -m 0750 /run/remote-browser
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
  /home/codex/.config/remote-browser \
  "${chrome_profile_dir}" \
  /home/codex/.local \
  /home/codex/.local/share \
  /home/codex/.vnc \
  /home/codex/Projects

if [[ "${CODEX_DESKTOP_CRD_ENABLED:-1}" == 1 ]]; then
  setpriv --reuid=10001 --regid=10001 --init-groups \
    install -d -m 0700 /home/codex/.config/chrome-remote-desktop
fi

# This is a service-managed autostart contract. Refresh it on image upgrades so
# existing persistent homes gain the supervised Codex launcher.
setpriv --reuid=10001 --regid=10001 --init-groups install -m 0644 \
  /opt/codex-desktop-home-skel/.config/autostart/codex.desktop \
  /home/codex/.config/autostart/codex.desktop

# Electron delegates ChatGPT sign-in to the system browser. Register Chrome for
# web URLs and Codex for the OAuth callback before the desktop session starts.
# xdg-mime updates only these associations and preserves unrelated user choices.
for mime_type in text/html x-scheme-handler/http x-scheme-handler/https; do
  setpriv --reuid=10001 --regid=10001 --init-groups \
    env HOME=/home/codex USER=codex LOGNAME=codex \
      XDG_CONFIG_HOME=/home/codex/.config \
    xdg-mime default google-chrome.desktop "${mime_type}"
done
setpriv --reuid=10001 --regid=10001 --init-groups \
  env HOME=/home/codex USER=codex LOGNAME=codex \
    XDG_CONFIG_HOME=/home/codex/.config \
  xdg-mime default chatgpt.desktop x-scheme-handler/codex

test -w "${chrome_profile_dir}"
# Chrome can leave these process locks after an unclean container stop. At this
# point no user session or Chrome process exists, so removing only Singleton*
# is safe and preserves cookies, extensions, and all other authenticated state.
rm -f -- "${chrome_profile_dir}"/Singleton*

# Create gateway credentials once in the persistent machine volume. The helper
# is deliberately silent and never places generated values in process args.
/opt/codex-desktop/remote-browser/prepare-credentials.sh

exec /usr/bin/supervisord --nodaemon --configuration /etc/supervisor/supervisord.conf
