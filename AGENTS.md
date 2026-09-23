# Repository instructions

## Deployment

Before installing, upgrading, recovering, or operating this service, read
`docs/agent-deployment.md`, `docs/installation.md`, `docs/tailscale.md`,
`docs/remote-browser-mcp.md`, and `SECURITY.md` completely.

Supported installation targets are exactly Apple silicon macOS with native
ARM64 Docker Desktop, and Ubuntu 24.04 AMD64 with local Docker Engine,
systemd, and AppArmor. Ubuntu may use either CRD plus noVNC or a CRD-free
noVNC-only mode; both work on a host with no graphical environment. Treat
Intel macOS, Linux ARM64, other Linux distributions, Windows/WSL, rootless or
remote Docker, non-AppArmor Linux, and serverless container platforms as
unsupported unless the user explicitly authorizes separate platform work.

Do not deploy merely because repository work was requested. Deployment requires
an explicit current request naming or clearly identifying the target host.

The default topology is Tailscale-only. An explicitly enabled public MCP Funnel
is the sole supported permanent public exception. It exposes HTTPS 443 only to
the dedicated MCP-only listener on `127.0.0.1:8445`; permanent noVNC moves to
tailnet-only Serve HTTPS 8443 and the temporary guest desktop remains on Funnel
HTTPS 10000. Do not publish Docker ports, raw VNC, raw Chrome debugging, or the
Docker socket. Keep the permanent gateway on `127.0.0.1:8443` and all
unauthenticated backends on `127.0.0.2`.

Use `scripts/install.sh` for a guided installation and
`scripts/verify-deployment.sh` for acceptance. Collect non-secret choices in the
documented order. Auth keys, PINs, gateway credentials,
cookies, and browser/Tailscale state must be entered only through their trusted
interactive surfaces and must never appear in chat, logs, commits, reports, or
command arguments. The short-lived CRD authorization code is the unavoidable exception:
Google's registration tool receives it in process arguments, so run that command
with shell history disabled and never copy the code into chat, logs, commits, or
reports.

Installation must run in a trusted interactive TTY. For a remote headless host,
use an approved SSH connection with PTY allocation and keep the installer
attached. Browser-based Tailscale enrollment does not require a browser on the
host: hand the short-lived login URL directly to the user, who may open it on a
different trusted computer or phone. Do not put that URL in logs, tickets, or a
durable transcript. Wait for approval, verify the sanitized account, MagicDNS
suffix, and node name, and only then continue to noVNC or CRD setup. noVNC is
not used to enroll Tailscale.

Preserve the persistent home, Tailscale state, machine identity, Chrome profile,
remote-browser gateway credentials, and Ubuntu CRD
registration across upgrades. A legacy noVNC password may remain in the home
volume but the unified gateway does not use it. Build every change under a new
immutable image tag and validate the real Tailscale, authenticated noVNC, MCP,
Codex, Chrome-extension, restart-persistence, scheduled-task, and
platform-specific Ubuntu CRD workflows before reporting a deployment complete.

The desktop user has passwordless sudo inside the container. Package installs
made interactively change only that container's writable layer; packages needed
after an image replacement belong in the Dockerfile. Chrome downloads must be
saved from Playwright's temporary artifacts into the persistent home volume.
Do not overwrite existing downloads, and verify a test download survives a
container restart when changing this path.

The Playwright MCP service uses the stock pinned package against the one
persistent headed Chrome/profile. A separate owner process launches Chrome
with Playwright's private pipe transport and publishes only a protected Unix
endpoint under `/run/remote-browser/browser`; the MCP connects with
`--endpoint`. Do not add a Chrome `--remote-debugging-port`, a TCP CDP listener,
a second Chrome, `--no-sandbox`, disabled extensions, or a local patch to
Playwright MCP. No Playwright browser extension or extension token is used.
The official ChatGPT extension is separate and optional for Codex `@Chrome`.

The MCP bearer token, one-click noVNC token, and Basic Auth credentials are
independent secrets. They are created once in the persistent machine-state
volume and retrieved only with the TTY-only `remote-browser-credentials`
command. Never run that command through an agent or capture its output.

`get_novnc_link` and `remote_chrome_request_human_intervention` return only the
stable tailnet link. Temporary public guest access is a separate, explicit
operation: call `create_temporary_novnc_link` only when the user states that
Tailscale is unavailable. It creates a guest-only foreground Funnel on HTTPS
10000 with a single-use link and a fixed 30-minute deadline. It must never expose
MCP, the permanent login route, or Basic Auth. Call
`revoke_temporary_novnc_link` when the user finishes. Never create Funnel access
proactively for ordinary login, MFA, CAPTCHA, or convenience.

Public MCP Funnel is separately opt-in with
`REMOTE_BROWSER_PUBLIC_MCP_FUNNEL=1`. It must never target the permanent
gateway. HTTPS 443 targets only `127.0.0.1:8445`, which has MCP authentication
routes and returns 404 for noVNC, guest, health, and arbitrary paths. Verify the
exact Tailscale TCP/Web/AllowFunnel topology rather than accepting substring
matches, and never use a global Funnel reset.

`scripts/install.sh` is the single public installer entry point. It supports
Ubuntu 24.04 AMD64 through systemd/AppArmor and Apple silicon macOS through
Docker Desktop, named volumes, and launchd. Tailscale must remain in userspace
mode on both platforms; do not add `/dev/net/tun`, `NET_ADMIN`, or `NET_RAW`.
Use `scripts/verify-macos.sh` for macOS acceptance.

Apple silicon must use the native ARM64 image and must not install Chrome Remote
Desktop. Its graphical access path is tailnet noVNC. Ubuntu AMD64 keeps CRD as
the backwards-compatible default, but the guided installer may build a matched
`INSTALL_CRD=0` image for noVNC-only headless operation. Never switch only the
runtime flag against an image whose CRD label does not match.
