#!/usr/bin/env bash
set -Eeuo pipefail

container_name=codex-desktop-desktop-1
config_file=/etc/codex-desktop/deploy.env
compose_file=/opt/services/codex-desktop/compose.yaml
allow_incomplete=0
credentials_dir=/var/lib/codex-desktop-persistent/remote-browser
credentials_file=${credentials_dir}/credentials.env
extension_token_file=/home/codex/.config/remote-browser/extension-token

usage() {
  echo 'Usage: sudo verify-deployment.sh [--allow-incomplete]'
}

case "${1:-}" in
  '') ;;
  --allow-incomplete) allow_incomplete=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 64; }

[[ ${EUID} -eq 0 ]] || {
  echo 'Run with sudo or as root.' >&2
  exit 1
}

systemctl is-enabled --quiet codex-desktop.service
systemctl is-active --quiet codex-desktop.service
docker compose --project-name codex-desktop \
  --env-file "${config_file}" -f "${compose_file}" config --quiet
[[ -s /opt/services/codex-desktop/REVISION ]]
deployed_revision="$(</opt/services/codex-desktop/REVISION)"
[[ "${deployed_revision}" =~ ^[0-9a-f]{40}$ ]]
container_image_id="$(docker inspect "${container_name}" --format '{{.Image}}')"
image_revision="$(docker image inspect "${container_image_id}" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
[[ "${image_revision}" == "${deployed_revision}" ]]
crd_enabled="$(sed -n 's/^CODEX_DESKTOP_CRD_ENABLED=//p' "${config_file}" | tail -n 1)"
[[ "${crd_enabled}" == 0 || "${crd_enabled}" == 1 ]]
image_crd_enabled="$(docker image inspect "${container_image_id}" \
  --format '{{index .Config.Labels "io.google.chrome-remote-desktop.enabled"}}')"
[[ "${image_crd_enabled}" == "${crd_enabled}" ]]

state="$(docker inspect "${container_name}" \
  --format '{{.State.Status}} {{.State.Health.Status}} {{json .NetworkSettings.Ports}}')"
[[ "${state}" == 'running healthy {}' ]]

docker exec "${container_name}" /usr/local/sbin/codex-desktop-healthcheck
docker exec "${container_name}" supervisorctl status
packages=(chatgpt google-chrome-stable novnc websockify x11vnc)
if [[ "${crd_enabled}" == 1 ]]; then
  packages+=(chrome-remote-desktop)
fi
docker exec "${container_name}" dpkg-query -W "${packages[@]}"
[[ "$(docker exec "${container_name}" dpkg --print-architecture)" == amd64 ]]
[[ "$(docker exec "${container_name}" node -p process.arch)" == x64 ]]
[[ "$(docker exec "${container_name}" playwright-mcp --version)" == \
  'Version 0.0.82' ]]
for native_binary in /usr/local/bin/node /usr/bin/caddy; do
  [[ "$(docker exec "${container_name}" sh -c \
    "od -An -tx1 -j18 -N2 '${native_binary}' | tr -d ' \\n'")" == 3e00 ]]
done
[[ "$(docker compose --project-name codex-desktop \
  --env-file "${config_file}" -f "${compose_file}" ps -q | wc -l | tr -d ' ')" == 1 ]]

docker exec "${container_name}" test -d "${credentials_dir}"
[[ "$(docker exec "${container_name}" stat -c '%u:%g:%a' "${credentials_dir}")" == \
  '0:0:700' ]]
docker exec "${container_name}" test -f "${credentials_file}"
[[ "$(docker exec "${container_name}" stat -c '%u:%g:%a' "${credentials_file}")" == \
  '0:0:600' ]]
docker exec "${container_name}" test -x /usr/local/bin/remote-browser-credentials
docker exec "${container_name}" test -x /usr/local/bin/remote-browser-extension-token
docker exec "${container_name}" supervisorctl status remote-browser-gateway | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
docker exec "${container_name}" supervisorctl status remote-browser-guest-access | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
[[ "$(docker exec "${container_name}" stat -c '%u:%g:%a' \
  /run/remote-browser/guest-control.sock)" == '0:10001:660' ]]
[[ "$(docker exec "${container_name}" stat -c '%u:%g:%a' \
  /run/remote-browser/guest-status.json)" == '0:10001:440' ]]

listeners="$(docker exec "${container_name}" ss -lntH)"
for expected_listener in \
  '127.0.0.1:8443' \
  '127.0.0.2:5900' \
  '127.0.0.2:6081'; do
  grep -Eq "[[:space:]]${expected_listener//./\\.}[[:space:]]" <<<"${listeners}"
done
if awk '$4 ~ /:9222$/ { found=1 } END { exit !found }' <<<"${listeners}"; then
  echo 'A process is listening on forbidden Chrome debugging port 9222.' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|:::):(5900|6081|8932|8443|8444)([[:space:]]|$)' \
  <<<"${listeners}"; then
  echo 'A remote-browser service is listening on a wildcard address.' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])\[[^]]+\]:(5900|6081|8932|8443|8444)([[:space:]]|$)' \
  <<<"${listeners}"; then
  echo 'A remote-browser service is listening on IPv6.' >&2
  exit 1
fi
if docker exec "${container_name}" pgrep -af 'chrome|chromium' | \
  grep -Eq -- '--remote-debugging-port(=|[[:space:]])'; then
  echo 'Chrome was started with a forbidden remote debugging port.' >&2
  exit 1
fi

[[ "$(docker exec "${container_name}" curl -sS -o /dev/null -w '%{http_code}' \
  http://127.0.0.1:8443/healthz)" == 200 ]]
[[ "$(docker exec "${container_name}" curl -sS -o /dev/null -w '%{http_code}' \
  -X POST http://127.0.0.1:8443/mcp)" == 401 ]]
[[ "$(docker exec "${container_name}" curl -sS -o /dev/null -w '%{http_code}' \
  http://127.0.0.1:8443/mcp)" == 405 ]]
[[ "$(docker exec "${container_name}" curl -sS -o /dev/null -w '%{http_code}' \
  http://127.0.0.1:8443/login/)" == 401 ]]
docker exec "${container_name}" tailscale serve status --json | \
  grep -Fq '127.0.0.1:8443'

tailscale_summary="$(
  docker exec "${container_name}" tailscale status --json |
    jq -c '{BackendState,CurrentTailnet,Self:{DNSName:.Self.DNSName,TailscaleIPs:.Self.TailscaleIPs,Online:.Self.Online,Tags:.Self.Tags}}'
)"
[[ "$(jq -r '.BackendState' <<<"${tailscale_summary}")" == Running ]]
printf 'Tailscale: %s\n' "${tailscale_summary}"
docker exec "${container_name}" test ! -e /run/secrets/tailscale-auth-key

crd_status=NOT_INSTALLED
crd_incomplete=0
if [[ "${crd_enabled}" == 1 ]]; then
  crd_status=NOT_REGISTERED
  if docker exec "${container_name}" \
    bash -c "compgen -G '/home/codex/.config/chrome-remote-desktop/host#*.json' >/dev/null"; then
    crd_status="$(
      docker exec "${container_name}" \
        setpriv --reuid=10001 --regid=10001 --init-groups \
        env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
        /opt/google/chrome-remote-desktop/chrome-remote-desktop --get-status
    )"
    [[ "${crd_status}" == STARTED ]]
  fi
  if [[ "${crd_status}" != STARTED ]]; then
    crd_incomplete=1
    if [[ "${allow_incomplete}" == 0 ]]; then
      echo 'Chrome Remote Desktop is not registered and STARTED.' >&2
      exit 1
    fi
  fi
else
  docker exec "${container_name}" sh -c \
    '! dpkg-query -W chrome-remote-desktop >/dev/null 2>&1 && test ! -e /opt/google/chrome-remote-desktop'
  docker exec "${container_name}" pgrep -u 10001 -x Xvfb >/dev/null
fi
printf 'Chrome Remote Desktop: %s\n' "${crd_status}"

extension_configured=0
if docker exec "${container_name}" test -s "${extension_token_file}"; then
  [[ "$(docker exec "${container_name}" stat -c '%u:%g:%a' \
    "${extension_token_file}")" == '10001:10001:600' ]]
  docker exec "${container_name}" supervisorctl status playwright-mcp | \
    grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
  grep -Eq '[[:space:]]127\.0\.0\.2:8932[[:space:]]' <<<"${listeners}"
  extension_configured=1
  printf 'Playwright MCP extension token: configured\n'
else
  docker exec "${container_name}" supervisorctl status playwright-mcp | \
    grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
  if awk '$4 ~ /:8932$/ { found=1 } END { exit !found }' <<<"${listeners}"; then
    echo 'MCP backend is listening before its extension token is configured.' >&2
    exit 1
  fi
  printf 'Playwright MCP extension token: not configured\n'
fi
if [[ "${extension_configured}" == 0 && "${allow_incomplete}" == 0 ]]; then
  echo 'Playwright MCP extension token is not configured.' >&2
  exit 1
fi

if [[ "${allow_incomplete}" == 1 && \
  ("${crd_incomplete}" == 1 || "${extension_configured}" == 0) ]]; then
  printf 'Base deployment checks passed; user-only setup remains incomplete.\n'
else
  printf 'Codex Desktop deployment verification passed.\n'
fi
