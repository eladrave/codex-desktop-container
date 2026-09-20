#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

node --test \
  tests/guest-session-proxy.test.cjs \
  tests/mcp-session-regression.test.cjs
PYTHONDONTWRITEBYTECODE=1 python3 tests/guest-access-broker.test.py

for test_script in \
  tests/bootstrap-contract.test.sh \
  tests/chrome-launch.test.sh \
  tests/codex-launch.test.sh \
  tests/container-runtime-contract.test.sh \
  tests/install-contract.test.sh \
  tests/local-session-contract.test.sh \
  tests/mcp-keeper-contract.test.sh \
  tests/novnc-contract.test.sh \
  tests/session-handoff.test.sh \
  tests/unified-remote-browser-contract.test.sh \
  tests/remote-browser-gateway-contract.test.sh; do
  bash "${test_script}"
done
