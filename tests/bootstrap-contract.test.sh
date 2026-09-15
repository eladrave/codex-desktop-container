#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

bootstrap_output="$(sh bootstrap.sh --help)"
grep -Fq "curl --proto '=https' --tlsv1.2" <<<"${bootstrap_output}"
grep -Fq 'Ubuntu 24.04 AMD64' <<<"${bootstrap_output}"
grep -Fq 'macOS on Apple silicon' <<<"${bootstrap_output}"

grep -Fq 'sudo bash "${checkout_dir}/scripts/install.sh" </dev/tty' bootstrap.sh
grep -Fq 'bash "${checkout_dir}/scripts/install.sh" </dev/tty' bootstrap.sh
if grep -Fq 'scripts/install-macos.sh"' bootstrap.sh; then
  echo 'The bootstrap must invoke the single public scripts/install.sh entry point.' >&2
  exit 1
fi
grep -Fq 'exec bash "${repo_dir}/scripts/install-macos.sh" "$@"' scripts/install.sh
grep -Fq 'platform: linux/arm64' compose.macos.yaml
grep -Fq 'CODEX_DESKTOP_CRD_ENABLED: "0"' compose.macos.yaml
grep -Fq 'TAILSCALE_BINARY_PLATFORM=linux/arm64' scripts/install-macos.sh
grep -Fq 'TAILSCALE_BINARY_ARCH=arm64' scripts/install-macos.sh
grep -Fq 'TAILSCALE_ELF_MACHINE_HEX=b700' scripts/install-macos.sh
grep -Fq 'io.tailscale.binary.arch' Dockerfile scripts/verify-macos.sh
grep -Fq 'INSTALL_CRD=0' scripts/install-macos.sh
if rg -n 'GODEBUG=cpu\.avx2|install-rosetta|--platform linux/amd64' \
  bootstrap.sh scripts/install-macos.sh compose.macos.yaml; then
  echo 'Apple silicon runtime must remain native ARM64 without Rosetta workarounds.' >&2
  exit 1
fi
grep -Fq 'codex-desktop-home' scripts/verify-macos.sh
grep -Fq -- '--tun=userspace-networking' supervisord.conf

if rg -n '/dev/net/tun|NET_ADMIN|NET_RAW' \
  compose.yaml compose.macos.yaml bootstrap.sh scripts/install.sh \
  scripts/install-macos.sh supervisord.conf; then
  echo 'Portable installation must use userspace Tailscale only.' >&2
  exit 1
fi
