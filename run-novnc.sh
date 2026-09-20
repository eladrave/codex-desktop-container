#!/usr/bin/env bash
set -Eeuo pipefail

websockify_binary="${CODEX_WEBSOCKIFY_BINARY:-/usr/bin/websockify}"

exec setpriv \
  --reuid=10001 \
  --regid=10001 \
  --init-groups \
  env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
  "${websockify_binary}" \
    --web=/usr/share/novnc/ \
    127.0.0.2:6081 \
    127.0.0.2:5900
