#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

scripts/install.sh --help >/dev/null
scripts/verify-deployment.sh --help >/dev/null
scripts/install-macos.sh --help >/dev/null
scripts/verify-macos.sh --help >/dev/null
grep -Fq -- '--auth-key=file:/run/secrets/tailscale-auth-key' scripts/install.sh
grep -Fq -- '--auth-key=file:/run/secrets/tailscale-auth-key' scripts/install-macos.sh
grep -Fq -- "tailscale up --hostname=\"\${tailscale_hostname}\" --ssh" scripts/install.sh
grep -Fq 'prompt_secret tailscale_auth_key' scripts/install.sh
grep -Fq 'prompt_secret tailscale_auth_key' scripts/install-macos.sh
grep -Fq 'Do not paste it into chat.' scripts/install.sh
grep -Fq "rm -f -- \"\${secret_path}\"" scripts/install.sh
grep -Fq "rm -f -- \"\${secret_path}\"" scripts/install-macos.sh
grep -Fq 'repo_git archive --format=tar HEAD' scripts/install.sh
grep -Fq 'docker compose --project-name codex-desktop' scripts/install.sh
grep -Fq 'scripts/verify-deployment.sh' scripts/install.sh
grep -Fq 'persistent-state.tar' scripts/install.sh
grep -Fq 'That image tag already belongs to another source revision.' \
  scripts/install.sh scripts/install-macos.sh
# shellcheck disable=SC2016
grep -Fq 'short_revision="${source_revision:0:12}"' \
  scripts/install.sh scripts/install-macos.sh
grep -Fq 'org.opencontainers.image.revision' scripts/install.sh Dockerfile
grep -Fq 'Existing Tailscale identity was preserved.' scripts/install.sh
grep -Fq 'Does this new enrollment belong to the intended account/tailnet?' scripts/install.sh
grep -Fq 'deployment_activated' scripts/install.sh
grep -Fq -- '--allow-incomplete' scripts/verify-deployment.sh docs/installation.md
grep -Fq 'Chrome Remote Desktop is not registered and STARTED.' scripts/verify-deployment.sh
grep -Fq 'noVNC password is not configured.' scripts/verify-deployment.sh
grep -Fq 'test ! -e /run/secrets/tailscale-auth-key' scripts/verify-deployment.sh
grep -Fq 'ss -lnt' scripts/verify-deployment.sh
grep -Fq 'test -x /usr/bin/ss' Dockerfile
grep -Fq 'status --json 2>/dev/null || true' healthcheck.sh
grep -Fq "CHROME_REMOTE_DESKTOP_DEFAULT_DESKTOP_SIZES: \${DESKTOP_SIZES" compose.yaml
grep -Fq -- '--tun=userspace-networking' supervisord.conf
grep -Fq 'platform: linux/amd64' compose.macos.yaml
grep -Fq 'type: volume' compose.macos.yaml
grep -Fq 'raw.githubusercontent.com/eladrave/codex-desktop-container/main/bootstrap.sh' bootstrap.sh README.md

if grep -Fq 'CHROME_REMOTE_DESKTOP_DEFAULT_DESKTOP_SIZES=' supervisord.conf; then
  echo 'Supervisor must inherit the configured desktop-size environment.' >&2
  exit 1
fi

if grep -Eq '^TS_.*KEY=' deploy.env.example; then
  echo 'Tailscale credentials must not be stored in deploy.env.example.' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]+ports:' compose.yaml; then
  echo 'The Tailscale-only Compose file must not publish ports.' >&2
  exit 1
fi

if rg -n 'tskey-[A-Za-z0-9_-]{20,}' --glob '!tests/install-contract.test.sh' .; then
  echo 'A literal Tailscale auth key appears in the repository.' >&2
  exit 1
fi
