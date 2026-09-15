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
grep -Fq 'platform: linux/amd64' compose.macos.yaml
grep -Fq 'GODEBUG: cpu.avx2=off' compose.macos.yaml
grep -Fq 'codex-desktop-home' scripts/verify-macos.sh
grep -Fq -- '--tun=userspace-networking' supervisord.conf

if rg -n '/dev/net/tun|NET_ADMIN|NET_RAW' \
  compose.yaml compose.macos.yaml bootstrap.sh scripts/install.sh \
  scripts/install-macos.sh supervisord.conf; then
  echo 'Portable installation must use userspace Tailscale only.' >&2
  exit 1
fi
