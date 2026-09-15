#!/bin/sh
# shellcheck disable=SC2024
set -eu

repository_url=https://github.com/eladrave/codex-desktop-container.git
repository_ref=${CODEX_DESKTOP_REF:-main}
docker_desktop_dmg=https://desktop.docker.com/mac/main/arm64/Docker.dmg
work_dir=
docker_dmg_mounted=0

say() {
  printf '%s\n' "$*" >/dev/tty
}

fail() {
  say "Error: $*"
  exit 1
}

ask_yes_no() {
  prompt=$1
  default=${2:-no}
  if [ "${default}" = yes ]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi
  while :; do
    printf '%s %s: ' "${prompt}" "${suffix}" >/dev/tty
    IFS= read -r answer </dev/tty || fail 'Interactive input is required.'
    [ -n "${answer}" ] || answer=${default}
    case ${answer} in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) say 'Enter yes or no.' ;;
    esac
  done
}

cleanup() {
  if [ "${docker_dmg_mounted}" -eq 1 ]; then
    sudo hdiutil detach /Volumes/Docker >/dev/null 2>&1 || true
    docker_dmg_mounted=0
  fi
  if [ -n "${work_dir}" ]; then
    case ${work_dir} in
      "${TMPDIR:-/tmp}"/codex-desktop-bootstrap.*)
        rm -rf -- "${work_dir}"
        ;;
    esac
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

usage() {
  cat <<'EOF'
Usage:
  curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/eladrave/codex-desktop-container/main/bootstrap.sh | sh

Supported hosts:
  - Ubuntu 24.04 AMD64
  - macOS on Apple silicon with Docker Desktop

Set CODEX_DESKTOP_REF to install a different branch or tag.
EOF
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || { usage; exit 64; }
if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
  fail 'Run this command from an interactive terminal.'
fi

host_os=$(uname -s)
host_arch=$(uname -m)
case "${host_os}:${host_arch}" in
  Linux:x86_64|Linux:amd64) platform=linux ;;
  Darwin:arm64) platform=macos ;;
  *) fail "Unsupported host ${host_os} ${host_arch}. Use Ubuntu 24.04 AMD64 or Apple silicon macOS." ;;
esac

install_docker_repo_ubuntu() {
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  architecture=$(dpkg --print-architecture)
  # shellcheck disable=SC1091
  . /etc/os-release
  codename=${UBUNTU_CODENAME:-${VERSION_CODENAME}}
  {
    printf '%s\n' 'Types: deb'
    printf '%s\n' 'URIs: https://download.docker.com/linux/ubuntu'
    printf 'Suites: %s\n' "${codename}"
    printf '%s\n' 'Components: stable'
    printf 'Architectures: %s\n' "${architecture}"
    printf '%s\n' 'Signed-By: /etc/apt/keyrings/docker.asc'
  } | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
  sudo apt-get update
}

prepare_linux() {
  [ -r /etc/os-release ] || fail 'Unable to identify the Linux distribution.'
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != 24.04 ]; then
    fail "The automated Linux installer supports Ubuntu 24.04 AMD64; found ${ID:-unknown} ${VERSION_ID:-unknown}."
  fi
  command -v sudo >/dev/null 2>&1 || fail 'sudo is required.'

  missing_prerequisites=0
  for command_name in git jq tar apparmor_parser; do
    command -v "${command_name}" >/dev/null 2>&1 || missing_prerequisites=1
  done
  command -v docker >/dev/null 2>&1 || missing_prerequisites=1
  if command -v docker >/dev/null 2>&1; then
    sudo docker compose version >/dev/null 2>&1 || missing_prerequisites=1
  fi

  if [ "${missing_prerequisites}" -eq 1 ]; then
    ask_yes_no 'Install missing Ubuntu prerequisites and the official Docker Engine packages?' yes || \
      fail 'Required host prerequisites were not installed.'
    sudo -v
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl git jq tar apparmor-utils

    if ! command -v docker >/dev/null 2>&1; then
      conflicting_packages=$(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' \
        docker.io docker-compose docker-compose-v2 docker-doc docker-buildx \
        podman-docker containerd runc 2>/dev/null | awk '$2 ~ /^ii/ {print $1}' || true)
      if [ -n "${conflicting_packages}" ]; then
        say "Conflicting Docker packages are installed: ${conflicting_packages}"
        ask_yes_no 'Remove those packages before installing Docker Engine from Docker official repository?' no || \
          fail 'Resolve the Docker package conflict, then rerun the bootstrap.'
        # shellcheck disable=SC2086
        sudo apt-get remove -y ${conflicting_packages}
      fi
      install_docker_repo_ubuntu
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    elif ! sudo docker compose version >/dev/null 2>&1; then
      install_docker_repo_ubuntu
      sudo apt-get install -y docker-buildx-plugin docker-compose-plugin
    fi
  fi

  sudo systemctl enable --now docker
  sudo docker info >/dev/null
  linux_docker_endpoint=$(sudo docker context inspect "$(sudo docker context show)" \
    --format '{{.Endpoints.docker.Host}}')
  case "${linux_docker_endpoint}" in
    unix:///var/run/docker.sock|unix:///run/docker.sock) ;;
    *) fail "The root Docker context is not local: ${linux_docker_endpoint}" ;;
  esac
  sudo docker compose version >/dev/null
}

prepare_git_macos() {
  if git --version >/dev/null 2>&1; then
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    ask_yes_no 'Install Git with Homebrew?' yes || fail 'Git is required.'
    brew install git
    return
  fi
  ask_yes_no 'Open the Apple Command Line Tools installer to provide Git?' yes || \
    fail 'Git is required.'
  xcode-select --install >/dev/null 2>&1 || true
  say 'Complete the Apple Command Line Tools installation, then press Return.'
  IFS= read -r _answer </dev/tty || true
  git --version >/dev/null 2>&1 || fail 'Git is still unavailable.'
}

prepare_docker_macos() {
  current_user=$(id -un)
  export PATH="${HOME}/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

  docker_ready=0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && \
    docker compose version >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
    docker_ready=1
  fi

  docker_desktop_installed=0
  if open -Ra Docker >/dev/null 2>&1; then
    docker_desktop_installed=1
  fi

  if [ "${docker_ready}" -eq 0 ] && [ "${docker_desktop_installed}" -eq 0 ]; then
    say 'Docker Desktop is subject to Docker licensing terms. Review them before continuing:'
    say 'https://docs.docker.com/subscription/desktop-license/'
    ask_yes_no 'Download and install official Docker Desktop for Apple silicon?' no || \
      fail 'Docker Desktop is required.'
    [ ! -e /Volumes/Docker ] || \
      fail '/Volumes/Docker is already mounted. Eject it, then rerun the bootstrap.'
    docker_dmg="${work_dir}/Docker.dmg"
    curl -fL --retry 5 --retry-all-errors -o "${docker_dmg}" "${docker_desktop_dmg}"
    sudo hdiutil attach "${docker_dmg}" >/dev/null
    docker_dmg_mounted=1
    codesign --verify --deep --strict /Volumes/Docker/Docker.app
    spctl --assess --type execute /Volumes/Docker/Docker.app
    sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --user "${current_user}"
    sudo hdiutil detach /Volumes/Docker >/dev/null
    docker_dmg_mounted=0
    docker_desktop_installed=1
  fi

  if ! pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    say 'Rosetta 2 substantially improves this AMD64 image on Apple silicon.'
    if ask_yes_no 'Install Rosetta 2 and accept the Apple software license?' yes; then
      sudo softwareupdate --install-rosetta --agree-to-license
    fi
  fi

  if [ "${docker_ready}" -eq 0 ]; then
    if docker desktop start >/dev/null 2>&1; then
      :
    else
      open -gj -a Docker
    fi
    say 'Waiting for Docker Desktop. Complete any first-run or license screen in Docker Desktop.'
    attempt=0
    while ! docker info >/dev/null 2>&1; do
      attempt=$((attempt + 1))
      [ "${attempt}" -le 180 ] || fail 'Docker Desktop did not become ready within six minutes.'
      sleep 2
    done
  fi
  [ -z "${DOCKER_HOST:-}" ] || fail 'Unset DOCKER_HOST; the installer refuses remote Docker daemons.'
  macos_docker_endpoint=$(docker context inspect "$(docker context show)" \
    --format '{{.Endpoints.docker.Host}}')
  case "${macos_docker_endpoint}" in
    "unix://${HOME}/.docker/run/docker.sock"|unix:///var/run/docker.sock) ;;
    *) fail "The active Docker context is not the local Docker Desktop socket: ${macos_docker_endpoint}" ;;
  esac
  docker compose version >/dev/null 2>&1 || fail 'Docker Compose is unavailable.'
  docker buildx version >/dev/null 2>&1 || fail 'Docker Buildx is unavailable.'
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-desktop-bootstrap.XXXXXXXX")
case ${platform} in
  linux) prepare_linux ;;
  macos)
    prepare_git_macos
    prepare_docker_macos
    ;;
esac

checkout_dir="${work_dir}/codex-desktop-container"
say "Downloading ${repository_url} (${repository_ref})..."
git clone --depth 1 --branch "${repository_ref}" "${repository_url}" "${checkout_dir}" >/dev/tty
revision=$(git -C "${checkout_dir}" rev-parse HEAD)
say "Source revision: ${revision}"
ask_yes_no "Run the guided ${platform} installer from this revision?" no || \
  fail 'Installation cancelled before the container or persistent state was changed.'

case ${platform} in
  # Redirection intentionally happens in this parent shell so the elevated
  # installer inherits the controlling terminal instead of the curl pipe.
  linux) sudo bash "${checkout_dir}/scripts/install.sh" </dev/tty ;;
  macos) bash "${checkout_dir}/scripts/install.sh" </dev/tty ;;
esac
