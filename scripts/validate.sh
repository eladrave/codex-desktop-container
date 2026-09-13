#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

bash -n \
  configure-crd.sh \
  entrypoint.sh \
  healthcheck.sh \
  run-crd.sh \
  start-host-wrapper.sh \
  scripts/validate.sh
sh -n chrome-remote-desktop-session

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    chrome-remote-desktop-session \
    configure-crd.sh \
    entrypoint.sh \
    healthcheck.sh \
    run-crd.sh \
    start-host-wrapper.sh \
    scripts/validate.sh
else
  echo "shellcheck is unavailable; skipped" >&2
fi

docker compose \
  --env-file deploy.env.example \
  -f compose.yaml \
  config --quiet

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify codex-desktop.service
else
  echo "systemd-analyze is unavailable; skipped" >&2
fi

if command -v apparmor_parser >/dev/null 2>&1; then
  apparmor_parser --skip-kernel-load --skip-cache apparmor-chatgpt
else
  echo "apparmor_parser is unavailable; skipped" >&2
fi

docker buildx build --check --progress=plain .
