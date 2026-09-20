#!/usr/bin/env bash
set -Eeuo pipefail

container_name=codex-desktop-desktop-1
token_file=/run/remote-browser/functional-canary-token
credential_file=/var/lib/codex-desktop-persistent/remote-browser/credentials.env
endpoint=http://127.0.0.1:8443/mcp

fail() {
  printf 'Remote browser functional canary failed: %s\n' "$1" >&2
  exit 1
}

[[ "$#" == 0 ]] || fail 'this command accepts no arguments'
command -v docker >/dev/null 2>&1 || fail 'docker is unavailable'

case "$(uname -s)" in
  Linux)
    [[ ${EUID} -eq 0 ]] || fail 'run as root on Linux'
    regression_script=/opt/services/codex-desktop/tests/mcp-session-regression.cjs
    ;;
  Darwin)
    [[ ${EUID} -ne 0 ]] || fail 'run as the installed macOS user, not root'
    export PATH="${HOME}/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    regression_script=${HOME}/.local/share/codex-desktop/source/tests/mcp-session-regression.cjs
    ;;
  *) fail 'unsupported host platform' ;;
esac

[[ -f "${regression_script}" && ! -L "${regression_script}" ]] || \
  fail 'the installed MCP regression client is unavailable'
docker inspect "${container_name}" --format '{{.State.Running}}' 2>/dev/null | \
  grep -Fqx true || fail 'the Codex Desktop container is not running'
lock_dir="${TMPDIR:-/tmp}/codex-desktop-mcp-canary.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'Remote browser functional canary skipped: another run is active.\n'
  exit 0
fi

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  docker exec "${container_name}" rm -f -- "${token_file}" >/dev/null 2>&1 || true
  rmdir "${lock_dir}" >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT HUP INT TERM

docker exec "${container_name}" sh -eu -c '
  credential_file=$1
  token_file=$2
  test -f "$credential_file" && test ! -L "$credential_file"
  test "$(stat -c "%u:%g:%a" "$credential_file")" = 0:0:600
  umask 077
  awk -F= '\''$1 == "MCP_TOKEN" { print substr($0, index($0, "=") + 1); exit }'\'' \
    "$credential_file" >"$token_file"
  test -s "$token_file"
' sh "${credential_file}" "${token_file}"

docker exec -i "${container_name}" node - \
  --endpoint "${endpoint}" \
  --bearer-token-file "${token_file}" \
  --snapshot-only \
  --timeout-seconds 60 \
  <"${regression_script}"
