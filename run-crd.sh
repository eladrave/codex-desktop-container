#!/usr/bin/env bash
set -Eeuo pipefail

config_dir=/home/codex/.config/chrome-remote-desktop

while ! compgen -G "${config_dir}/host#*.json" >/dev/null; do
  sleep 5
done

exec /opt/google/chrome-remote-desktop/chrome-remote-desktop \
  --start \
  --child-process \
  --foreground
