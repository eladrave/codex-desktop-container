#!/usr/bin/env bash
set -Eeuo pipefail

token_file="${REMOTE_BROWSER_EXTENSION_TOKEN_FILE:-/home/codex/.config/remote-browser/extension-token}"
handoff_file=/run/remote-browser/handoff-url
chrome_profile="${CODEX_CHROME_PROFILE_DIR:-/home/codex/.config/google-chrome}"
extension_timeout="${REMOTE_BROWSER_EXTENSION_CONNECT_TIMEOUT_MS:-30000}"

fail() {
  printf 'Playwright MCP cannot start: %s\n' "$1" >&2
  exit 78
}

[[ "$(id -u)" == 10001 ]] || fail 'must run as the codex user'
[[ "${extension_timeout}" =~ ^[0-9]+$ ]] || \
  fail 'extension timeout must be numeric'
(( extension_timeout >= 5000 && extension_timeout <= 120000 )) || \
  fail 'extension timeout must be between 5000 and 120000 milliseconds'

extension_token="${PLAYWRIGHT_MCP_EXTENSION_TOKEN:-}"
if [[ -z "${extension_token}" ]]; then
  while [[ ! -f "${token_file}" ]]; do
    [[ ! -e "${token_file}" && ! -L "${token_file}" ]] || \
      fail 'extension token path is not a regular file'
    sleep 2
  done
  [[ ! -L "${token_file}" ]] || fail 'extension token file cannot be a symlink'
  [[ "$(stat -c '%u:%g:%a' "${token_file}" 2>/dev/null || true)" == \
    '10001:10001:600' ]] || fail 'extension token file permissions are invalid'
  [[ "$(stat -c '%s' "${token_file}" 2>/dev/null || echo 99999)" -le 1024 ]] || \
    fail 'extension token file is too large'
  extension_token="$(<"${token_file}")"
fi
[[ ${#extension_token} -ge 16 && ${#extension_token} -le 1024 && \
  "${extension_token}" =~ ^[[:graph:]]+$ ]] || \
  fail 'extension token does not meet the required format'

for _ in $(seq 1 60); do
  if [[ -f "${handoff_file}" && ! -L "${handoff_file}" ]] && \
    [[ "$(stat -c '%u:%g:%a' "${handoff_file}" 2>/dev/null || true)" == \
      '0:10001:440' ]]; then
    break
  fi
  sleep 2
done
[[ -r "${handoff_file}" ]] || fail 'gateway handoff data was not ready in time'
[[ -d "${chrome_profile}" && -w "${chrome_profile}" ]] || \
  fail 'persistent Chrome profile is unavailable'

profile_args=()
if [[ -n "${REMOTE_BROWSER_CHROME_PROFILE_NAME:-}" ]]; then
  profile_name_pattern='^[A-Za-z0-9_. -]{1,80}$'
  [[ "${REMOTE_BROWSER_CHROME_PROFILE_NAME}" =~ ${profile_name_pattern} ]] || \
    fail 'Chrome profile name is invalid'
  profile_args+=(--profile-dir-name "${REMOTE_BROWSER_CHROME_PROFILE_NAME}")
fi

export PLAYWRIGHT_MCP_EXTENSION_TOKEN="${extension_token}"
export PWTEST_EXTENSION_CONNECT_TIMEOUT="${extension_timeout}"
export REMOTE_CHROME_LOGIN_TOKEN_URL_FILE="${handoff_file}"
export NODE_OPTIONS="--require=/opt/codex-desktop/remote-browser/inject-instructions.cjs${NODE_OPTIONS:+ ${NODE_OPTIONS}}"
export NODE_PATH=/usr/local/lib/node_modules/@playwright/mcp/node_modules:/usr/local/lib/node_modules

exec /usr/local/bin/playwright-mcp \
  --extension \
  --browser chrome \
  --executable-path /usr/bin/google-chrome-stable \
  --user-data-dir "${chrome_profile}" \
  --host 127.0.0.2 \
  --port 8932 \
  --allowed-hosts=* \
  --shared-browser-context \
  --idle-timeout 0 \
  "${profile_args[@]}"
