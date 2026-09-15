#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install_root="${HOME}/.local/share/codex-desktop"
source_dir="${install_root}/source"
config_file="${install_root}/deploy.env"
backup_root="${install_root}/backups"
launcher_file="${install_root}/start.sh"
launch_agent_dir="${HOME}/Library/LaunchAgents"
launch_agent_file="${launch_agent_dir}/com.eladrave.codex-desktop.plist"
container_name=codex-desktop-desktop-1
volume_prefix=codex-desktop
backup_image='alpine@sha256:2c9d26f410d032d5b1525aa8a873e238b05b90c4ae8618743d4311f0cc827e37'
tailscale_arm64_image='tailscale/tailscale@sha256:fdbdb434c50a6d3a5ed73f2b15ef66228dd2d265c1729e55f9a663ae804c5453'
ubuntu_arm64_image='ubuntu@sha256:ec0b1c9058e44c837a21c3f9d8a3d5e9aaa94ed28edceb18e154af5efecf0950'
chatgpt_arm64_url='https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.820.60940_arm64.deb'
chatgpt_arm64_sha256='8f4dacbff5f054a4f69c2a021f1396c57976972829a61041febac1b423f27c86'
chrome_arm64_url='https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_152.0.7977.64-1_arm64.deb'
chrome_arm64_sha256='6ccab79a7afe1d174c89e28cf0d5a265e6e8855ff3b45c6a2151a65d7ddae9e8'
secret_path=/run/secrets/tailscale-auth-key
temporary_secret_installed=0
backup_dir=
previous_source_dir=
source_swapped=0
base_activated=0
deployment_complete=0
container_stopped_by_installer=0
had_config=0
had_launcher=0
had_launch_agent=0
launch_agent_was_loaded=0

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh

Guided installer for Apple silicon macOS with Docker Desktop. It builds a
native ARM64 Codex, Chrome, Tailscale, Xfce, and noVNC image. Chrome Remote
Desktop is not installed on ARM64. No host ports are published.
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

compose_command() {
  docker compose \
    --project-name codex-desktop \
    --env-file "${config_file}" \
    -f "${source_dir}/compose.yaml" \
    -f "${source_dir}/compose.macos.yaml" \
    "$@"
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

  if ((status != 0 && base_activated == 0)); then
    if ((source_swapped == 1)); then
      compose_command down >/dev/null 2>&1 || true
      failed_source="${source_dir}.failed.$(date -u '+%Y%m%dT%H%M%SZ')"
      [[ ! -d "${source_dir}" ]] || mv "${source_dir}" "${failed_source}" || true
      if [[ -n "${previous_source_dir}" && -d "${previous_source_dir}" ]]; then
        mv "${previous_source_dir}" "${source_dir}" || true
      fi
      if [[ -n "${backup_dir}" && -f "${backup_dir}/deploy.env" ]]; then
        install -m 0600 "${backup_dir}/deploy.env" "${config_file}" || true
      elif ((had_config == 0)); then
        rm -f -- "${config_file}" || true
      fi
      if [[ -n "${backup_dir}" && -f "${backup_dir}/start.sh" ]]; then
        install -m 0700 "${backup_dir}/start.sh" "${launcher_file}" || true
      elif ((had_launcher == 0)); then
        rm -f -- "${launcher_file}" || true
      fi
      if [[ -n "${backup_dir}" && -f "${backup_dir}/com.eladrave.codex-desktop.plist" ]]; then
        install -m 0600 "${backup_dir}/com.eladrave.codex-desktop.plist" \
          "${launch_agent_file}" || true
      elif ((had_launch_agent == 0)); then
        rm -f -- "${launch_agent_file}" || true
      fi
    fi
    if ((container_stopped_by_installer == 1)) && \
      [[ -f "${config_file}" && -f "${source_dir}/compose.yaml" ]]; then
      compose_command up -d --no-build --remove-orphans >/dev/null 2>&1 || true
    fi
  elif ((status != 0 && base_activated == 1 && deployment_complete == 0)); then
    printf 'Warning: the healthy base container remains installed; rerun the installer to resume incomplete enrollment or startup registration.\n' >&2
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
  if [[ "${default}" == yes ]]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
  while true; do
    tty_read "${label} ${suffix}: "
    answer="${TTY_REPLY:-${default}}"
    case "${answer}" in
      y|Y|yes|YES|Yes) printf -v "${destination}" '%s' yes; return 0 ;;
      n|N|no|NO|No) printf -v "${destination}" '%s' no; return 0 ;;
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

validate_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
validate_desktop_sizes() { [[ $1 =~ ^[0-9]+x[0-9]+(,[0-9]+x[0-9]+)*$ ]]; }
validate_memory() { [[ $1 =~ ^[0-9]+[mMgG]$ ]]; }
validate_cpu() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
validate_timezone() {
  [[ $1 =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] && \
    [[ $1 != *'/../'* && $1 != ../* && $1 != */.. ]]
}
validate_image_ref() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]+$ ]]; }

memory_to_mib() {
  local value=$1 number=${1%[mMgG]}
  case "${value}" in
    *g|*G) printf '%d' "$((number * 1024))" ;;
    *) printf '%d' "${number}" ;;
  esac
}

backup_volume() {
  local volume_name=$1 archive_name=$2
  if docker volume inspect "${volume_name}" >/dev/null 2>&1; then
    docker run --rm \
      --platform linux/arm64 \
      -v "${volume_name}:/data:ro" \
      -v "${backup_dir}:/backup" \
      "${backup_image}" \
      tar -cpf "/backup/${archive_name}" -C /data .
    chmod 0600 "${backup_dir}/${archive_name}"
  fi
}

[[ ${EUID} -ne 0 ]] || die 'Run this installer as your normal macOS user, not with sudo.'
[[ -r /dev/tty && -w /dev/tty ]] || die 'A trusted interactive terminal is required.'
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || \
  die 'This installer supports Apple silicon macOS only.'
[[ "${HOME}" != *['&<>']* ]] || die 'The home path contains characters unsupported by the launch-agent template.'
for command_name in docker git tar; do
  command -v "${command_name}" >/dev/null 2>&1 || die "Required command is unavailable: ${command_name}"
done
docker info >/dev/null 2>&1 || die 'Docker Desktop is not running.'
[[ -z "${DOCKER_HOST:-}" ]] || die 'Unset DOCKER_HOST; remote Docker daemons are not supported.'
docker_endpoint="$(docker context inspect "$(docker context show)" \
  --format '{{.Endpoints.docker.Host}}')"
case "${docker_endpoint}" in
  "unix://${HOME}/.docker/run/docker.sock"|unix:///var/run/docker.sock) ;;
  *) die "The active Docker context is not the local Docker Desktop socket: ${docker_endpoint}" ;;
esac
export DOCKER_HOST="${docker_endpoint}"
unset DOCKER_CONTEXT || true
docker compose version >/dev/null 2>&1 || die 'Docker Compose is unavailable.'
docker buildx version >/dev/null 2>&1 || die 'Docker Buildx is unavailable.'
git -C "${repo_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  die 'Run this installer from the repository clone.'
[[ -z "$(git -C "${repo_dir}" status --porcelain)" ]] || \
  die 'The repository must be clean so deployed source matches its commit.'

source_revision="$(git -C "${repo_dir}" rev-parse HEAD)"
short_revision="${source_revision:0:12}"
commit_image_ref="codex-desktop:chatgpt-26.820.60940-chrome-152.0.7977.64-ts1.102.2-arm64-nocrd-11-g${short_revision}"
default_timezone=Etc/UTC
timezone_link="$(readlink /etc/localtime 2>/dev/null || true)"
if [[ "${timezone_link}" == */zoneinfo/* ]]; then
  default_timezone="${timezone_link#*/zoneinfo/}"
fi
if [[ -r "${source_dir}/REVISION" && \
  "$(<"${source_dir}/REVISION")" == "${source_revision}" ]]; then
  default_image_ref="$(read_existing_value IMAGE_REF "${commit_image_ref}")"
else
  default_image_ref="${commit_image_ref}"
fi
default_container_hostname="$(read_existing_value CONTAINER_HOSTNAME codex-desktop)"
default_tailscale_hostname="$(read_existing_value TAILSCALE_HOSTNAME codex-desktop)"
default_timezone="$(read_existing_value TZ "${default_timezone}")"
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
upgrade_existing=
proceed=
keep_enrollment=
confirm_tailnet=
configure_novnc=

existing_install=0
[[ ! -f "${config_file}" ]] || had_config=1
[[ ! -f "${launcher_file}" ]] || had_launcher=1
[[ ! -f "${launch_agent_file}" ]] || had_launch_agent=1
if launchctl print "gui/${UID}/com.eladrave.codex-desktop" >/dev/null 2>&1; then
  launch_agent_was_loaded=1
fi
state_volume_present=0
for state_volume in \
  "${volume_prefix}-home" \
  "${volume_prefix}-tailscale" \
  "${volume_prefix}-machine"; do
  if docker volume inspect "${state_volume}" >/dev/null 2>&1; then
    state_volume_present=1
  fi
done
if [[ -f "${config_file}" || -d "${source_dir}" ]] || \
  docker inspect "${container_name}" >/dev/null 2>&1 || \
  ((state_volume_present == 1 || launch_agent_was_loaded == 1)); then
  existing_install=1
fi
if [[ -f "${config_file}" && ! -f "${source_dir}/compose.yaml" ]] || \
  [[ -f "${source_dir}/compose.yaml" && ! -f "${config_file}" ]]; then
  die 'Managed source and configuration are incomplete. Restore the matching pair before upgrading.'
fi
if docker inspect "${container_name}" >/dev/null 2>&1 && \
  [[ ! -f "${config_file}" || ! -f "${source_dir}/compose.yaml" ]]; then
  die 'An existing container is present without its managed source/config. Resolve it before installing.'
fi

printf '%s\n' \
  'Codex Desktop guided installation for Apple silicon macOS' \
  'The native ARM64 image uses no Rosetta emulation and omits Chrome Remote Desktop.' \
  'No public or LAN ports will be published.' \
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
prompt_default desktop_sizes 'Desktop sizes, comma separated' "${default_desktop_sizes}"
validate_desktop_sizes "${desktop_sizes}" || die 'Invalid desktop-size list.'
prompt_default mem_limit 'Container memory limit' "${default_mem_limit}"
validate_memory "${mem_limit}" || die 'Invalid memory limit; use a value such as 6g.'
prompt_default mem_reservation 'Container memory reservation' "${default_mem_reservation}"
validate_memory "${mem_reservation}" || die 'Invalid memory reservation; use a value such as 1g.'
prompt_default cpu_limit 'Container CPU limit' "${default_cpu_limit}"
validate_cpu "${cpu_limit}" || die 'Invalid CPU limit; use a value such as 2.0.'
awk -v value="${cpu_limit}" 'BEGIN { exit !(value > 0) }' || die 'CPU limit must be greater than zero.'
mem_limit_mib="$(memory_to_mib "${mem_limit}")"
mem_reservation_mib="$(memory_to_mib "${mem_reservation}")"
((mem_reservation_mib <= mem_limit_mib)) || die 'Memory reservation cannot exceed the memory limit.'
docker_memory_mib="$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 ))"
((mem_limit_mib <= docker_memory_mib)) || \
  die "Container memory limit exceeds Docker Desktop's ${docker_memory_mib} MiB allocation. Increase Docker Desktop Resources > Memory or choose a smaller limit."
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
prompt_yes_no build_image 'Build the native ARM64 image from this checked-out commit?' "${build_default}"
if [[ "${build_image}" == yes && "${image_ref}" == *@* ]]; then
  die 'A digest reference cannot be used as a build tag.'
fi
if ((existing_install == 1)); then
  prompt_yes_no upgrade_existing \
    'Existing installation/state detected. Stop only this container and create a full local backup before upgrading?' no
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
prompt_yes_no proceed 'Install and start this configuration?' no
[[ "${proceed}" == yes ]] || die 'Installation cancelled.'

install -d -m 0700 "${install_root}" "${backup_root}"
available_kib="$(df -Pk "${install_root}" | awk 'NR == 2 {print $4}')"
((available_kib >= 15728640)) || die 'At least 15 GiB free disk is required for the image, backup, and persistent state.'

if [[ "${build_image}" == yes ]]; then
  if docker image inspect "${image_ref}" >/dev/null 2>&1; then
    printf 'Matching immutable image already exists; reusing it.\n' >/dev/tty
    build_image=no
  fi
fi
if [[ "${build_image}" == yes ]]; then
  docker buildx build --pull --platform linux/arm64 --load \
    --build-arg "VCS_REF=${source_revision}" \
    --build-arg "UBUNTU_BASE_IMAGE=${ubuntu_arm64_image}" \
    --build-arg 'DESKTOP_ARCH=arm64' \
    --build-arg 'INSTALL_CRD=0' \
    --build-arg "CHATGPT_DEB_URL=${chatgpt_arm64_url}" \
    --build-arg "CHATGPT_DEB_SHA256=${chatgpt_arm64_sha256}" \
    --build-arg "CHROME_DEB_URL=${chrome_arm64_url}" \
    --build-arg "CHROME_DEB_SHA256=${chrome_arm64_sha256}" \
    --build-arg 'TAILSCALE_BINARY_PLATFORM=linux/arm64' \
    --build-arg 'TAILSCALE_BINARY_ARCH=arm64' \
    --build-arg 'TAILSCALE_ELF_MACHINE_HEX=b700' \
    --build-arg "TAILSCALE_BASE_IMAGE=${tailscale_arm64_image}" \
    --tag "${image_ref}" "${repo_dir}"
else
  docker image inspect "${image_ref}" >/dev/null 2>&1 || die 'The selected image is not available locally.'
fi
[[ "$(docker image inspect "${image_ref}" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" == \
  "${source_revision}" ]] || die 'Image revision label does not match the checked-out commit.'
[[ "$(docker image inspect "${image_ref}" \
  --format '{{index .Config.Labels "io.tailscale.binary.arch"}}')" == arm64 ]] || \
  die 'Apple silicon images must contain native ARM64 Tailscale binaries.'
[[ "$(docker image inspect "${image_ref}" --format '{{.Architecture}}')" == arm64 ]] || \
  die 'Apple silicon images must use a native ARM64 root filesystem.'
[[ "$(docker image inspect "${image_ref}" \
  --format '{{index .Config.Labels "io.google.chrome-remote-desktop.enabled"}}')" == 0 ]] || \
  die 'Chrome Remote Desktop must be omitted from the Apple silicon image.'
docker run --rm --platform linux/arm64 --entrypoint /bin/bash "${image_ref}" \
  -lc 'grep -Fq -- --tun=userspace-networking /etc/supervisor/conf.d/codex-desktop.conf; ! dpkg-query -W chrome-remote-desktop >/dev/null 2>&1'

backup_dir="${backup_root}/$(date -u '+%Y%m%dT%H%M%SZ')"
install -d -m 0700 "${backup_dir}"
if ((existing_install == 1)); then
  if [[ -f "${config_file}" && -f "${source_dir}/compose.yaml" ]] && \
    docker inspect "${container_name}" --format '{{.State.Running}}' 2>/dev/null | \
      grep -Fqx true; then
    compose_command stop
    container_stopped_by_installer=1
  fi
  [[ ! -d "${source_dir}" ]] || tar -C "${source_dir}" -cpf "${backup_dir}/source.tar" .
  [[ ! -f "${config_file}" ]] || install -m 0600 "${config_file}" "${backup_dir}/deploy.env"
  [[ ! -f "${launcher_file}" ]] || install -m 0700 "${launcher_file}" "${backup_dir}/start.sh"
  [[ ! -f "${launch_agent_file}" ]] || install -m 0600 "${launch_agent_file}" \
    "${backup_dir}/com.eladrave.codex-desktop.plist"
  backup_volume "${volume_prefix}-home" home.tar
  backup_volume "${volume_prefix}-tailscale" tailscale.tar
  backup_volume "${volume_prefix}-machine" machine.tar
fi

stage_dir="$(mktemp -d "${install_root}/.source-stage.XXXXXXXX")"
git -C "${repo_dir}" archive --format=tar HEAD | tar -x -C "${stage_dir}"
printf '%s\n' "${source_revision}" >"${stage_dir}/REVISION"
if [[ -d "${source_dir}" ]]; then
  previous_source_dir="${source_dir}.previous.$(date -u '+%Y%m%dT%H%M%SZ')"
  mv "${source_dir}" "${previous_source_dir}"
fi
mv "${stage_dir}" "${source_dir}"
source_swapped=1

config_tmp="$(mktemp "${install_root}/.deploy.env.XXXXXXXX")"
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
  printf 'VOLUME_PREFIX=%s\n' "${volume_prefix}"
} >"${config_tmp}"
mv -f "${config_tmp}" "${config_file}"

cat >"${launcher_file}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="${HOME}/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export DOCKER_HOST="${docker_endpoint}"
unset DOCKER_CONTEXT || true
if ! docker info >/dev/null 2>&1; then
  open -gj -a Docker || true
fi
for attempt in \$(seq 1 180); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info >/dev/null
exec docker compose --project-name codex-desktop \\
  --env-file "${config_file}" \\
  -f "${source_dir}/compose.yaml" \\
  -f "${source_dir}/compose.macos.yaml" \\
  up -d --no-build --remove-orphans
EOF
chmod 0700 "${launcher_file}"
install -d -m 0700 "${launch_agent_dir}" "${install_root}/logs"
cat >"${launch_agent_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.eladrave.codex-desktop</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>${launcher_file}</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${install_root}/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>${install_root}/logs/launchd.err.log</string>
</dict>
</plist>
EOF
chmod 0600 "${launch_agent_file}"

compose_command config --quiet
compose_command up -d --no-build --remove-orphans
health=starting
for _attempt in $(seq 1 90); do
  health="$(docker inspect --format '{{.State.Health.Status}}' "${container_name}" 2>/dev/null || true)"
  [[ "${health}" == healthy ]] && break
  [[ "${health}" == unhealthy ]] && die 'Container became unhealthy; inspect Docker logs before retrying.'
  sleep 2
done
[[ "${health}" == healthy ]] || die 'Container did not become healthy within 180 seconds.'
base_activated=1

backend_state="$(docker exec "${container_name}" sh -c \
  "tailscale status --json 2>/dev/null | jq -r '.BackendState // empty'" || true)"
tailnet_confirmed=0
if [[ "${backend_state}" == Running ]]; then
  observed_tailnet="$(docker exec "${container_name}" sh -c \
    "tailscale status --json | jq -r '.CurrentTailnet.Name // .MagicDNSSuffix // .Self.DNSName // \"unknown\"'")"
  printf 'Existing persistent Tailscale enrollment: %s\n' "${observed_tailnet}" >/dev/tty
  printf 'Expected account/tailnet label: %s\n' "${tailnet_label}" >/dev/tty
  prompt_yes_no keep_enrollment 'Does this enrollment belong to the intended account/tailnet?' no
  [[ "${keep_enrollment}" == yes ]] || die 'Existing Tailscale identity was preserved; resolve the mismatch explicitly.'
  docker exec "${container_name}" tailscale set --hostname="${tailscale_hostname}" --ssh
  tailnet_confirmed=1
else
  printf '%s\n' \
    'Tailscale enrollment method:' \
    '  1) One-time auth key from the intended tailnet' \
    '  2) Browser login URL' >/dev/tty
  while true; do
    tty_read 'Choose 1 or 2: '
    enrollment_method="${TTY_REPLY}"
    [[ "${enrollment_method}" == 1 || "${enrollment_method}" == 2 ]] && break
  done
  if [[ "${enrollment_method}" == 1 ]]; then
    printf '%s\n' 'Enter the one-time key only in the hidden prompt. Do not paste it into chat.' >/dev/tty
    prompt_secret tailscale_auth_key 'Tailscale auth key'
    [[ -n "${tailscale_auth_key}" ]] || die 'The Tailscale auth key cannot be empty.'
    docker exec "${container_name}" install -d -o root -g root -m 0700 /run/secrets
    temporary_secret_installed=1
    printf '%s' "${tailscale_auth_key}" | docker exec -i "${container_name}" \
      sh -c 'umask 077; cat > /run/secrets/tailscale-auth-key'
    unset tailscale_auth_key
    docker exec -i "${container_name}" tailscale up \
      --auth-key=file:/run/secrets/tailscale-auth-key \
      --hostname="${tailscale_hostname}" --ssh
    cleanup_tailscale_secret || die 'Temporary Tailscale auth-key removal could not be verified.'
  else
    printf '%s\n' \
      'Tailscale will print a login URL. Open it in a trusted browser or private window,' \
      'select the intended account/tailnet, approve the device, and return here.' >/dev/tty
    docker exec -i "${container_name}" tailscale up --hostname="${tailscale_hostname}" --ssh
  fi
fi

tailscale_summary="$(docker exec "${container_name}" sh -c \
  "tailscale status --json | jq -c '{BackendState,CurrentTailnet,Self:{DNSName:.Self.DNSName,TailscaleIPs:.Self.TailscaleIPs,Tags:.Self.Tags,Online:.Self.Online}}'")"
[[ "$(docker exec "${container_name}" sh -c \
  "tailscale status --json | jq -r '.BackendState'")" == Running ]] || \
  die 'Tailscale enrollment is not running.'
printf 'Tailscale enrollment summary: %s\n' "${tailscale_summary}" >/dev/tty
if ((tailnet_confirmed == 0)); then
  printf 'Expected account/tailnet label: %s\n' "${tailnet_label}" >/dev/tty
  prompt_yes_no confirm_tailnet 'Does this enrollment belong to the intended account/tailnet?' no
  [[ "${confirm_tailnet}" == yes ]] || die 'Enrollment was preserved for explicit investigation.'
fi

if docker exec "${container_name}" test -s /home/codex/.vnc/passwd; then
  printf 'Existing persistent noVNC password was preserved.\n' >/dev/tty
else
  prompt_yes_no configure_novnc 'Configure the noVNC password now?' yes
  if [[ "${configure_novnc}" == yes ]]; then
    docker exec -it "${container_name}" /usr/local/bin/configure-codex-novnc
  fi
fi

"${source_dir}/scripts/verify-macos.sh" --allow-incomplete
if ((launch_agent_was_loaded == 0)); then
  launchctl bootstrap "gui/${UID}" "${launch_agent_file}"
fi
deployment_complete=1
printf '\nInstallation, startup, and Tailscale enrollment completed.\n' >/dev/tty
printf 'Persistent Docker volumes: %s-{home,tailscale,machine}\n' "${volume_prefix}" >/dev/tty
printf 'Backup: %s\n' "${backup_dir}" >/dev/tty
printf '%s\n' \
  '' \
  'User-only desktop setup still required:' \
  "1. Open http://${tailscale_hostname}:6080/vnc.html?autoconnect=1&resize=scale from an allowed tailnet device." \
  '2. Enter the noVNC password and sign in to Codex in the Xfce desktop.' \
  '3. Install the Chrome plugin and official extension through Codex settings.' \
  '4. Test @Chrome, restart the container, and verify sign-in/browser persistence.' \
  '5. Run ~/.local/share/codex-desktop/source/scripts/verify-macos.sh.' >/dev/tty
