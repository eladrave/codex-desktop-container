#!/usr/bin/env bash
set -Eeuo pipefail

credential_dir=/var/lib/codex-desktop-persistent/remote-browser
credential_file="${REMOTE_BROWSER_CREDENTIALS_FILE:-${credential_dir}/credentials.env}"

fail() {
  printf 'Remote browser credential initialization failed: %s\n' "$1" >&2
  exit 78
}

[[ "$(id -u)" == 0 ]] || fail 'must run as root'
[[ "${credential_file}" == "${credential_dir}/credentials.env" ]] || \
  fail 'credential path must use the persistent machine directory'

install -d -o root -g root -m 0700 "${credential_dir}"
[[ ! -L "${credential_dir}" ]] || fail 'credential directory cannot be a symlink'

if [[ -e "${credential_file}" ]]; then
  [[ -f "${credential_file}" && ! -L "${credential_file}" ]] || \
    fail 'credential file is not a regular file'
  [[ "$(stat -c '%u:%g:%a' "${credential_file}" 2>/dev/null || true)" == \
    '0:0:600' ]] || fail 'credential file permissions are invalid'
  [[ "$(stat -c '%s' "${credential_file}" 2>/dev/null || echo 99999)" -le 8192 ]] || \
    fail 'credential file is too large'
  exit 0
fi

random_hex() {
  /usr/local/bin/node -e \
    'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))'
}

random_password() {
  /usr/local/bin/node -e \
    'process.stdout.write(require("node:crypto").randomBytes(32).toString("base64url"))'
}

mcp_token="${REMOTE_BROWSER_MCP_TOKEN:-$(random_hex)}"
login_token="${REMOTE_BROWSER_LOGIN_TOKEN:-$(random_hex)}"
login_username="${REMOTE_BROWSER_LOGIN_USERNAME:-remotechrome}"
login_password="${REMOTE_BROWSER_LOGIN_PASSWORD:-$(random_password)}"

[[ "${mcp_token}" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || \
  fail 'MCP token does not meet the required format'
[[ "${login_token}" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || \
  fail 'login token does not meet the required format'
[[ "${login_username}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || \
  fail 'login username does not meet the required format'
[[ ${#login_password} -ge 20 && ${#login_password} -le 128 && \
  "${login_password}" =~ ^[[:graph:]]+$ ]] || \
  fail 'login password does not meet the required format'

login_password_hash="$({ printf '%s\n' "${login_password}"; } | \
  /usr/bin/caddy hash-password --algorithm bcrypt)"
[[ "${login_password_hash}" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] || \
  fail 'could not hash the login password'

umask 077
temporary_file="$(mktemp "${credential_dir}/.credentials.XXXXXX")"
cleanup() {
  if [[ -n "${temporary_file:-}" && -e "${temporary_file}" ]]; then
    shred -u "${temporary_file}" 2>/dev/null || unlink "${temporary_file}"
  fi
}
trap cleanup EXIT

printf '%s\n' \
  "MCP_TOKEN=${mcp_token}" \
  "LOGIN_TOKEN=${login_token}" \
  "LOGIN_USERNAME=${login_username}" \
  "LOGIN_PASSWORD=${login_password}" \
  "LOGIN_PASSWORD_HASH=${login_password_hash}" \
  >"${temporary_file}"
chown root:root "${temporary_file}"
chmod 0600 "${temporary_file}"
mv -f "${temporary_file}" "${credential_file}"
temporary_file=
trap - EXIT
