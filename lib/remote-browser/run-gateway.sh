#!/usr/bin/env bash
set -Eeuo pipefail

credential_file="${REMOTE_BROWSER_CREDENTIALS_FILE:-/var/lib/codex-desktop-persistent/remote-browser/credentials.env}"
runtime_dir=/run/remote-browser
edge_config="${runtime_dir}/edge-compat.caddy"
handoff_file="${runtime_dir}/handoff-url"
origin_file="${runtime_dir}/origin"
tailscale_binary="${CODEX_TAILSCALE_BINARY:-/usr/local/bin/tailscale}"
tailscale_socket=/run/tailscale/tailscaled.sock
caddy_config=/opt/codex-desktop/remote-browser/Caddyfile
edge_config_source=/opt/codex-desktop/remote-browser/edge-compat.caddy
edge_credentials_file="${REMOTE_BROWSER_EDGE_CREDENTIALS_FILE:-}"

fail() {
  printf 'Remote browser gateway cannot start: %s\n' "$1" >&2
  exit 78
}

[[ "$(id -u)" == 0 ]] || fail 'must run as root'
[[ -f "${credential_file}" && ! -L "${credential_file}" ]] || \
  fail 'credential file is unavailable'
[[ "$(stat -c '%u:%g:%a' "${credential_file}" 2>/dev/null || true)" == \
  '0:0:600' ]] || fail 'credential file permissions are invalid'
[[ "$(stat -c '%s' "${credential_file}" 2>/dev/null || echo 99999)" -le 8192 ]] || \
  fail 'credential file is too large'

MCP_TOKEN=
LOGIN_TOKEN=
LOGIN_USERNAME=
LOGIN_PASSWORD=
LOGIN_PASSWORD_HASH=
while IFS='=' read -r key value; do
  case "${key}" in
    MCP_TOKEN) MCP_TOKEN="${value}" ;;
    LOGIN_TOKEN) LOGIN_TOKEN="${value}" ;;
    LOGIN_USERNAME) LOGIN_USERNAME="${value}" ;;
    LOGIN_PASSWORD) LOGIN_PASSWORD="${value}" ;;
    LOGIN_PASSWORD_HASH) LOGIN_PASSWORD_HASH="${value}" ;;
    '') ;;
    *) fail 'credential file contains an unknown field' ;;
  esac
done <"${credential_file}"

[[ "${MCP_TOKEN}" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || \
  fail 'MCP token is invalid'
[[ "${LOGIN_TOKEN}" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || \
  fail 'login token is invalid'
[[ "${LOGIN_USERNAME}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || \
  fail 'login username is invalid'
[[ "${LOGIN_PASSWORD_HASH}" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] || \
  fail 'login password hash is invalid'

edge_compat="${REMOTE_BROWSER_EDGE_COMPAT:-0}"
[[ "${edge_compat}" == 0 || "${edge_compat}" == 1 ]] || \
  fail 'REMOTE_BROWSER_EDGE_COMPAT must be 0 or 1'

edge_handoff_url=
edge_origin=
if [[ "${edge_compat}" == 1 ]]; then
  [[ "${tailscale_serve:-${REMOTE_BROWSER_TAILSCALE_SERVE:-0}}" != 1 ]] || \
    fail 'edge compatibility and Tailscale Serve cannot be enabled together'
  [[ -f "${edge_config_source}" && ! -L "${edge_config_source}" ]] || \
    fail 'edge compatibility configuration is unavailable'
  [[ -n "${edge_credentials_file}" && -f "${edge_credentials_file}" && \
    ! -L "${edge_credentials_file}" ]] || \
    fail 'edge compatibility credentials are unavailable'
  [[ "$(stat -c '%u:%g:%a' "${edge_credentials_file}" 2>/dev/null || true)" == \
    '0:0:600' ]] || fail 'edge compatibility credential permissions are invalid'
  [[ "$(stat -c '%s' "${edge_credentials_file}" 2>/dev/null || echo 99999)" -le 8192 ]] || \
    fail 'edge compatibility credential file is too large'
  while IFS='=' read -r key value || [[ -n "${key}${value}" ]]; do
    case "${key}" in
      LOGIN_TOKEN_URL) edge_handoff_url="${value}" ;;
      MCP_URL|MCP_TOKEN|MCP_COMPATIBILITY_URL|LOGIN_URL|LOGIN_TOKEN|LOGIN_USERNAME|LOGIN_PASSWORD|'') ;;
      *) fail 'edge compatibility credential file contains an unknown field' ;;
    esac
  done <"${edge_credentials_file}"
  if [[ "${edge_handoff_url}" =~ ^(https://[A-Za-z0-9.-]+(:[0-9]{1,5})?)/login/\?token=([A-Za-z0-9_-]{32,128})$ ]]; then
    edge_origin="${BASH_REMATCH[1]}"
  else
    fail 'edge compatibility handoff URL is invalid'
  fi
  install -o root -g codex -m 0440 "${edge_config_source}" "${edge_config}"
else
  : >"${edge_config}"
  chown root:codex "${edge_config}"
  chmod 0440 "${edge_config}"
fi
tailscale_serve="${REMOTE_BROWSER_TAILSCALE_SERVE:-1}"
[[ "${tailscale_serve}" == 0 || "${tailscale_serve}" == 1 ]] || \
  fail 'REMOTE_BROWSER_TAILSCALE_SERVE must be 0 or 1'
if [[ "${edge_compat}" == 1 && "${tailscale_serve}" != 0 ]]; then
  fail 'edge compatibility requires REMOTE_BROWSER_TAILSCALE_SERVE=0'
fi

configured_origin="${REMOTE_BROWSER_ORIGIN:-}"
if [[ -n "${configured_origin}" ]]; then
  [[ "${configured_origin}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || \
    fail 'REMOTE_BROWSER_ORIGIN must be an HTTPS origin without a path'
  origin="${configured_origin}"
else
  origin=
fi
if [[ -z "${origin}" && -n "${edge_origin}" ]]; then
  origin="${edge_origin}"
fi

tailscale_dns_name() {
  local status_json dns_name
  status_json="$(${tailscale_binary} --socket="${tailscale_socket}" status --json 2>/dev/null || true)"
  dns_name="$(jq -r '.Self.DNSName // empty' <<<"${status_json}" 2>/dev/null | sed 's/[.]$//' | head -n 1)"
  if [[ "${dns_name}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf '%s\n' "${dns_name}"
  fi
}

dns_name="$(tailscale_dns_name)"
if [[ -z "${origin}" && -n "${dns_name}" ]]; then
  origin="https://${dns_name}"
fi
origin="${origin:-https://remote-browser.invalid}"
if [[ -n "${edge_origin}" && "${origin}" != "${edge_origin}" ]]; then
  fail 'configured origin does not match the existing edge handoff URL'
fi
handoff_url="${origin}/login/?token=${LOGIN_TOKEN}"
if [[ -n "${edge_handoff_url}" ]]; then
  handoff_url="${edge_handoff_url}"
fi

export REMOTE_BROWSER_MCP_TOKEN="${MCP_TOKEN}"
export REMOTE_BROWSER_LOGIN_TOKEN="${LOGIN_TOKEN}"
export REMOTE_BROWSER_LOGIN_USERNAME="${LOGIN_USERNAME}"
export REMOTE_BROWSER_LOGIN_PASSWORD_HASH="${LOGIN_PASSWORD_HASH}"

/usr/bin/caddy validate --config "${caddy_config}" --adapter caddyfile >/dev/null

umask 077
printf '%s\n' "${origin}" >"${origin_file}"
printf '%s\n' "${handoff_url}" >"${handoff_file}"
chown root:codex "${origin_file}" "${handoff_file}"
chmod 0440 "${origin_file}" "${handoff_file}"

setpriv \
  --reuid=10001 \
  --regid=10001 \
  --init-groups \
  env \
    HOME=/home/codex \
    USER=codex \
    LOGNAME=codex \
    XDG_CONFIG_HOME=/home/codex/.config \
    XDG_DATA_HOME=/home/codex/.local/share \
    REMOTE_BROWSER_MCP_TOKEN="${MCP_TOKEN}" \
    REMOTE_BROWSER_LOGIN_TOKEN="${LOGIN_TOKEN}" \
    REMOTE_BROWSER_LOGIN_USERNAME="${LOGIN_USERNAME}" \
    REMOTE_BROWSER_LOGIN_PASSWORD_HASH="${LOGIN_PASSWORD_HASH}" \
    /usr/bin/caddy run --config "${caddy_config}" --adapter caddyfile &
caddy_pid=$!

terminate() {
  trap - TERM INT HUP
  if kill -0 "${caddy_pid}" 2>/dev/null; then
    kill -TERM "${caddy_pid}" 2>/dev/null || true
    wait "${caddy_pid}" 2>/dev/null || true
  fi
  exit 0
}
trap terminate TERM INT HUP

if [[ "${tailscale_serve}" == 1 ]]; then
  while kill -0 "${caddy_pid}" 2>/dev/null; do
    dns_name="$(tailscale_dns_name)"
    if [[ -n "${dns_name}" ]] && \
      ${tailscale_binary} --socket="${tailscale_socket}" serve \
        --bg --yes --https=443 http://127.0.0.1:8443 >/dev/null 2>&1; then
      if [[ -z "${configured_origin}" ]]; then
        origin="https://${dns_name}"
        handoff_url="${origin}/login/?token=${LOGIN_TOKEN}"
        umask 077
        printf '%s\n' "${origin}" >"${origin_file}"
        printf '%s\n' "${handoff_url}" >"${handoff_file}"
        chown root:codex "${origin_file}" "${handoff_file}"
        chmod 0440 "${origin_file}" "${handoff_file}"
      fi
      break
    fi
    sleep 5
  done
fi

set +e
wait "${caddy_pid}"
status=$?
set -e
exit "${status}"
