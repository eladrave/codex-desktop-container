# Repository instructions

## Deployment

Before installing, upgrading, recovering, or operating this service, read
`docs/agent-deployment.md`, `docs/installation.md`, `docs/tailscale.md`,
`docs/remote-browser-mcp.md`, and `SECURITY.md` completely.

Do not deploy merely because repository work was requested. Deployment requires
an explicit current request naming or clearly identifying the target host.

The supported topology is Tailscale-only. Do not add or publish LAN/public
ports, raw VNC, raw Chrome debugging, or the Docker socket during deployment.
The only browser gateway ingress is Tailscale Serve HTTPS on TCP 443. Keep the
gateway on `127.0.0.1:8443` and all unauthenticated backends on `127.0.0.2` so
Tailscale userspace networking cannot expose them through same-port forwarding.

Use `scripts/install.sh` for a guided installation and
`scripts/verify-deployment.sh` for acceptance. Collect non-secret choices in the
documented order. Auth keys, PINs, gateway credentials, extension tokens,
cookies, and browser/Tailscale state must be entered only through their trusted
interactive surfaces and must never appear in chat, logs, commits, reports, or
command arguments. The short-lived CRD authorization code is the unavoidable exception:
Google's registration tool receives it in process arguments, so run that command
with shell history disabled and never copy the code into chat, logs, commits, or
reports.

Preserve the persistent home, Tailscale state, machine identity, Chrome profile,
remote-browser gateway credentials, Playwright extension token, and Ubuntu CRD
registration across upgrades. A legacy noVNC password may remain in the home
volume but the unified gateway does not use it. Build every change under a new
immutable image tag and validate the real Tailscale, authenticated noVNC, MCP,
Codex, Chrome-extension, restart-persistence, scheduled-task, and
platform-specific Ubuntu CRD workflows before reporting a deployment complete.

The Playwright MCP service uses the stock pinned package in `--extension` mode
against the one persistent visible Chrome/profile. Do not add a Chrome
`--remote-debugging-port`, TCP 9222, a second Chrome, or a local patch to
Playwright MCP. Browser-extension token entry is a user-only step performed
with `/usr/local/bin/remote-browser-extension-token` at its hidden prompt.
Never copy the token into chat, a command argument, logs, or `deploy.env`.

The MCP bearer token, one-click noVNC token, and Basic Auth credentials are
independent secrets. They are created once in the persistent machine-state
volume and retrieved only with the TTY-only `remote-browser-credentials`
command. Never run that command through an agent or capture its output.

`get_novnc_link` and `remote_chrome_request_human_intervention` return only the
stable tailnet link. Temporary public guest access is a separate, explicit
operation: call `create_temporary_novnc_link` only when the user states that
Tailscale is unavailable. It creates a guest-only foreground Funnel on HTTPS
8443 with a single-use link and a fixed 30-minute deadline. It must never expose
MCP, the permanent login route, or Basic Auth. Call
`revoke_temporary_novnc_link` when the user finishes. Never create Funnel access
proactively for ordinary login, MFA, CAPTCHA, or convenience.

`scripts/install.sh` is the single public installer entry point. It supports
Ubuntu 24.04 AMD64 through systemd/AppArmor and Apple silicon macOS through
Docker Desktop, named volumes, and launchd. Tailscale must remain in userspace
mode on both platforms; do not add `/dev/net/tun`, `NET_ADMIN`, or `NET_RAW`.
Use `scripts/verify-macos.sh` for macOS acceptance.

Apple silicon must use the native ARM64 image and must not install Chrome Remote
Desktop. Its graphical access path is tailnet noVNC. Ubuntu AMD64 retains CRD.
