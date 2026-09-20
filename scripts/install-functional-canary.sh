#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'Functional canary installation failed: %s\n' "$1" >&2
  exit 1
}

[[ "$#" == 0 ]] || fail 'this command accepts no arguments'

case "$(uname -s)" in
  Linux)
    [[ ${EUID} -eq 0 ]] || fail 'run with sudo or as root on Linux'
    canary=/opt/services/codex-desktop/scripts/remote-browser-functional-canary.sh
    [[ -x "${canary}" && ! -L "${canary}" ]] || fail 'installed canary is unavailable'
    "${canary}"
    service=/etc/systemd/system/codex-desktop-mcp-canary.service
    timer=/etc/systemd/system/codex-desktop-mcp-canary.timer
    install -o root -g root -m 0644 /dev/stdin "${service}" <<EOF
[Unit]
Description=Codex Desktop Playwright MCP functional canary
After=network-online.target codex-desktop.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
ExecStart=${canary}
TimeoutStartSec=180
NoNewPrivileges=yes
PrivateDevices=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
RestrictAddressFamilies=AF_UNIX
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
EOF
    install -o root -g root -m 0644 /dev/stdin "${timer}" <<'EOF'
[Unit]
Description=Run the Codex Desktop Playwright MCP canary hourly

[Timer]
OnCalendar=hourly
Persistent=yes
AccuracySec=1m
Unit=codex-desktop-mcp-canary.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now codex-desktop-mcp-canary.timer
    printf 'Installed hourly systemd canary. Logs: journalctl -u codex-desktop-mcp-canary.service\n'
    ;;
  Darwin)
    [[ ${EUID} -ne 0 ]] || fail 'run as the installed macOS user, not root'
    canary=${HOME}/.local/share/codex-desktop/source/scripts/remote-browser-functional-canary.sh
    [[ -x "${canary}" && ! -L "${canary}" ]] || fail 'installed canary is unavailable'
    "${canary}"
    agent_dir=${HOME}/Library/LaunchAgents
    log_dir=${HOME}/.local/share/codex-desktop/logs
    plist=${agent_dir}/com.eladrave.codex-desktop-mcp-canary.plist
    install -d -m 0700 "${agent_dir}" "${log_dir}"
    temporary_plist="$(mktemp "${agent_dir}/.mcp-canary.XXXXXXXX")"
    trap 'rm -f -- "${temporary_plist:-}"' EXIT
    cat >"${temporary_plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.eladrave.codex-desktop-mcp-canary</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>${canary}</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>${log_dir}/mcp-canary.out.log</string>
  <key>StandardErrorPath</key><string>${log_dir}/mcp-canary.err.log</string>
</dict>
</plist>
EOF
    chmod 0600 "${temporary_plist}"
    mv -f "${temporary_plist}" "${plist}"
    trap - EXIT
    launchctl bootout "gui/${UID}" "${plist}" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/${UID}" "${plist}"
    printf 'Installed hourly launchd canary. Logs: %s/mcp-canary.*.log\n' "${log_dir}"
    ;;
  *) fail 'unsupported host platform' ;;
esac

