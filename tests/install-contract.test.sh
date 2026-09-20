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
grep -Fq 'enroll_tailscale_in_browser' scripts/install-macos.sh
grep -Fq '.AuthURL // \"\"' scripts/install-macos.sh
grep -Fq 'Open this Tailscale login URL in a trusted browser:' scripts/install-macos.sh
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
grep -Fq "s/^CODEX_DESKTOP_CRD_ENABLED=//p" scripts/verify-deployment.sh
grep -Fq 'io.google.chrome-remote-desktop.enabled' scripts/verify-deployment.sh
grep -Fq 'packages+=(chrome-remote-desktop)' scripts/verify-deployment.sh
grep -Fq 'crd_status=NOT_INSTALLED' scripts/verify-deployment.sh
grep -Fq "pgrep -u 10001 -x Xvfb" scripts/verify-deployment.sh
grep -Fq '"${crd_incomplete}" == 1' scripts/verify-deployment.sh
grep -Fq 'Playwright MCP extension token is not configured.' \
  scripts/verify-deployment.sh
grep -Fq 'test ! -e /run/secrets/tailscale-auth-key' scripts/verify-deployment.sh
grep -Fq 'ss -lnt' scripts/verify-deployment.sh
grep -Fq 'test -x /usr/bin/ss' Dockerfile
grep -Fq 'xdg-mime default google-chrome.desktop' entrypoint.sh
grep -Fq 'xdg-mime default chatgpt.desktop x-scheme-handler/codex' entrypoint.sh
grep -Fq "xdg-mime query default \"\${mime_type}\"" healthcheck.sh
grep -Fq 'xdg-mime query default x-scheme-handler/codex' healthcheck.sh
grep -Fq 'TAILSCALE_ELF_MACHINE_HEX="3e00"' Dockerfile
grep -Fq 'CODEX_DESKTOP_TAILSCALE_ELF_MACHINE_HEX' Dockerfile healthcheck.sh
grep -Fq 'status --json 2>/dev/null || true' healthcheck.sh
grep -Fq "CHROME_REMOTE_DESKTOP_DEFAULT_DESKTOP_SIZES: \${DESKTOP_SIZES" compose.yaml
grep -Fq 'CODEX_DESKTOP_CRD_ENABLED: "${CODEX_DESKTOP_CRD_ENABLED:-1}"' compose.yaml
grep -Fxq 'CODEX_DESKTOP_CRD_ENABLED=1' deploy.env.example
grep -Fq "read_existing_value CODEX_DESKTOP_CRD_ENABLED 1" scripts/install.sh
grep -Fq 'Enable Chrome Remote Desktop in addition to authenticated noVNC?' scripts/install.sh
grep -Fq "printf 'CODEX_DESKTOP_CRD_ENABLED=%s\\n' \"\${crd_enabled}\"" scripts/install.sh
grep -Fq 'User-only desktop setup still required (no CRD registration):' scripts/install.sh
grep -Fq -- '--build-arg "INSTALL_CRD=${crd_enabled}"' scripts/install.sh
grep -Fq 'io.google.chrome-remote-desktop.enabled' scripts/install.sh
grep -Fq 'does not match the selected Chrome Remote Desktop mode' scripts/install.sh
grep -Fq '## Supported installation matrix' README.md
grep -Fq '## Supported topologies' docs/installation.md
grep -Fq '## Supported target matrix' docs/agent-deployment.md
grep -Fq 'Copy the printed Tailscale login URL directly to another trusted computer,' \
  docs/installation.md
grep -Fq 'noVNC is not used for Tailscale enrollment' AGENTS.md \
  docs/agent-deployment.md
grep -Fq 'The Docker host does not need a GUI or browser.' docs/tailscale.md
grep -Fq 'browser_home' docs/installation.md docs/remote-browser-mcp.md \
  docs/agent-deployment.md
grep -Fq -- '--bearer-token-env-var CODEX_BROWSER_HOME_TOKEN' \
  docs/installation.md docs/remote-browser-mcp.md docs/agent-deployment.md
grep -Fq '## Interrupted installation and enrollment recovery' \
  docs/installation.md
grep -Fq '## 7. Resume and recovery rules' docs/agent-deployment.md
grep -Fq 'short-lived sensitive device-claim link' SECURITY.md
grep -Fq -- '--tun=userspace-networking' supervisord.conf
grep -Fq 'platform: linux/arm64' compose.macos.yaml
grep -Fq 'INSTALL_CRD=0' scripts/install-macos.sh
grep -Fq 'io.google.chrome-remote-desktop.enabled' Dockerfile scripts/verify-macos.sh
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
