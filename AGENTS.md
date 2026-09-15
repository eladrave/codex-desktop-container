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

Preserve the persistent home, Tailscale state, machine identity, CRD
registration, Chrome profile, and noVNC password across upgrades. Build every
change under a new immutable image tag and validate the real Tailscale, CRD,
noVNC, Codex, Chrome-extension, restart-persistence, and scheduled-task
workflows before reporting a deployment complete.
