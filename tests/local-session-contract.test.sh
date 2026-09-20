#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

grep -Fq 'exec /usr/local/sbin/run-codex-crd' run-session.sh
grep -Fq 'exec /usr/local/sbin/run-codex-local-desktop' run-session.sh
grep -Fq 'Xvfb "${display}"' run-local-desktop.sh
grep -Fq -- '-nolisten tcp' run-local-desktop.sh
grep -Fq 'dbus-run-session -- xfce4-session' run-local-desktop.sh
grep -Fq 'DISPLAY=%s\nXAUTHORITY=%s\n' run-local-desktop.sh
grep -Fq '[program:desktop-session]' supervisord.conf
grep -Fq 'CODEX_DESKTOP_CRD_ENABLED: "${CODEX_DESKTOP_CRD_ENABLED:-1}"' compose.yaml
grep -Fq 'CODEX_DESKTOP_CRD_ENABLED: "0"' compose.macos.yaml
if grep -Fq '[program:chrome-remote-desktop]' supervisord.conf; then
  echo 'Supervisor must use the platform-selecting desktop session wrapper.' >&2
  exit 1
fi
