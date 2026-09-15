#!/usr/bin/env bash
set -Eeuo pipefail

case "${CODEX_DESKTOP_CRD_ENABLED:-1}" in
  1) exec /usr/local/sbin/run-codex-crd ;;
  0) exec /usr/local/sbin/run-codex-local-desktop ;;
  *)
    echo 'CODEX_DESKTOP_CRD_ENABLED must be 0 or 1.' >&2
    exit 64
    ;;
esac
