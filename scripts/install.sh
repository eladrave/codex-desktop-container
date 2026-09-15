#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep one public installer entry point. Apple silicon uses Docker Desktop,
# named volumes, and launchd rather than the Ubuntu systemd/AppArmor layout.
if [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]; then
  exec bash "${repo_dir}/scripts/install-macos.sh" "$@"
fi

service_dir=/opt/services/codex-desktop
config_dir=/etc/codex-desktop
config_file=${config_dir}/deploy.env
unit_file=/etc/systemd/system/codex-desktop.service
container_name=codex-desktop-desktop-1
secret_path=/run/secrets/tailscale-auth-key
temporary_secret_installed=0
backup_dir=
previous_dir=
new_service_installed=0
service_stopped_by_installer=0
deployment_activated=0
had_service_dir=0
had_config_file=0
had_unit_file=0
unit_was_enabled=0
unit_was_active=0

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install.sh

Guided installer for the Tailscale-only Codex Desktop container.
Run it from a clean clone on an Ubuntu 24.04 AMD64 Docker host with a TTY.
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if (($# != 0)); then
  usage >&2
  exit 64
fi

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

repo_git() {
  git -c "safe.directory=${repo_dir}" -C "${repo_dir}" "$@"
}

cleanup_tailscale_secret() {
  if [[ "${temporary_secret_installed}" == 1 ]]; then
    docker exec "${container_name}" rm -f -- "${secret_path}" \
      >/dev/null 2>&1 || return 1
    docker exec "${container_name}" test ! -e "${secret_path}" \
      >/dev/null 2>&1 || return 1
    temporary_secret_installed=0
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  cleanup_tailscale_secret || \
    printf 'Warning: temporary Tailscale auth-key removal could not be verified.\n' >&2

  if ((status != 0 && deployment_activated == 0)); then
    if ((new_service_installed == 1)); then
      systemctl stop codex-desktop.service >/dev/null 2>&1 || true
      failed_dir="${service_dir}.failed.$(date -u '+%Y%m%dT%H%M%SZ')"
      [[ ! -d "${service_dir}" ]] || mv "${service_dir}" "${failed_dir}" || true
      if [[ -n "${previous_dir}" && -d "${previous_dir}" ]]; then
        mv "${previous_dir}" "${service_dir}" || true
      fi
      if [[ -n "${backup_dir}" && -f "${backup_dir}/deploy.env" ]]; then
        install -o root -g root -m 0600 \
          "${backup_dir}/deploy.env" "${config_file}" || true
      elif ((had_config_file == 0)); then
        rm -f -- "${config_file}" || true
      fi
      if [[ -n "${backup_dir}" && -f "${backup_dir}/codex-desktop.service" ]]; then
        install -o root -g root -m 0644 \
          "${backup_dir}/codex-desktop.service" "${unit_file}" || true
      elif ((had_unit_file == 0)); then
        rm -f -- "${unit_file}" || true
      fi
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if ((new_service_installed == 1 || service_stopped_by_installer == 1)); then
      if ((unit_was_enabled == 1)); then
        systemctl enable codex-desktop.service >/dev/null 2>&1 || true
      else
        systemctl disable codex-desktop.service >/dev/null 2>&1 || true
      fi
      if ((unit_was_active == 1)); then
        systemctl start codex-desktop.service >/dev/null 2>&1 || true
      else
        systemctl stop codex-desktop.service >/dev/null 2>&1 || true
      fi
    fi
  fi
  exit "${status}"
}
trap on_exit EXIT

tty_read() {
  local prompt=$1
  printf '%s' "${prompt}" >/dev/tty
  TTY_REPLY=
  IFS= read -r TTY_REPLY </dev/tty || die 'Interactive input is required.'
}

prompt_default() {
  local destination=$1 label=$2 default=$3
  tty_read "${label} [${default}]: "
  printf -v "${destination}" '%s' "${TTY_REPLY:-${default}}"
}

prompt_yes_no() {
  local destination=$1 label=$2 default=${3:-no} answer suffix
  if [[ "${default}" == yes ]]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi
  while true; do
    tty_read "${label} ${suffix}: "
    answer="${TTY_REPLY:-${default}}"
    case "${answer,,}" in
      y|yes) printf -v "${destination}" '%s' yes; return 0 ;;
      n|no) printf -v "${destination}" '%s' no; return 0 ;;
      *) printf 'Enter yes or no.\n' >/dev/tty ;;
    esac
  done
}

prompt_secret() {
  local destination=$1 label=$2 value
  printf '%s' "${label}: " >/dev/tty
  IFS= read -r -s value </dev/tty || die 'Secret input failed.'
  printf '\n' >/dev/tty
  printf -v "${destination}" '%s' "${value}"
}

read_existing_value() {
  local key=$1 fallback=$2 value
  value=
  if [[ -r "${config_file}" ]]; then
    value="$(sed -n "s/^${key}=//p" "${config_file}" | tail -n 1)"
  fi
  printf '%s' "${value:-${fallback}}"
}

validate_hostname() {
  [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

validate_desktop_sizes() {
  [[ $1 =~ ^[0-9]+x[0-9]+(,[0-9]+x[0-9]+)*$ ]]
}

validate_memory() {
  [[ $1 =~ ^[0-9]+[mMgG]$ ]]
}

memory_to_mib() {
  local value=${1,,} number=${1%[mMgG]}
  if [[ "${value}" == *g ]]; then
    printf '%d' "$((number * 1024))"
  else
    printf '%d' "${number}"
  fi
}

validate_cpu() {
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]
}

validate_timezone() {
  [[ $1 =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] && \
    [[ $1 != *'/../'* && $1 != ../* && $1 != */.. ]]
}

validate_image_ref() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]+$ ]]
}

[[ ${EUID} -eq 0 ]] || die 'Run this installer with sudo or as root.'
[[ -r /dev/tty && -w /dev/tty ]] || die 'A trusted interactive TTY is required.'
[[ "$(uname -s)" == Linux ]] || die 'This installer supports Linux hosts only.'
[[ "$(uname -m)" == x86_64 || "$(uname -m)" == amd64 ]] || \
  die 'This image currently supports AMD64 hosts only.'
[[ -r /etc/os-release ]] || die 'Unable to identify the host operating system.'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || \
  die "Supported installer host is Ubuntu 24.04 AMD64; found ${ID:-unknown} ${VERSION_ID:-unknown}."

for command_name in docker git jq tar systemctl apparmor_parser; do
  command -v "${command_name}" >/dev/null 2>&1 || \
    die "Required command is unavailable: ${command_name}"
done
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required.'
docker info >/dev/null 2>&1 || die 'Docker Engine is unavailable.'
[[ -z "${DOCKER_HOST:-}" ]] || die 'Unset DOCKER_HOST; remote Docker daemons are not supported.'
docker_endpoint="$(docker context inspect "$(docker context show)" \
  --format '{{.Endpoints.docker.Host}}')"
case "${docker_endpoint}" in
  unix:///var/run/docker.sock|unix:///run/docker.sock) ;;
  *) die "The active Docker context is not a local system socket: ${docker_endpoint}" ;;
esac
export DOCKER_HOST="${docker_endpoint}"
unset DOCKER_CONTEXT || true
if [[ ! -r /sys/module/apparmor/parameters/enabled ]] || \
  ! grep -Fq Y /sys/module/apparmor/parameters/enabled; then
  die 'AppArmor must be enabled on the host.'
fi
docker info --format '{{json .SecurityOptions}}' | grep -q apparmor || \
  die 'Docker is not reporting AppArmor support.'
if docker info --format '{{json .SecurityOptions}}' | grep -q rootless; then
  die 'Rootless Docker is not supported by this systemd/AppArmor deployment.'
fi
repo_git rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  die 'Run this installer from the repository clone.'
[[ -z "$(repo_git status --porcelain)" ]] || \
  die 'The repository must be clean so the deployed source matches its commit.'

source_revision="$(repo_git rev-parse HEAD)"
short_revision="${source_revision:0:12}"
commit_image_ref="codex-desktop:chatgpt-26.820.60940-crd-152.0.7977.9-ts1.102.2-10-g${short_revision}"
if [[ -r "${service_dir}/REVISION" && \
  "$(<"${service_dir}/REVISION")" == "${source_revision}" ]]; then
  default_image_ref="$(read_existing_value IMAGE_REF "${commit_image_ref}")"
else
  default_image_ref="${commit_image_ref}"
fi
default_container_hostname="$(read_existing_value CONTAINER_HOSTNAME codex-desktop)"
default_tailscale_hostname="$(read_existing_value TAILSCALE_HOSTNAME codex-desktop)"
default_timezone="$(read_existing_value TZ Etc/UTC)"
default_desktop_sizes="$(read_existing_value DESKTOP_SIZES '1920x1080,2560x1440')"
default_mem_limit="$(read_existing_value MEM_LIMIT 6g)"
default_mem_reservation="$(read_existing_value MEM_RESERVATION 1g)"
default_cpu_limit="$(read_existing_value CPU_LIMIT 2.0)"

container_hostname=
tailscale_hostname=
tailnet_label=
timezone=
desktop_sizes=
mem_limit=
mem_reservation=
cpu_limit=
image_ref=
build_image=
proceed=
configure_novnc=
keep_enrollment=
upgrade_existing=
confirm_tailnet=
tailnet_confirmed=0

existing_install=0
[[ ! -d "${service_dir}" ]] || had_service_dir=1
[[ ! -f "${config_file}" ]] || had_config_file=1
[[ ! -f "${unit_file}" ]] || had_unit_file=1
if systemctl is-enabled --quiet codex-desktop.service >/dev/null 2>&1; then
  unit_was_enabled=1
fi
if systemctl is-active --quiet codex-desktop.service >/dev/null 2>&1; then
  unit_was_active=1
fi
container_running=0
if docker inspect "${container_name}" --format '{{.State.Running}}' \
  2>/dev/null | grep -Fqx true; then
  container_running=1
fi
if ((container_running == 1 && unit_was_active == 0)); then
  die 'The Codex Desktop container is running outside an active codex-desktop.service. Resolve ownership before installing or backing up state.'
fi
if ((had_service_dir == 1 || had_config_file == 1 || had_unit_file == 1)) || \
  [[ -d /var/lib/codex-desktop ]]; then
  existing_install=1
fi

printf '%s\n' \
  'Codex Desktop guided installation' \
  'No public or LAN ports will be published. Tailscale and CRD remain the access paths.' \
  '' >/dev/tty

prompt_default container_hostname 'Container hostname' "${default_container_hostname}"
validate_hostname "${container_hostname}" || die 'Invalid container hostname.'
prompt_default tailscale_hostname 'Tailscale/MagicDNS hostname' "${default_tailscale_hostname}"
validate_hostname "${tailscale_hostname}" || die 'Invalid Tailscale hostname.'
prompt_default tailnet_label \
  'Expected Tailscale account or tailnet label, used only for confirmation' \
  'confirm-in-browser'
prompt_default timezone 'Timezone' "${default_timezone}"
validate_timezone "${timezone}" || die 'Invalid timezone.'
[[ -e "/usr/share/zoneinfo/${timezone}" ]] || die 'Timezone was not found under /usr/share/zoneinfo.'
prompt_default desktop_sizes 'Desktop sizes, comma separated' "${default_desktop_sizes}"
validate_desktop_sizes "${desktop_sizes}" || die 'Invalid desktop-size list.'
prompt_default mem_limit 'Container memory limit' "${default_mem_limit}"
validate_memory "${mem_limit}" || die 'Invalid memory limit; use a value such as 6g.'
prompt_default mem_reservation 'Container memory reservation' "${default_mem_reservation}"
validate_memory "${mem_reservation}" || die 'Invalid memory reservation; use a value such as 1g.'
prompt_default cpu_limit 'Container CPU limit' "${default_cpu_limit}"
validate_cpu "${cpu_limit}" || die 'Invalid CPU limit; use a value such as 2.0.'
awk -v value="${cpu_limit}" 'BEGIN { exit !(value > 0) }' || \
  die 'CPU limit must be greater than zero.'
mem_limit_mib="$(memory_to_mib "${mem_limit}")"
mem_reservation_mib="$(memory_to_mib "${mem_reservation}")"
((mem_reservation_mib <= mem_limit_mib)) || \
  die 'Memory reservation cannot exceed the memory limit.'
host_memory_mib="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
((mem_limit_mib <= host_memory_mib)) || \
  die 'Container memory limit exceeds total host memory.'
while true; do
  prompt_default image_ref 'Immutable image reference to build or use' "${default_image_ref}"
  validate_image_ref "${image_ref}" || { printf 'Invalid image reference.\n' >/dev/tty; continue; }
  if docker image inspect "${image_ref}" >/dev/null 2>&1; then
    existing_image_revision="$(docker image inspect "${image_ref}" \
      --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
    if [[ "${existing_image_revision}" != "${source_revision}" ]]; then
      printf 'That image tag already belongs to another source revision. Enter a new immutable tag.\n' >/dev/tty
      continue
    fi
    build_default=no
  else
    build_default=yes
  fi
  break
done
prompt_yes_no build_image 'Build this image from the checked-out commit?' "${build_default}"
if [[ "${build_image}" == yes && "${image_ref}" == *@* ]]; then
  die 'A digest reference cannot be used as a docker build tag.'
fi
if ((existing_install == 1)); then
  prompt_yes_no upgrade_existing \
    'Existing installation/state detected. Stop only this service and create a full root-only backup before upgrading?' no
  [[ "${upgrade_existing}" == yes ]] || die 'Upgrade cancelled; existing state was not changed.'
fi

printf '\nConfiguration summary:\n' >/dev/tty
printf '  Source commit: %s\n' "${source_revision}" >/dev/tty
printf '  Image: %s\n' "${image_ref}" >/dev/tty
printf '  Container hostname: %s\n' "${container_hostname}" >/dev/tty
printf '  Tailscale hostname: %s\n' "${tailscale_hostname}" >/dev/tty
printf '  Expected tailnet/account: %s\n' "${tailnet_label}" >/dev/tty
printf '  Timezone: %s\n' "${timezone}" >/dev/tty
printf '  Desktop sizes: %s\n' "${desktop_sizes}" >/dev/tty
printf '  Resources: %s memory, %s reservation, %s CPUs\n' \
  "${mem_limit}" "${mem_reservation}" "${cpu_limit}" >/dev/tty
prompt_yes_no proceed 'Install this configuration?' no
[[ "${proceed}" == yes ]] || die 'Installation cancelled.'

install -d -o root -g root -m 0700 /var/backups/codex-desktop
available_kib="$(df -Pk /var/backups | awk 'NR == 2 {print $4}')"
if [[ "${build_image}" == yes ]]; then
  required_kib=10485760
else
  required_kib=1048576
fi
if [[ -d /var/lib/codex-desktop ]]; then
  state_kib="$(du -sk /var/lib/codex-desktop | awk '{print $1}')"
  required_kib=$((required_kib + state_kib))
fi
((available_kib >= required_kib)) || \
  die 'Insufficient free space for the image operation and consistent state backup.'

if [[ "${build_image}" == yes ]]; then
  if docker image inspect "${image_ref}" >/dev/null 2>&1; then
    printf 'Matching immutable image already exists; reusing it.\n' >/dev/tty
    build_image=no
  fi
fi
if [[ "${build_image}" == yes ]]; then
  docker build --pull --platform linux/amd64 \
    --build-arg "VCS_REF=${source_revision}" \
    --tag "${image_ref}" "${repo_dir}"
  [[ "$(docker image inspect "${image_ref}" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" == \
    "${source_revision}" ]] || die 'Built image revision label does not match the source commit.'
else
  docker image inspect "${image_ref}" >/dev/null 2>&1 || \
    die 'The selected image is not available locally.'
  [[ "$(docker image inspect "${image_ref}" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" == \
    "${source_revision}" ]] || \
    die 'Existing image revision label does not match the checked-out commit.'
fi

backup_dir=/var/backups/codex-desktop/"$(date -u '+%Y%m%dT%H%M%SZ')"
install -d -o root -g root -m 0700 "${backup_dir}"

if systemctl is-active --quiet codex-desktop.service; then
  systemctl stop codex-desktop.service
  service_stopped_by_installer=1
fi
if [[ -d "${service_dir}" ]]; then
  tar -C "$(dirname "${service_dir}")" -cpf "${backup_dir}/service.tar" \
    "$(basename "${service_dir}")"
fi
if [[ -f "${config_file}" ]]; then
  install -o root -g root -m 0600 "${config_file}" "${backup_dir}/deploy.env"
  prior_image_ref="$(sed -n 's/^IMAGE_REF=//p' "${config_file}" | tail -n 1)"
  if [[ -n "${prior_image_ref}" ]] && \
    docker image inspect "${prior_image_ref}" >/dev/null 2>&1; then
    {
      printf 'IMAGE_REF=%s\n' "${prior_image_ref}"
      printf 'IMAGE_ID=%s\n' "$(docker image inspect "${prior_image_ref}" --format '{{.Id}}')"
    } >"${backup_dir}/image.env"
    chmod 0600 "${backup_dir}/image.env"
  fi
fi
if [[ -f "${unit_file}" ]]; then
  install -o root -g root -m 0644 "${unit_file}" "${backup_dir}/codex-desktop.service"
fi
if [[ -d /var/lib/codex-desktop ]]; then
  tar -C /var/lib -cpf "${backup_dir}/persistent-state.tar" codex-desktop
  chmod 0600 "${backup_dir}/persistent-state.tar"
fi

stage_dir="$(mktemp -d /opt/services/.codex-desktop-stage.XXXXXXXXXX)"
repo_git archive --format=tar HEAD | tar -x -C "${stage_dir}"
repo_git rev-parse HEAD >"${stage_dir}/REVISION"
if [[ -d "${service_dir}" ]]; then
  previous_dir="${service_dir}.previous.$(date -u '+%Y%m%dT%H%M%SZ')"
  mv "${service_dir}" "${previous_dir}"
  printf 'Previous source retained at %s\n' "${previous_dir}" >/dev/tty
fi
mv "${stage_dir}" "${service_dir}"
new_service_installed=1

install -d -o root -g root -m 0755 "${config_dir}"
config_tmp="$(mktemp -p "${config_dir}" '.deploy.env.XXXXXXXXXX')"
chmod 0600 "${config_tmp}"
{
  printf 'IMAGE_REF=%s\n' "${image_ref}"
  printf 'CONTAINER_HOSTNAME=%s\n' "${container_hostname}"
  printf 'TAILSCALE_HOSTNAME=%s\n' "${tailscale_hostname}"
  printf 'TZ=%s\n' "${timezone}"
  printf 'DESKTOP_SIZES=%s\n' "${desktop_sizes}"
  printf 'MEM_LIMIT=%s\n' "${mem_limit}"
  printf 'MEM_RESERVATION=%s\n' "${mem_reservation}"
  printf 'CPU_LIMIT=%s\n' "${cpu_limit}"
} >"${config_tmp}"
chown root:root "${config_tmp}"
mv -f "${config_tmp}" "${config_file}"
install -o root -g root -m 0644 \
  "${service_dir}/codex-desktop.service" "${unit_file}"

install -d -o 10001 -g 10001 -m 0700 /var/lib/codex-desktop/home
install -d -o root -g root -m 0700 \
  /var/lib/codex-desktop/tailscale \
  /var/lib/codex-desktop/machine

docker compose --project-name codex-desktop \
  --env-file "${config_file}" \
  -f "${service_dir}/compose.yaml" config --quiet
apparmor_parser --replace "${service_dir}/apparmor-chatgpt"
systemctl daemon-reload
systemctl enable codex-desktop.service
systemctl restart codex-desktop.service

for _attempt in $(seq 1 90); do
  health="$(docker inspect --format '{{.State.Health.Status}}' \
    "${container_name}" 2>/dev/null || true)"
  [[ "${health}" == healthy ]] && break
  [[ "${health}" == unhealthy ]] && \
    die 'Container became unhealthy; inspect docker logs before retrying.'
  sleep 2
done
[[ "${health:-}" == healthy ]] || die 'Container did not become healthy within 180 seconds.'
deployment_activated=1

backend_state="$(
  docker exec "${container_name}" tailscale status --json 2>/dev/null |
    jq -r '.BackendState // empty' || true
)"
if [[ "${backend_state}" == Running ]]; then
  observed_tailnet="$(
    docker exec "${container_name}" tailscale status --json |
      jq -r '.CurrentTailnet.Name // .MagicDNSSuffix // .Self.DNSName // "unknown"'
  )"
  printf 'Existing persistent Tailscale enrollment: %s\n' "${observed_tailnet}" >/dev/tty
  printf 'Expected account/tailnet label: %s\n' "${tailnet_label}" >/dev/tty
  prompt_yes_no keep_enrollment \
    'Does this existing enrollment belong to the intended account/tailnet?' no
  [[ "${keep_enrollment}" == yes ]] || \
    die 'Existing Tailscale identity was preserved. Resolve the account mismatch explicitly before retrying.'
  docker exec "${container_name}" \
    tailscale set --hostname="${tailscale_hostname}" --ssh
  tailnet_confirmed=1
else
  printf '\nTailscale enrollment method:\n' >/dev/tty
  printf '  1) One-time auth key from the intended tailnet (recommended for servers)\n' >/dev/tty
  printf '  2) Browser login URL, where you select the intended account/tailnet\n' >/dev/tty
  while true; do
    tty_read 'Choose 1 or 2: '
    enrollment_method="${TTY_REPLY}"
    [[ "${enrollment_method}" == 1 || "${enrollment_method}" == 2 ]] && break
    printf 'Enter 1 or 2.\n' >/dev/tty
  done

  if [[ "${enrollment_method}" == 1 ]]; then
    printf '%s\n' \
      'Generate a one-time, non-ephemeral auth key in the intended tailnet.' \
      'Use a tag only when policy intentionally grants that tag the required SSH/noVNC access; pre-approve only when device approval is enabled.' \
      'Enter it only in the hidden prompt below. Do not paste it into chat.' >/dev/tty
    prompt_secret tailscale_auth_key 'Tailscale auth key'
    [[ -n "${tailscale_auth_key}" ]] || die 'The Tailscale auth key cannot be empty.'
    docker exec "${container_name}" install -d -o root -g root -m 0700 /run/secrets
    temporary_secret_installed=1
    printf '%s' "${tailscale_auth_key}" | docker exec -i "${container_name}" \
      sh -c 'umask 077; cat > /run/secrets/tailscale-auth-key'
    unset tailscale_auth_key
    docker exec -i "${container_name}" \
      tailscale up \
      --auth-key=file:/run/secrets/tailscale-auth-key \
      --hostname="${tailscale_hostname}" \
      --ssh
    cleanup_tailscale_secret || \
      die 'Temporary Tailscale auth-key removal could not be verified.'
  else
    printf '%s\n' \
      'Tailscale will print a login URL next.' \
      'Open it in a trusted browser, sign in with the intended account, select the correct tailnet, and approve this device.' \
      'The command will return after approval. If the wrong account is already active, use a private browser window.' >/dev/tty
    docker exec -i "${container_name}" \
      tailscale up --hostname="${tailscale_hostname}" --ssh
  fi
fi

backend_state="$(
  docker exec "${container_name}" tailscale status --json |
    jq -r '.BackendState // empty'
)"
[[ "${backend_state}" == Running ]] || die 'Tailscale enrollment is not running.'
tailscale_summary="$(
  docker exec "${container_name}" tailscale status --json |
    jq -c '{BackendState,CurrentTailnet,Self:{DNSName:.Self.DNSName,TailscaleIPs:.Self.TailscaleIPs,Tags:.Self.Tags,Online:.Self.Online}}'
)"
printf 'Tailscale enrollment summary: %s\n' "${tailscale_summary}" >/dev/tty
if ((tailnet_confirmed == 0)); then
  printf 'Expected account/tailnet label: %s\n' "${tailnet_label}" >/dev/tty
  prompt_yes_no confirm_tailnet \
    'Does this new enrollment belong to the intended account/tailnet?' no
  [[ "${confirm_tailnet}" == yes ]] || \
    die 'The enrollment was left intact for investigation. Resolve the mismatch explicitly; the installer will not log out or switch it.'
fi

if [[ -s /var/lib/codex-desktop/home/.vnc/passwd ]]; then
  printf 'Existing persistent noVNC password was preserved.\n' >/dev/tty
else
  prompt_yes_no configure_novnc 'Configure the noVNC password now?' yes
  if [[ "${configure_novnc}" == yes ]]; then
    printf '%s\n' \
      'Use a unique random value. Classic VNC uses only the first eight characters.' \
      'The tailnet ACL is the primary access boundary.' >/dev/tty
    docker exec -it "${container_name}" /usr/local/bin/configure-codex-novnc
  fi
fi

printf '\nHost deployment and Tailscale enrollment completed.\n' >/dev/tty
printf 'Backup created at %s\n' "${backup_dir}" >/dev/tty
printf '%s\n' \
  '' \
  'User-only desktop setup still required:' \
  '1. Open https://remotedesktop.google.com/headless in the intended Google account.' \
  '2. Generate the Debian/Linux registration command.' \
  "3. Connect with: tailscale ssh root@${tailscale_hostname}" \
  '4. Run: set +o history' \
  '5. Paste and run the registration command directly, then run: set -o history' \
  '6. Enter the CRD PIN only at its hidden prompt.' \
  '7. Connect through Chrome Remote Desktop; sign in to Codex.' \
  '8. In Codex Settings > Computer Use, install the Chrome plugin and official extension.' \
  '9. Confirm Chrome shows Manage and test one @Chrome action.' \
  '10. Enable full CDP only if the scheduled task genuinely needs it.' \
  '11. Run sudo /opt/services/codex-desktop/scripts/verify-deployment.sh.' >/dev/tty
