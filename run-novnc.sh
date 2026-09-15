#!/usr/bin/env bash
set -Eeuo pipefail

tailscale_binary="${CODEX_TAILSCALE_BINARY:-/usr/local/bin/tailscale}"
websockify_binary="${CODEX_WEBSOCKIFY_BINARY:-/usr/bin/websockify}"
check_interval="${CODEX_NOVNC_CHECK_INTERVAL:-5}"

[[ "${check_interval}" =~ ^[0-9]+$ ]] || {
  echo "Invalid noVNC address-check interval." >&2
  exit 64
}

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

child_pid=
# Invoked indirectly by the signal trap below.
# shellcheck disable=SC2317,SC2329
terminate() {
  trap - TERM INT HUP
  if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
    kill -TERM "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true
  fi
  exit 0
}
trap terminate TERM INT HUP

setpriv \
  --reuid=10001 \
  --regid=10001 \
  --init-groups \
  env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
  "${websockify_binary}" \
    --web=/usr/share/novnc/ \
    "${tailscale_ip}:6080" \
    127.0.0.1:5900 &
child_pid=$!

while kill -0 "${child_pid}" 2>/dev/null; do
  sleep "${check_interval}"
  current_ip="$(get_tailscale_ip)"
  if [[ "${current_ip}" != "${tailscale_ip}" ]]; then
    kill -TERM "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true
    exit 75
  fi
done

set +e
wait "${child_pid}"
status=$?
set -e
exit "${status}"
