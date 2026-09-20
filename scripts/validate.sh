#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

bash -n \
  configure-crd.sh \
  configure-novnc.sh \
  entrypoint.sh \
  healthcheck.sh \
  lib/remote-browser/prepare-credentials.sh \
  lib/remote-browser/remote-browser-credentials \
  lib/remote-browser/remote-browser-extension-token \
  lib/remote-browser/run-gateway.sh \
  lib/remote-browser/run-playwright-mcp.sh \
  run-session.sh \
  run-local-desktop.sh \
  run-codex.sh \
  run-crd.sh \
  run-chrome.sh \
  run-novnc.sh \
  run-x11vnc.sh \
  start-host-wrapper.sh \
  scripts/install.sh \
  scripts/install-functional-canary.sh \
  scripts/install-macos.sh \
  scripts/remote-browser-functional-canary.sh \
  scripts/verify-deployment.sh \
  scripts/verify-macos.sh \
  tests/bootstrap-contract.test.sh \
  tests/chrome-launch.test.sh \
  tests/codex-launch.test.sh \
  tests/container-runtime-contract.test.sh \
  tests/install-contract.test.sh \
  tests/local-session-contract.test.sh \
  tests/novnc-contract.test.sh \
  tests/remote-browser-gateway-contract.test.sh \
  tests/session-handoff.test.sh \
  tests/unified-remote-browser-contract.test.sh \
  tests/run.sh \
  scripts/validate.sh
sh -n bootstrap.sh
sh -n chrome-remote-desktop-session
node --check tests/live-guest-funnel-regression.cjs

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    chrome-remote-desktop-session \
    configure-crd.sh \
    configure-novnc.sh \
    entrypoint.sh \
    healthcheck.sh \
    lib/remote-browser/prepare-credentials.sh \
    lib/remote-browser/remote-browser-credentials \
    lib/remote-browser/remote-browser-extension-token \
    lib/remote-browser/run-gateway.sh \
    lib/remote-browser/run-playwright-mcp.sh \
    run-session.sh \
    run-local-desktop.sh \
    run-codex.sh \
    run-crd.sh \
    run-chrome.sh \
    run-novnc.sh \
    run-x11vnc.sh \
    start-host-wrapper.sh \
    scripts/install.sh \
    scripts/install-functional-canary.sh \
    scripts/install-macos.sh \
    scripts/remote-browser-functional-canary.sh \
    scripts/verify-deployment.sh \
    scripts/verify-macos.sh \
    tests/bootstrap-contract.test.sh \
    tests/chrome-launch.test.sh \
    tests/codex-launch.test.sh \
    tests/container-runtime-contract.test.sh \
    tests/install-contract.test.sh \
    tests/local-session-contract.test.sh \
    tests/novnc-contract.test.sh \
    tests/remote-browser-gateway-contract.test.sh \
    tests/session-handoff.test.sh \
    tests/unified-remote-browser-contract.test.sh \
    tests/run.sh \
    scripts/validate.sh
  shellcheck --shell=sh bootstrap.sh
else
  echo "shellcheck is unavailable; skipped" >&2
fi

bash tests/run.sh

docker compose \
  --env-file deploy.env.example \
  -f compose.yaml \
  config --quiet
docker compose \
  --env-file deploy.env.example \
  -f compose.yaml \
  -f compose.macos.yaml \
  config --quiet
docker compose \
  --env-file deploy.env.example \
  -f compose.yaml \
  -f compose.codexgui.yaml \
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

case "$(uname -m)" in
  x86_64|amd64)
    docker buildx build --check --progress=plain .
    ;;
  *)
    echo "Dockerfile build check skipped on non-AMD64 host; run the AMD64 image build separately" >&2
    ;;
esac
