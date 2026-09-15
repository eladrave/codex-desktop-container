# Security

Do not commit Tailscale auth keys, Chrome Remote Desktop authorization codes or
PINs, Codex authentication state, SSH private keys, browser profiles, or files
from any persistent state directory.

Treat `/var/lib/codex-desktop/home/.config/google-chrome` as a credential
store. It can contain cookies, local storage, installed extensions, and active
website sessions. Full Chrome DevTools Protocol access is mediated by the Codex
browser integration and its approval flow. Do not add or publish a raw Chrome
debugging port through Docker, a reverse proxy, or a host-network mode.

noVNC and x11vnc bind only to container loopback. Tailscale runs with
`--tun=userspace-networking`; its netstack forwards authorized tailnet traffic
to noVNC on `127.0.0.1:6080`. The raw VNC backend binds to
`127.0.0.2:5900`, outside the netstack's same-port localhost forwarding target.
Keep the VNC password file private, require a tailnet ACL for TCP 6080, and do
not publish TCP 5900 or 6080 through Docker.
The noVNC page uses HTTP inside the encrypted tailnet, so do not access it over
an untrusted non-Tailscale route. Classic VNC authentication uses only the
first eight password characters; tailnet identity and ACLs are therefore the
primary access boundary.

The example configuration deliberately contains no credentials. Authenticate
Tailscale and Chrome Remote Desktop interactively after the container starts.

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
Codex, Chrome, CRD, noVNC, and Tailscale state. Keep the backup directory
`root:root` mode `0700`, keep archives mode `0600`, encrypt copies before they
leave the host, and delete retained backups only through a separately approved
retention process.

Apple silicon backups under `~/.local/share/codex-desktop/backups` contain the
same credential-bearing state exported from named Docker volumes. Keep that
directory private and apply the same encryption and retention rules.

The Apple silicon Compose override sets `GODEBUG=cpu.avx2=off` to avoid a
Go/Rosetta cryptographic implementation bug. Tailscale still performs its
normal encrypted Noise and WireGuard protocols; only the faulty emulated AVX2
optimization is disabled.

Report a suspected vulnerability privately through GitHub's security advisory
interface for this repository. Do not open a public issue containing secrets.
