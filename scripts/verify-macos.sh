#!/usr/bin/env bash
set -Eeuo pipefail

install_root="${HOME}/.local/share/codex-desktop"
source_dir="${install_root}/source"
config_file="${install_root}/deploy.env"
container_name=codex-desktop-desktop-1
allow_incomplete=0

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
docker exec "${container_name}" sh -c \
  '! dpkg-query -W chrome-remote-desktop >/dev/null 2>&1'
docker exec "${container_name}" supervisorctl status desktop-session | \
  grep -Eq '^[^[:space:]]+[[:space:]]+RUNNING([[:space:]]|$)'
docker exec "${container_name}" grep -Fq -- \
  '--tun=userspace-networking' /etc/supervisor/conf.d/codex-desktop.conf

tailscale_summary="$(docker exec "${container_name}" sh -c \
  "tailscale status --json | jq -c '{BackendState,CurrentTailnet,Self:{DNSName:.Self.DNSName,TailscaleIPs:.Self.TailscaleIPs,Online:.Self.Online,Tags:.Self.Tags}}'")"
[[ "$(docker exec "${container_name}" sh -c \
  "tailscale status --json | jq -r '.BackendState'")" == Running ]]
printf 'Tailscale: %s\n' "${tailscale_summary}"
docker exec "${container_name}" test ! -e /run/secrets/tailscale-auth-key

printf 'Chrome Remote Desktop: not installed on ARM64\n'

novnc_configured=0
if docker exec "${container_name}" test -s /home/codex/.vnc/passwd; then
  docker exec "${container_name}" bash -c \
    "test \"\$(stat -c '%u:%g:%a' /home/codex/.vnc/passwd)\" = '10001:10001:600'"
  printf 'noVNC password: configured\n'
  novnc_configured=1
else
  printf 'noVNC password: not configured\n'
fi
if [[ "${novnc_configured}" == 0 && "${allow_incomplete}" == 0 ]]; then
  echo 'noVNC password is not configured.' >&2
  exit 1
fi

if [[ "${novnc_configured}" == 1 ]]; then
  listeners="$(docker exec "${container_name}" ss -lnt)"
  grep -Eq '127\.0\.0\.2:5900[[:space:]]' <<<"${listeners}"
  grep -Eq '127\.0\.0\.1:6080[[:space:]]' <<<"${listeners}"
  if grep -Eq '(0\.0\.0\.0|:::):(5900|6080)[[:space:]]' <<<"${listeners}"; then
    echo 'VNC or noVNC is listening on an unrestricted container address.' >&2
    exit 1
  fi
  tailscale_dns="$(docker exec "${container_name}" sh -c \
    "tailscale status --json | jq -r '.Self.DNSName // empty'")"
  tailscale_ip="$(docker exec "${container_name}" tailscale ip -4 | head -n 1)"
  if [[ -n "${tailscale_dns}" ]]; then
    printf 'noVNC: http://%s:6080/vnc.html?autoconnect=1&resize=scale\n' \
      "${tailscale_dns%.}"
  else
    printf 'noVNC: http://%s:6080/vnc.html?autoconnect=1&resize=scale\n' \
      "${tailscale_ip}"
  fi
fi

if [[ "${allow_incomplete}" == 1 && "${novnc_configured}" == 0 ]]; then
  printf 'Base macOS deployment checks passed; user-only setup remains incomplete.\n'
else
  printf 'Codex Desktop macOS deployment verification passed.\n'
fi
