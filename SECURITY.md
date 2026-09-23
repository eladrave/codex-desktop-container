# Security

Do not commit Tailscale auth keys, Chrome Remote Desktop authorization codes or
PINs, Codex authentication state, SSH private keys, browser profiles, gateway
credentials, or files from any persistent state
directory.

The browser-enrollment `AuthURL` is a short-lived sensitive device-claim link.
It may be handed directly to the user who is approving the node and opened on a
different trusted machine, but it must not be stored in chat, logs, tickets,
documentation, shell history, or telemetry. noVNC is not required for this
approval. After approval, report only sanitized account, MagicDNS, node-name,
and online-state fields.

Treat the persistent Chrome profile under
`/var/lib/codex-desktop/home/.config/remote-browser/chrome-profile` as a
credential store. It can contain cookies, local storage, installed extensions,
and active website sessions. Full Chrome DevTools Protocol access is mediated
by the Codex browser integration and its approval flow. Remote Playwright MCP
controls the same visible Chrome through a private Unix endpoint created by
Playwright's pipe transport. The endpoint directory is mode `0700`, owned by
`codex`, and cannot be traversed by the guest-proxy UID. Do not add
`--remote-debugging-port`, any TCP CDP listener, or expose the Unix endpoint
through Docker, a reverse proxy, Tailscale, a bind mount, or host networking.
Keep the tailnet policy default-deny for every other TCP port on this node and
grant intended clients only Tailscale SSH and HTTPS 443.

Tailscale Serve is the default ingress and exposes only HTTPS 443 to the
authenticated gateway on `127.0.0.1:8443`. When public MCP Funnel is explicitly
enabled, private Serve moves to HTTPS 8443 and public Funnel HTTPS 443 targets
the separate MCP-only listener on `127.0.0.1:8445`. That listener has no
permanent login, Basic Auth, noVNC, guest, health, generic proxy, or CDP route.
MCP, noVNC, and x11vnc bind to
`127.0.0.2` on ports 8932, 6081, and 5900. Tailscale runs with
`--tun=userspace-networking`; binding an unauthenticated backend to
`127.0.0.1` could make the same port tailnet-reachable and bypass the gateway.
Do not change these backends to `127.0.0.1`, a wildcard address, or IPv6. Do
not publish any of these ports through Docker.

The desktop user `codex` has passwordless `sudo` inside the container so a
person at the desktop can install packages. Compose therefore does not set
`no-new-privileges`. The MCP server exposes server-process code execution as
`codex`, so an authenticated MCP token holder has container-root authority and
can read root-owned gateway and Tailscale state. Keep MCP tokens private, restrict
tailnet access, retain the capability allowlist, and never mount the Docker
socket or host-sensitive directories. This is container root, not macOS host
root. Interactive OS package installs change only the container writable layer
and are lost when the image is replaced; bake required packages into the image.

Playwright stores downloads as temporary artifacts and removes them when the
browser context closes. The browser owner copies completed downloads into a
collision-safe file in the persistent home volume, using the Chrome-selected
folder only when it resolves inside `/home/codex`. The default is
`/home/codex/Downloads`. Existing downloaded files are never overwritten.

Temporary guest access is the only supported public desktop ingress. It uses a
foreground Tailscale Funnel on external HTTPS 10000 and a separate guest-only
proxy on `127.0.0.1:8444`; it never funnels the permanent gateway on 8443.
The guest proxy has no MCP, permanent-login, Basic Auth, generic proxy, or
health route. A 256-bit link token is redeemed at most once for a distinct
Secure, HttpOnly, SameSite=Strict cookie. Both remain bounded by the original
30-minute deadline. Revocation or expiry destroys open guest sockets and stops
the foreground Funnel process. Guest state is memory-only and must not return
after a broker or container restart.

The optional permanent public MCP ingress uses the independently generated MCP
token and no desktop route. Funnel visibility applies to the entire external
port, so never Funnel the combined gateway on `127.0.0.1:8443`. Clear and
verify only the service-owned HTTPS port before changing it between Serve and
Funnel; never use `tailscale funnel reset`, which could destroy the independent
guest configuration.

Creating guest access is a security-sensitive, mutating action. The MCP tool
must accept no arguments and must be used only after the user explicitly says
Tailscale is unavailable. Never accept a client-provided port, target, command,
duration, path, executable, or environment value. Never use `tailscale funnel
reset`, background Funnel, or the permanent gateway as the Funnel target.
Treat the guest link as a password-equivalent full-desktop credential. A guest
who controls this desktop is within the same desktop-user trust boundary as the
browser and can access visible authenticated state; temporary ingress is not a
sandbox from the desktop itself.

The noVNC backend intentionally has no inner VNC password because it is
reachable only through the HTTPS gateway. The gateway requires either its
one-click token cookie or independent Basic Auth, validates WebSocket requests,
and discards access logs. Tailnet identity and restrictive ACLs remain the outer
boundary. A legacy `.vnc/passwd` may remain in persistent state but is unused.

Gateway credentials live under the root-owned persistent machine-state
directory with mode `0700` for the directory and `0600` for the file. Retrieve
them only with the TTY-only `remote-browser-credentials` command. No Playwright
browser-extension token exists. The official ChatGPT extension, when enabled
for Codex `@Chrome`, remains ordinary credential-bearing browser state and is
not used to authenticate remote MCP. Gateway secrets do not belong in
`deploy.env`, process arguments, chat, logs, or command output captured by an
agent.

The example configuration deliberately contains no credentials. Authenticate
Tailscale interactively after the container starts. Ubuntu requires interactive
Chrome Remote Desktop registration only when CRD is enabled; noVNC-only mode
starts the isolated container display without Google registration. Apple
silicon does not install CRD.

The one-line bootstrap is mutable when fetched from the `main` branch. For
review-sensitive environments, download and inspect `bootstrap.sh` before
running it or set the installation source to a reviewed release tag. The
bootstrap prints the exact cloned commit before requesting final confirmation.

The guided installer accepts a Tailscale auth key only through a hidden
terminal prompt. It streams the value into the container, stores it temporarily
at `/run/secrets/tailscale-auth-key` with mode `0600`, invokes the file-backed
Tailscale enrollment option, unsets the shell variable, and removes the file on
success or failure. Never add an auth key to `deploy.env`, a command argument,
Git, an image layer, chat, logs, or telemetry.

Upgrade backups under `/var/backups/codex-desktop` contain credential-bearing
Codex, Chrome, CRD, gateway, and Tailscale state. Keep the
backup directory `root:root` mode `0700`, keep archives mode `0600`, encrypt copies before they
leave the host, and delete retained backups only through a separately approved
retention process.

Apple silicon backups under `~/.local/share/codex-desktop/backups` contain the
same credential-bearing state exported from named Docker volumes. Keep that
directory private and apply the same encryption and retention rules.

Apple silicon images use native ARM64 packages throughout and omit Chrome
Remote Desktop. Do not add the unavailable AMD64 CRD package through multiarch
or reintroduce Rosetta into this security boundary.

Report a suspected vulnerability privately through GitHub's security advisory
interface for this repository. Do not open a public issue containing secrets.
