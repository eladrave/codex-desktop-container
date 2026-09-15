# Repository instructions

## Deployment

Before installing, upgrading, recovering, or operating this service, read
`docs/agent-deployment.md`, `docs/installation.md`, `docs/tailscale.md`, and
`SECURITY.md` completely.

Do not deploy merely because repository work was requested. Deployment requires
an explicit current request naming or clearly identifying the target host.

The supported topology is Tailscale-only. Do not add or publish LAN/public
ports, raw VNC, raw Chrome debugging, or the Docker socket during deployment.

Use `scripts/install.sh` for a guided installation and
`scripts/verify-deployment.sh` for acceptance. Collect non-secret choices in the
documented order. Auth keys, PINs, noVNC passwords, cookies, and
browser/Tailscale state must be entered only through their trusted interactive
surfaces and must never appear in chat, logs, commits, reports, or command
arguments. The short-lived CRD authorization code is the unavoidable exception:
Google's registration tool receives it in process arguments, so run that command
with shell history disabled and never copy the code into chat, logs, commits, or
reports.

Preserve the persistent home, Tailscale state, machine identity, Chrome profile,
noVNC password, and Ubuntu CRD registration across upgrades. Build every change
under a new immutable image tag and validate the real Tailscale, noVNC, Codex,
Chrome-extension, restart-persistence, scheduled-task, and platform-specific
Ubuntu CRD workflows before reporting a deployment complete.

`scripts/install.sh` is the single public installer entry point. It supports
Ubuntu 24.04 AMD64 through systemd/AppArmor and Apple silicon macOS through
Docker Desktop, named volumes, and launchd. Tailscale must remain in userspace
mode on both platforms; do not add `/dev/net/tun`, `NET_ADMIN`, or `NET_RAW`.
Use `scripts/verify-macos.sh` for macOS acceptance.

Apple silicon must use the native ARM64 image and must not install Chrome Remote
Desktop. Its graphical access path is tailnet noVNC. Ubuntu AMD64 retains CRD.
