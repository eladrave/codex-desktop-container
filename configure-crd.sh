#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  exec setpriv \
    --reuid=10001 \
    --regid=10001 \
    --init-groups \
    env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
    /usr/local/bin/configure-chrome-remote-desktop "$@"
fi

if [[ "$(id -u)" -ne 10001 ]]; then
  echo "Run this command as the codex desktop user." >&2
  exit 1
fi

set +e
/opt/google/chrome-remote-desktop/start-host "$@"
status=$?
set -e

if compgen -G '/home/codex/.config/chrome-remote-desktop/host#*.json' >/dev/null; then
  echo "Chrome Remote Desktop registration is present; the supervised host will start automatically."
  exit 0
fi

exit "${status}"
