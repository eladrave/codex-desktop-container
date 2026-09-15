#!/usr/bin/env bash
set -Eeuo pipefail

container_name=codex-desktop-desktop-1
config_file=/etc/codex-desktop/deploy.env
compose_file=/opt/services/codex-desktop/compose.yaml
allow_incomplete=0

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

state="$(docker inspect "${container_name}" \
  --format '{{.State.Status}} {{.State.Health.Status}} {{json .NetworkSettings.Ports}}')"
[[ "${state}" == 'running healthy {}' ]]

docker exec "${container_name}" /usr/local/sbin/codex-desktop-healthcheck
docker exec "${container_name}" supervisorctl status
docker exec "${container_name}" dpkg-query -W \
  chatgpt chrome-remote-desktop google-chrome-stable novnc websockify x11vnc

tailscale_summary="$(
  docker exec "${container_name}" tailscale status --json |
    jq -c '{BackendState,CurrentTailnet,Self:{DNSName:.Self.DNSName,TailscaleIPs:.Self.TailscaleIPs,Online:.Self.Online,Tags:.Self.Tags}}'
)"
[[ "$(jq -r '.BackendState' <<<"${tailscale_summary}")" == Running ]]
printf 'Tailscale: %s\n' "${tailscale_summary}"
docker exec "${container_name}" test ! -e /run/secrets/tailscale-auth-key

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
printf 'Chrome Remote Desktop: %s\n' "${crd_status}"
if [[ "${crd_status}" != STARTED && "${allow_incomplete}" == 0 ]]; then
  echo 'Chrome Remote Desktop is not registered and STARTED.' >&2
  exit 1
fi

novnc_configured=0
if [[ -s /var/lib/codex-desktop/home/.vnc/passwd ]]; then
  [[ "$(stat -c '%u:%g:%a' /var/lib/codex-desktop/home/.vnc/passwd)" == \
    '10001:10001:600' ]]
  printf 'noVNC password: configured\n'
  novnc_configured=1
else
  printf 'noVNC password: not configured\n'
fi
if [[ "${novnc_configured}" == 0 && "${allow_incomplete}" == 0 ]]; then
  echo 'noVNC password is not configured.' >&2
  exit 1
fi

if [[ "${crd_status}" == STARTED && "${novnc_configured}" == 1 ]]; then
  tailscale_ip="$(jq -r '.Self.TailscaleIPs[0] // empty' <<<"${tailscale_summary}")"
  [[ "${tailscale_ip}" =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
  listeners="$(docker exec "${container_name}" ss -lnt)"
  grep -Eq "127\\.0\\.0\\.1:5900[[:space:]]" <<<"${listeners}"
  grep -Eq "${tailscale_ip//./\\.}:6080[[:space:]]" <<<"${listeners}"
  if grep -Eq '(0\.0\.0\.0|:::):(5900|6080)[[:space:]]' <<<"${listeners}"; then
    echo 'VNC or noVNC is listening on an unrestricted container address.' >&2
    exit 1
  fi

  tailscale_dns="$(jq -r '.Self.DNSName // empty' <<<"${tailscale_summary}")"
  if [[ -n "${tailscale_dns}" ]]; then
    printf 'noVNC: http://%s:6080/vnc.html?autoconnect=1&resize=scale\n' \
      "${tailscale_dns%.}"
  else
    printf 'noVNC: http://%s:6080/vnc.html?autoconnect=1&resize=scale\n' \
      "${tailscale_ip}"
  fi
fi

if [[ "${allow_incomplete}" == 1 && \
  ("${crd_status}" != STARTED || "${novnc_configured}" == 0) ]]; then
  printf 'Base deployment checks passed; user-only setup remains incomplete.\n'
else
  printf 'Codex Desktop deployment verification passed.\n'
fi
