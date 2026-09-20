#!/usr/bin/env bash
set -Eeuo pipefail

browser_runtime="${REMOTE_BROWSER_RUNTIME_DIR:-/run/remote-browser/browser}"
browser_endpoint="${REMOTE_BROWSER_BROWSER_ENDPOINT:-${browser_runtime}/endpoint.sock}"
keeper_ready_file="${REMOTE_BROWSER_KEEPER_READY_FILE:-${browser_runtime}/keeper.ready}"
handoff_file=/run/remote-browser/handoff-url

fail() {
  printf 'Playwright MCP cannot start: %s\n' "$1" >&2
  exit 78
}

[[ "$(id -u)" == 10001 ]] || fail 'must run as the codex user'
[[ -d "${browser_runtime}" && ! -L "${browser_runtime}" ]] || \
  fail 'private browser runtime directory is unavailable'
[[ "$(stat -c '%u:%g:%a' "${browser_runtime}" 2>/dev/null || true)" == \
  '10001:10001:700' ]] || fail 'private browser runtime permissions are invalid'
rm -f -- "${keeper_ready_file}"

for _ in $(seq 1 120); do
  if [[ -L "${browser_endpoint}" ]]; then
    resolved_endpoint="$(readlink -f -- "${browser_endpoint}" 2>/dev/null || true)"
    if [[ "${resolved_endpoint}" == "${browser_runtime}"/* && \
      -S "${resolved_endpoint}" && \
      "$(stat -c '%u:%g:%a' "${resolved_endpoint}" 2>/dev/null || true)" == \
        '10001:10001:600' ]]; then
      break
    fi
  fi
  resolved_endpoint=
  sleep 1
done
[[ -n "${resolved_endpoint:-}" ]] || fail 'bound browser endpoint was not ready in time'

for _ in $(seq 1 60); do
  if [[ -f "${handoff_file}" && ! -L "${handoff_file}" ]] && \
    [[ "$(stat -c '%u:%g:%a' "${handoff_file}" 2>/dev/null || true)" == \
      '0:10001:440' ]]; then
    break
  fi
  sleep 2
done
[[ -r "${handoff_file}" ]] || fail 'gateway handoff data was not ready in time'

export REMOTE_CHROME_LOGIN_TOKEN_URL_FILE="${handoff_file}"
export NODE_OPTIONS="--require=/opt/codex-desktop/remote-browser/inject-instructions.cjs${NODE_OPTIONS:+ ${NODE_OPTIONS}}"
export NODE_PATH=/usr/local/lib/node_modules/@playwright/mcp/node_modules:/usr/local/lib/node_modules

exec /usr/local/bin/playwright-mcp \
  --endpoint "${browser_endpoint}" \
  --host 127.0.0.2 \
  --port 8932 \
  --allowed-hosts=* \
  --shared-browser-context \
  --idle-timeout 0
