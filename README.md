# Codex Desktop container

[![CI](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml/badge.svg)](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml)

A persistent Linux desktop container for the official Codex desktop app, with
Xfce, an always-on Google Chrome, Tailscale, Tailscale SSH, and noVNC. Ubuntu
AMD64 also includes Chrome Remote Desktop. Apple silicon uses a fully native
ARM64 image and noVNC as its graphical access path. Codex and Chrome run as the
same unprivileged desktop user so the official browser extension can connect
them.

The image uses the official unified Linux package named `chatgpt`; the desktop
application it launches is Codex. Package versions, download URLs, base images,
and checksums are pinned in the `Dockerfile` for reproducible builds.

## Documentation

- [Complete installation and upgrade guide](docs/installation.md)
- [Tailscale enrollment, access, and in-container usage](docs/tailscale.md)
- [Agent deployment question and execution playbook](docs/agent-deployment.md)
- [Security boundaries](SECURITY.md)

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
Tailscale through a hidden auth-key prompt or browser URL, optionally configures
noVNC, starts the container, and prints the remaining platform-specific Codex
steps.

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
| `/var/lib/codex-desktop/home` | `/home/codex` | Codex login and settings, Ubuntu CRD registration, Xfce settings, projects, and the Chrome profile under `.config/google-chrome` |
| `/var/lib/codex-desktop/tailscale` | `/var/lib/tailscale` | Tailscale node identity and preferences |
| `/var/lib/codex-desktop/machine` | `/var/lib/codex-desktop-persistent` | Stable DBus machine identity |

Those host paths apply to Ubuntu. The Apple silicon Compose override uses the
named volumes `codex-desktop-home`, `codex-desktop-tailscale`, and
`codex-desktop-machine` for the same container targets.

No ports are published. Tailscale and, on Ubuntu, Chrome Remote Desktop
establish outbound connections. No Docker socket is mounted, and no existing
Codex profile is copied into the image.

Tailscale runs entirely in userspace, so the container needs no TUN device or
network-administration capabilities. The noVNC web service and its private
x11vnc backend bind only to container loopback on TCP 6080 and 5900. Tailscale's
userspace netstack forwards tailnet TCP 6080 to `127.0.0.1:6080`. The raw VNC
backend uses `127.0.0.2:5900`, rather than the netstack's same-port localhost
target. Neither port is published by Docker.

Codex and Chrome are started by Xfce, share the managed display and session bus,
and use single-instance restart wrappers for unattended work.
The container registers Chrome as the default HTTP/HTTPS browser and Codex as
the `codex:` callback handler so ChatGPT sign-in can complete inside the same
persistent desktop session.
Browser control uses the official ChatGPT browser extension and Codex's
approval model; this image does not open a raw Chrome debugging port.

## Requirements

- Ubuntu 24.04 AMD64, or Apple silicon macOS
- Docker Engine with Compose on Linux, or Docker Desktop on macOS
- AppArmor tools on an AppArmor-enabled Linux host
- A Tailscale account and policy that permits Tailscale SSH
- A tailnet ACL permitting intended viewers to reach this node on TCP 6080
- On Ubuntu only, a Google account authorized for Chrome Remote Desktop
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
  --tag codex-desktop:chatgpt-26.820.60940-crd-152.0.7977.9-ts1.102.2-10 \
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

The installer asks for the host configuration, Tailscale enrollment method,
and optional noVNC setup. A one-time Tailscale auth key is accepted only through
a hidden terminal prompt and is removed from container tmpfs immediately after
use. The alternative browser flow prints a login URL for the user to open and
approve in the intended account and tailnet.

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
limits. Do not put Tailscale keys, CRD codes, PINs, or other credentials in
that file.

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
On Ubuntu, open a trusted browser signed into the intended Google account and visit
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

## Configure noVNC

noVNC displays the persistent Xfce session. It is the primary graphical path on
Apple silicon and an alternative to Chrome Remote Desktop on Ubuntu. After
Tailscale is configured, create the persistent VNC password from a trusted
interactive shell:

```bash
sudo docker exec -it codex-desktop-desktop-1 \
  /usr/local/bin/configure-codex-novnc
```

Enter and verify a dedicated password when x11vnc prompts. The password file is
stored at `/home/codex/.vnc/passwd` inside the persistent home mount. Do not use
a website, Google, Codex, or system-login password. The classic VNC protocol
uses only the first eight password characters, so use a unique random password
and treat the tailnet identity plus restrictive ACL as the primary boundary.

From an authenticated device on the permitted tailnet, open:

```text
http://codex-desktop:6080/vnc.html?autoconnect=1&resize=scale
```

Replace `codex-desktop` with `TAILSCALE_HOSTNAME` when customized, then enter
the VNC password. Tailscale encrypts this connection, while x11vnc provides the
application-level password check. Do not expose this HTTP service through a
public proxy or Docker port mapping.

## Connect Codex to persistent Chrome

Connect to the Xfce desktop through noVNC on Apple silicon or through either
remote-desktop option on Ubuntu. Codex and Chrome should both open
automatically. Complete this one-time setup in the persistent desktop:

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
systemctl status codex-desktop.service --no-pager
docker inspect codex-desktop-desktop-1 \
  --format '{{.State.Health.Status}}'
docker exec codex-desktop-desktop-1 \
  dpkg-query -W chatgpt chrome-remote-desktop google-chrome-stable
docker exec codex-desktop-desktop-1 tailscale status
docker exec codex-desktop-desktop-1 tailscale ip -4
docker exec codex-desktop-desktop-1 \
  supervisorctl status desktop-session x11vnc novnc
docker exec codex-desktop-desktop-1 \
  /usr/local/sbin/codex-desktop-healthcheck
docker inspect codex-desktop-desktop-1 \
  --format '{{json .NetworkSettings.Ports}}'
docker exec -u codex codex-desktop-desktop-1 \
  /opt/google/chrome-remote-desktop/chrome-remote-desktop --get-status
```

On Apple silicon:

```bash
~/.local/share/codex-desktop/source/scripts/verify-macos.sh
```

Finally, connect through noVNC, or Chrome Remote Desktop on Ubuntu, and confirm
that Xfce, Codex, and Chrome open. Confirm the extension reports connected in Codex, run one
`@Chrome` action, restart the service, and repeat the action without reinstalling
the extension or signing back into the test site. Open the noVNC URL before and
after that restart and verify that it shows the same Chrome tabs and Xfce
session.

## Upgrades and rollback

Build every package update as a new immutable image tag. Change only
`IMAGE_REF` in `/etc/codex-desktop/deploy.env`, then restart this service:

```bash
sudo systemctl restart codex-desktop.service
```

Verify the package versions, Tailscale identity, and a real desktop connection;
also verify CRD status on Ubuntu. Roll back by restoring the prior `IMAGE_REF`
and restarting the same service. Never remove persistent state during an
upgrade or rollback.

Back up the Chrome profile only while the service is stopped so Chrome has
closed it cleanly. Treat the backup as credential-bearing data and encrypt it
before moving it off the host.

## Platform boundary

This is a Linux workstation container, not a stateless web service. It requires
device and capability access that ordinary serverless container platforms do
not provide. A Linux VM is the appropriate host when moving it to a cloud.

Third-party packages remain subject to their respective vendors' terms. This
repository does not include authentication state or redistribute package
binaries; the build downloads verified packages from their official sources.
This is an independent deployment project and is not affiliated with or
endorsed by OpenAI, Google, or Tailscale.
