#!/usr/bin/env bash
set -Eeuo pipefail

case "${CODEX_DESKTOP_CRD_ENABLED:-1}" in
  1)
    # A fresh headless Ubuntu install must expose noVNC and MCP before the
    # optional CRD registration exists. Bootstrap on the local Xvfb/Xfce
    # session, then use CRD after registration and a deliberate restart.
    if compgen -G '/home/codex/.config/chrome-remote-desktop/host#*.json' \
      >/dev/null; then
      exec /usr/local/sbin/run-codex-crd
    fi
    exec /usr/local/sbin/run-codex-local-desktop
    ;;
  0) exec /usr/local/sbin/run-codex-local-desktop ;;
  *)
    echo 'CODEX_DESKTOP_CRD_ENABLED must be 0 or 1.' >&2
    exit 64
    ;;
esac
