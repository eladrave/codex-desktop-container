# Codex Desktop container

[![CI](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml/badge.svg)](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml)

A persistent Linux desktop container for the official Codex desktop app, with
Xfce, an always-on Google Chrome, Tailscale, Tailscale SSH, authenticated noVNC,
and a remote Playwright MCP server. Ubuntu AMD64 includes optional Chrome Remote
Desktop and can instead run in noVNC-only mode on a server with no host GUI.
Apple silicon uses a fully native ARM64 image and noVNC as its graphical access
path. Codex, Playwright MCP, and noVNC all use the same visible Chrome profile
and desktop session.

This is a single-container, in-place replacement for `remotechromemcp`. It
preserves bearer-authenticated MCP, optional token-path compatibility, the
browser-operation playbook, human-handoff tools, a one-click noVNC URL, and
Basic Auth fallback. It uses stock pinned Playwright MCP in extension mode and
does not open Chrome's debugging port.

The MCP handoff tools return the stable, bookmarkable tailnet noVNC link. When
the user explicitly cannot use Tailscale, a separate tool can create a
single-use public guest link with a fixed 30-minute maximum lifetime. That
temporary Funnel exposes only a dedicated noVNC proxy on HTTPS 8443; it never
publishes MCP or the permanent gateway and can be revoked immediately.

The default is Tailscale-only. An explicit `compose.codexgui.yaml` override
implements the existing central-edge replacement contract while keeping the
default deployment detached from codexgui's `edge` network. Applying that
override is a separate production operation and requires an explicit decision.
It reuses the existing remote browser profile and public credentials in place
so existing MCP and noVNC clients do not need new connection details.

The image uses the official unified Linux package named `chatgpt`; the desktop
application it launches is Codex. Package versions, download URLs, base images,
and checksums are pinned in the `Dockerfile` for reproducible builds.

## Documentation

- [Complete installation and upgrade guide](docs/installation.md)
- [Tailscale enrollment, access, and in-container usage](docs/tailscale.md)
- [Remote browser MCP, credentials, and noVNC gateway](docs/remote-browser-mcp.md)
- [Agent deployment question and execution playbook](docs/agent-deployment.md)
- [Security boundaries](SECURITY.md)

## Supported installation matrix

| Host | Host GUI required | Desktop mode | How Tailscale is approved |
| --- | --- | --- | --- |
| Apple silicon macOS | A logged-in macOS session is required for Docker Desktop and launchd, but the container does not use the host display | Native ARM64, noVNC only, no CRD, no Rosetta | Open the URL printed by the installer on this Mac or any other trusted browser |
| Ubuntu 24.04 AMD64 server or workstation | No | noVNC-only | Keep the SSH/console installer attached and open its printed URL on another trusted computer or phone |
| Ubuntu 24.04 AMD64 server or workstation | No | CRD plus noVNC | Approve Tailscale from any trusted browser, then complete Google's headless CRD registration from a trusted browser and Tailscale SSH |

The automated installer does not currently support Intel macOS, Linux ARM64,
other Linux distributions, Windows/WSL, rootless or remote Docker, Linux without
AppArmor, or serverless container platforms. A machine outside the matrix needs
separate platform work; do not force an AMD64 image through Rosetta or another
emulation layer and describe it as native support.

## One-line guided installation

Run this from an interactive terminal on Ubuntu 24.04 AMD64 or Apple silicon
macOS:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/eladrave/codex-desktop-container/main/bootstrap.sh | sh
```

The bootstrap detects the platform, asks before installing missing host
prerequisites, clones one exact repository revision, and invokes the same
`./scripts/install.sh` entry point on both platforms. The installer then builds
the pinned native image for the detected host, asks all non-secret
configuration questions, enrolls
Tailscale through a hidden auth-key prompt or browser URL, configures the
authenticated HTTPS gateway, starts the container, and prints the remaining
platform-specific Codex and Playwright-extension steps.

On a headless Ubuntu host, run the installer in an SSH session with a PTY. The
browser-enrollment option prints a short-lived Tailscale login URL in that
terminal and waits. Copy the URL to any other trusted Mac, PC, phone, or tablet,
approve the intended tailnet there, then return to the waiting terminal. The
headless host never needs a browser, and noVNC is not involved in enrollment.

For review-before-execution, download and inspect the bootstrap first:

```sh
curl --proto '=https' --tlsv1.2 -fsSLo bootstrap.sh \
  https://raw.githubusercontent.com/eladrave/codex-desktop-container/main/bootstrap.sh
less bootstrap.sh
sh bootstrap.sh
```

On Apple silicon, Docker Desktop runs a native ARM64 Codex/Chrome/Xfce image and
stores credential state in named Docker volumes. Chrome Remote Desktop is not
installed because its pinned Linux release has no ARM64 artifact. The installer
adds a user launch agent that starts Docker Desktop and this Compose project at
login. Scheduled tasks still require the Mac to remain powered on, awake, and
logged in; macOS sleep suspends Docker Desktop and the container.

The native image avoids Rosetta entirely, including the broken
[Go/Rosetta AVX2 ChaCha20-Poly1305 path](https://github.com/golang/go/issues/79205)
that prevented Tailscale browser enrollment.

## What persists

The Compose configuration keeps the state that must survive container
recreation in these host directories:

| Host path | Container path | Contents |
| --- | --- | --- |
| `/var/lib/codex-desktop/home` | `/home/codex` | Codex login and settings, Ubuntu CRD registration, Xfce settings, projects, Chrome profile, extensions, and Playwright extension token |
| `/var/lib/codex-desktop/tailscale` | `/var/lib/tailscale` | Tailscale node identity and preferences |
| `/var/lib/codex-desktop/machine` | `/var/lib/codex-desktop-persistent` | Stable DBus machine identity and root-only remote-browser gateway credentials |

Those host paths apply to Ubuntu. The Apple silicon Compose override uses the
named volumes `codex-desktop-home`, `codex-desktop-tailscale`, and
`codex-desktop-machine` for the same container targets.

No ports are published. Tailscale and, when enabled on Ubuntu, Chrome Remote
Desktop establish outbound connections. No Docker socket is mounted, and no
existing Codex profile is copied into the image.

Tailscale runs entirely in userspace, so the container needs no TUN device or
network-administration capabilities. Tailscale Serve terminates tailnet HTTPS
on TCP 443 and forwards only to the authenticated gateway on
`127.0.0.1:8443`. MCP, noVNC, and x11vnc bind to the private loopback alias
`127.0.0.2`; none is published by Docker or directly reachable through the
userspace netstack's same-port forwarding.

Codex and Chrome are started by Xfce, share the managed display and session bus,
and use single-instance restart wrappers for unattended work.
The container registers Chrome as the default HTTP/HTTPS browser and Codex as
the `codex:` callback handler so ChatGPT sign-in can complete inside the same
persistent desktop session.
Browser control supports both the official ChatGPT browser extension with
Codex's approval model and stock Playwright MCP `--extension` mode. Both attach
to the same persistent visible Chrome. This image does not pass
`--remote-debugging-port` to Chrome and nothing listens on TCP 9222.

## Requirements

- Ubuntu 24.04 AMD64, or Apple silicon macOS
- Docker Engine with Compose on Linux, or Docker Desktop on macOS
- AppArmor tools on an AppArmor-enabled Linux host
- A Tailscale account and policy that permits Tailscale SSH
- A tailnet ACL permitting intended clients to reach this node on TCP 443
- On Ubuntu only when CRD is enabled, a Google account authorized for Chrome
  Remote Desktop
- At least 8 GiB of host RAM is recommended for Codex, Chrome, and the desktop
  session together

The Codex Electron sandbox needs unprivileged user namespaces. This deployment
loads an executable-specific AppArmor profile and runs the outer container with
an explicit capability allowlist, `no-new-privileges`, and no published ports.
It does not disable Chromium's application sandbox.

For compatibility, Compose disables Docker's default AppArmor and seccomp
profiles for this container before the executable-specific Codex AppArmor
profile attaches. That weakens one layer of container isolation. Run this only
on a dedicated, trusted Linux host or VM, keep the capability allowlist intact,
and do not add host-sensitive mounts such as the Docker socket.

## Manual Ubuntu AMD64 build

```bash
git clone https://github.com/eladrave/codex-desktop-container.git
cd codex-desktop-container
revision="$(git rev-parse HEAD)"
docker buildx build --platform linux/amd64 --load \
  --build-arg "VCS_REF=${revision}" \
  --tag codex-desktop:chatgpt-26.820.60940-crd-154.0.8037.11-ts1.102.4-11 \
  .
```

Every downloaded Debian package is checked against its pinned SHA-256 digest.
If an upstream version changes, update the version, versioned URL, and checksum
together and rebuild as a new immutable image tag.

## Guided installation from a clone

The same command works from a clean clone on both supported platforms:

```bash
./scripts/install.sh
```

On Ubuntu the script requests root through the documented `sudo` bootstrap
path and installs a systemd service. When run directly on Ubuntu, invoke it as
`sudo ./scripts/install.sh`. On Apple silicon, run it as the normal user; it
uses Docker Desktop, named volumes, and a user launch agent.

The installer asks for the host configuration, whether Ubuntu should enable
Chrome Remote Desktop, and the Tailscale enrollment method. CRD remains enabled
by default for backwards compatibility. Choosing no builds a no-CRD image and
starts the container's own Xvfb/Xfce desktop immediately, so authenticated
noVNC works on a GUI-less host without Google CRD registration.
A one-time Tailscale auth key is accepted only through a hidden terminal prompt
and is removed from container tmpfs immediately after use. The alternative
browser flow prints a login URL for the user to open and approve in the intended
account and tailnet. Gateway credentials are generated silently in persistent
root-only state and are never added to `deploy.env`.

The installer does not install Docker, publish LAN/public ports, or automate
Google, Codex, Chrome-extension, or PIN entry. It prints the ordered user-only
steps for those actions. See the [complete installation guide](docs/installation.md).

## Manual installation on the host

The supplied systemd unit expects the deployment under
`/opt/services/codex-desktop` and its environment file under
`/etc/codex-desktop`:

```bash
sudo install -d -m 0755 /opt/services/codex-desktop
git archive --format=tar HEAD | sudo tar -x -C /opt/services/codex-desktop
git rev-parse HEAD | sudo tee /opt/services/codex-desktop/REVISION >/dev/null
sudo install -d -m 0755 /etc/codex-desktop
sudo install -m 0600 deploy.env.example /etc/codex-desktop/deploy.env
sudo install -m 0644 codex-desktop.service \
  /etc/systemd/system/codex-desktop.service
sudo systemctl daemon-reload
```

Edit `/etc/codex-desktop/deploy.env` if you want a different timezone,
container hostname, Tailscale hostname, desktop sizes, or container resource
limits. Set `CODEX_DESKTOP_CRD_ENABLED=0` only with an image built using
`--build-arg INSTALL_CRD=0`; the default `1` preserves CRD behavior. Do not put
Tailscale keys, CRD codes, PINs, or other credentials in that file.

## First start and Tailscale enrollment

Create the persistent directories, start the Compose project, and enroll the
node interactively:

```bash
sudo install -d -o 10001 -g 10001 -m 0700 \
  /var/lib/codex-desktop/home
sudo install -d -o 0 -g 0 -m 0700 \
  /var/lib/codex-desktop/tailscale \
  /var/lib/codex-desktop/machine
sudo docker compose \
  --project-name codex-desktop \
  --env-file /etc/codex-desktop/deploy.env \
  -f /opt/services/codex-desktop/compose.yaml \
  up -d
sudo docker exec -it codex-desktop-desktop-1 \
  tailscale up --hostname=codex-desktop --ssh
```

Open the authentication URL printed by Tailscale and attach the node to the
intended tailnet. Then hand lifecycle management to systemd:

```bash
sudo systemctl enable --now codex-desktop.service
```

Tailscale SSH access is controlled by the tailnet policy. The container's
administrative login is:

```bash
tailscale ssh root@codex-desktop
```

Replace `codex-desktop` with your configured `TAILSCALE_HOSTNAME` when changed.
For file-backed auth-key enrollment, multiple-account selection, commands used
inside the container, and identity recovery, see
[Tailscale operations](docs/tailscale.md).

## Register Chrome Remote Desktop on Ubuntu

Apple silicon does not install Chrome Remote Desktop; use tailnet noVNC instead.
On Ubuntu, skip this section when `CODEX_DESKTOP_CRD_ENABLED=0`. The local
Xvfb/Xfce session is already running and available through authenticated noVNC.
When CRD is enabled, open a trusted browser signed into the intended Google account and visit
<https://remotedesktop.google.com/headless> and select the Debian/Linux setup.
Use the generated command promptly because its OAuth code is short-lived.

Connect through Tailscale SSH and paste the wizard command unchanged. The image
installs a compatibility wrapper at Google's exact path:

```bash
DISPLAY= /opt/google/chrome-remote-desktop/start-host \
  --code='<short-lived-code>' \
  --redirect-url='https://remotedesktop.google.com/_/oauthredirect' \
  --name="$(hostname)"
```

Enter the PIN only at the interactive prompt. Never place the PIN or OAuth code
in a command file, image, repository, or durable shell history. If a code is
exposed, generate a new one before continuing.

The wrapper runs registration as the persistent desktop user `codex`, accepts
the exact command produced by the Google wizard, and tolerates the expected
systemd error from CRD's upstream helper. Supervisor starts the registered host
automatically after its persistent configuration appears.

## Open authenticated noVNC

noVNC displays the persistent Xfce session. It is the primary graphical path on
Apple silicon and an alternative to Chrome Remote Desktop on Ubuntu. The
installer creates independent one-click and Basic Auth credentials and stores
them in persistent root-only state. Retrieve the connection details only in a
trusted interactive root shell:

```bash
remote-browser-credentials
```

Use the displayed one-click HTTPS URL from an allowed tailnet device. The
gateway exchanges its token for a secure cookie, removes the secret from the
address bar, and opens the scaled noVNC session with auto-connect enabled.
Basic Auth is the fallback. The raw noVNC and VNC ports are private container
backends and must not be opened directly. See
[Remote browser MCP](docs/remote-browser-mcp.md).

## Connect Codex to persistent Chrome

Connect to the Xfce desktop through noVNC on Apple silicon or noVNC-only Ubuntu,
or through either remote-desktop option when Ubuntu CRD is enabled. Codex and
Chrome should both open automatically. Complete this one-time setup in the
persistent desktop:

1. Sign in to Codex.
2. Open **Settings > Computer Use**, select Google Chrome, and follow the prompt
   to install the required plugin.
3. Select **Install** beside Chrome and install the official ChatGPT browser
   extension from the store page opened by Codex.
4. Return to Codex and confirm Chrome shows **Manage**.
5. Grant only the website permissions required by scheduled tasks.
6. Start a test chat and use `@Chrome` for one real browser action.

Install the extension in the Chrome window started by this container. Its
profile is `/home/codex/.config/google-chrome`, so the extension, permissions,
and signed-in site state survive container recreation. The matching Codex
plugin and native-host state persist under `/home/codex`.

For remote MCP, separately install the Playwright extension into this same
Chrome profile. Obtain its token through the extension UI, then enter it only at
the hidden prompt inside the container:

```bash
remote-browser-extension-token
```

This starts the independently supervised stock Playwright MCP service. It does
not grant or bypass Codex `@Chrome` approvals.

If a task needs console, network, DOM, or performance inspection, open
**Settings > Browser** and enable **full CDP access**. Full CDP is elevated-risk
and Codex asks for explicit approval before using it on a site. Ordinary
extension control is a better fit for unattended work when full CDP is not
necessary. See the official OpenAI documentation for the
[browser extension](https://learn.chatgpt.com/docs/chrome-extension) and
[browser developer mode](https://learn.chatgpt.com/docs/browser).

## Scheduled tasks

Scheduled local tasks require the host to remain powered on and the Codex
desktop app to remain running. The managed Xfce session keeps Codex and Chrome
available without an attached viewer. Test a task manually with `@Chrome`
before scheduling it, then verify one unattended run.

Full CDP approvals or new site-permission prompts can pause an unattended run.
Prefer an explicit site allowlist, avoid granting all-sites access, and reserve
full CDP for tasks that actually need browser internals.

## Verify

On Ubuntu:

```bash
sudo /opt/services/codex-desktop/scripts/verify-deployment.sh
```

Use `--allow-incomplete` only before the user has provisioned the Playwright
extension token or, when enabled, completed CRD registration. The verifier
reads `CODEX_DESKTOP_CRD_ENABLED`, verifies that the image label and installed
packages match it, and does not query CRD in a noVNC-only image.

On Apple silicon:

```bash
~/.local/share/codex-desktop/source/scripts/verify-macos.sh
```

Finally, connect through authenticated noVNC, or Chrome Remote Desktop when it
is enabled on Ubuntu, and confirm
that Xfce, Codex, and Chrome open. Confirm the extension reports connected in Codex, run one
`@Chrome` action, restart the service, and repeat the action without reinstalling
the extension or signing back into the test site. Initialize MCP through its
bearer endpoint, list tools, take a harmless snapshot, and delete the session.
Verify the browser action is visible in noVNC and survives a restart without
rotating gateway credentials or reprovisioning either extension.

## Upgrades and rollback

Build every package update as a new immutable image tag. Change only
`IMAGE_REF` in `/etc/codex-desktop/deploy.env`, then restart this service:

```bash
sudo systemctl restart codex-desktop.service
```

Verify the package versions, Tailscale identity, Serve route, gateway and MCP
processes, and a real desktop connection; also verify CRD status when enabled
on Ubuntu.
Roll back by restoring the prior `IMAGE_REF` and restarting the same service.
Never remove persistent state or rotate gateway credentials during an ordinary
upgrade or rollback.

Back up the Chrome profile only while the service is stopped so Chrome has
closed it cleanly. Treat the backup as credential-bearing data and encrypt it
before moving it off the host.

## Platform boundary

This is a Linux workstation container, not a stateless web service. It requires
device and capability access that ordinary serverless container platforms do
not provide. A Linux VM is the appropriate host when moving it to a cloud.

Supported means the guided installer and acceptance verifier have explicit
platform logic. Current supported hosts are only Ubuntu 24.04 AMD64 and Apple
silicon macOS. A graphical environment on Ubuntu is irrelevant because the
desktop is container-managed; Linux ARM64 remains unsupported even though the
native ARM64 macOS image exists.

Third-party packages remain subject to their respective vendors' terms. This
repository does not include authentication state or redistribute package
binaries; the build downloads verified packages from their official sources.
This is an independent deployment project and is not affiliated with or
endorsed by OpenAI, Google, or Tailscale.
