#!/usr/bin/env bash
set -Eeuo pipefail

install_root="${HOME}/.local/share/codex-desktop"
source_dir="${install_root}/source"
config_file="${install_root}/deploy.env"
container_name=codex-desktop-desktop-1
allow_incomplete=0
credentials_dir=/var/lib/codex-desktop-persistent/remote-browser
credentials_file=${credentials_dir}/credentials.env
extension_token_file=/home/codex/.config/remote-browser/extension-token

usage() {
  echo 'Usage: verify-macos.sh [--allow-incomplete]'
}

case "${1:-}" in
  '') ;;
  --allow-incomplete) allow_incomplete=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 64; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'This verifier supports Apple silicon macOS.' >&2
  exit 1
}

docker info >/dev/null
docker compose --project-name codex-desktop \
  --env-file "${config_file}" \
  -f "${source_dir}/compose.yaml" \
  -f "${source_dir}/compose.macos.yaml" \
  config --quiet

[[ -s "${source_dir}/REVISION" ]]
deployed_revision="$(<"${source_dir}/REVISION")"
[[ "${deployed_revision}" =~ ^[0-9a-f]{40}$ ]]
container_image_id="$(docker inspect "${container_name}" --format '{{.Image}}')"
image_revision="$(docker image inspect "${container_image_id}" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
[[ "${image_revision}" == "${deployed_revision}" ]]
[[ "$(docker image inspect "${container_image_id}" \
  --format '{{index .Config.Labels "io.tailscale.binary.arch"}}')" == arm64 ]]
[[ "$(docker image inspect "${container_image_id}" \
  --format '{{index .Config.Labels "io.codex-desktop.image.arch"}}')" == arm64 ]]
[[ "$(docker image inspect "${container_image_id}" \
  --format '{{index .Config.Labels "io.google.chrome-remote-desktop.enabled"}}')" == 0 ]]
[[ "$(docker image inspect "${container_image_id}" --format '{{.Architecture}}')" == arm64 ]]

state="$(docker inspect "${container_name}" \
  --format '{{.State.Status}} {{.State.Health.Status}} {{json .NetworkSettings.Ports}}')"
[[ "${state}" == 'running healthy {}' ]]
mounts="$(docker inspect "${container_name}" \
  --format '{{range .Mounts}}{{println .Type .Name .Destination}}{{end}}')"
grep -Fqx 'volume codex-desktop-home /home/codex' <<<"${mounts}"
grep -Fqx 'volume codex-desktop-tailscale /var/lib/tailscale' <<<"${mounts}"
grep -Fqx 'volume codex-desktop-machine /var/lib/codex-desktop-persistent' <<<"${mounts}"

docker exec "${container_name}" /usr/local/sbin/codex-desktop-healthcheck
docker exec "${container_name}" supervisorctl status
docker exec "${container_name}" dpkg-query -W \
  chatgpt google-chrome-stable novnc websockify x11vnc xvfb
[[ "$(docker exec "${container_name}" dpkg --print-architecture)" == arm64 ]]
[[ "$(docker exec "${container_name}" node -p process.arch)" == arm64 ]]
[[ "$(docker exec "${container_name}" playwright-mcp --version)" == \
  'Version 0.0.82' ]]
for native_binary in /usr/local/bin/node /usr/bin/caddy; do
  [[ "$(docker exec "${container_name}" sh -c \
    "od -An -tx1 -j18 -N2 '${native_binary}' | tr -d ' \\n'")" == b700 ]]
done
docker exec "${container_name}" sh -c \
  '! dpkg-query -W chrome-remote-desktop >/dev/null 2>&1'
docker exec "${container_name}" supervisorctl status desktop-session | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
docker exec "${container_name}" grep -Fq -- \
  '--tun=userspace-networking' /etc/supervisor/conf.d/codex-desktop.conf
[[ "$(docker compose --project-name codex-desktop \
  --env-file "${config_file}" \
  -f "${source_dir}/compose.yaml" \
  -f "${source_dir}/compose.macos.yaml" ps -q | wc -l | tr -d ' ')" == 1 ]]

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

tailscale_summary="$(docker exec "${container_name}" sh -c \
  "tailscale status --json | jq -c '{BackendState,CurrentTailnet,Self:{DNSName:.Self.DNSName,TailscaleIPs:.Self.TailscaleIPs,Online:.Self.Online,Tags:.Self.Tags}}'")"
[[ "$(docker exec "${container_name}" sh -c \
  "tailscale status --json | jq -r '.BackendState'")" == Running ]]
printf 'Tailscale: %s\n' "${tailscale_summary}"
docker exec "${container_name}" test ! -e /run/secrets/tailscale-auth-key

printf 'Chrome Remote Desktop: not installed on ARM64\n'

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

if [[ "${allow_incomplete}" == 1 && "${extension_configured}" == 0 ]]; then
  printf 'Base macOS deployment checks passed; user-only setup remains incomplete.\n'
else
  printf 'Codex Desktop macOS deployment verification passed.\n'
fi
