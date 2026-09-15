#!/usr/bin/env bash
set -Eeuo pipefail

tailscale_binary="${CODEX_TAILSCALE_BINARY:-/usr/local/bin/tailscale}"
websockify_binary="${CODEX_WEBSOCKIFY_BINARY:-/usr/bin/websockify}"

get_tailscale_ip() {
  "${tailscale_binary}" \
    --socket=/run/tailscale/tailscaled.sock \
    ip -4 2>/dev/null | head -n 1 || true
}

while true; do
  tailscale_ip="$(get_tailscale_ip)"
  if [[ "${tailscale_ip}" =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    break
  fi
  sleep 5
done

exec setpriv \
  --reuid=10001 \
  --regid=10001 \
  --init-groups \
  env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
  "${websockify_binary}" \
    --web=/usr/share/novnc/ \
    127.0.0.1:6080 \
    127.0.0.2:5900
