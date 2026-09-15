# Codex Desktop container

[![CI](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml/badge.svg)](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml)

A persistent Linux desktop container for the official Codex desktop app, with
Xfce, Chrome Remote Desktop, an always-on Google Chrome, Tailscale, and
Tailscale SSH. Chrome Remote Desktop and a password-protected noVNC page expose
the same graphical session. Codex and Chrome run as the same unprivileged
desktop user so the official browser extension can connect them.

The image uses the official unified Linux package named `chatgpt`; the desktop
application it launches is Codex. Package versions, download URLs, base images,
and checksums are pinned in the `Dockerfile` for reproducible builds.

## Documentation

- [Complete installation and upgrade guide](docs/installation.md)
- [Tailscale enrollment, access, and in-container usage](docs/tailscale.md)
- [Agent deployment question and execution playbook](docs/agent-deployment.md)
- [Security boundaries](SECURITY.md)

## What persists

The Compose configuration keeps the state that must survive container
recreation in these host directories:

| Host path | Container path | Contents |
| --- | --- | --- |
| `/var/lib/codex-desktop/home` | `/home/codex` | Codex login and settings, CRD registration, Xfce settings, projects, and the Chrome profile under `.config/google-chrome` |
| `/var/lib/codex-desktop/tailscale` | `/var/lib/tailscale` | Tailscale node identity and preferences |
| `/var/lib/codex-desktop/machine` | `/var/lib/codex-desktop-persistent` | Stable DBus machine identity |

No ports are published. Tailscale and Chrome Remote Desktop establish outbound
connections. No Docker socket is mounted, and no existing Codex profile is
copied into the image.

The noVNC web service binds only to the container's Tailscale IPv4 address on
TCP 6080. Its private x11vnc backend binds only to container loopback on TCP
5900. Neither port is published by Docker.

Codex and Chrome are started by Xfce, inherit the Chrome Remote Desktop display
and session bus, and use single-instance restart wrappers for unattended work.
Browser control uses the official ChatGPT browser extension and Codex's
approval model; this image does not open a raw Chrome debugging port.

## Requirements

- Ubuntu 24.04 or another compatible AMD64 Linux Docker host
- Docker Engine with the Compose plugin
- AppArmor tools on an AppArmor-enabled host
- `/dev/net/tun`
- A Tailscale account and policy that permits Tailscale SSH
- A tailnet ACL permitting intended viewers to reach this node on TCP 6080
- A Google account authorized for Chrome Remote Desktop
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

## Build

```bash
git clone https://github.com/eladrave/codex-desktop-container.git
cd codex-desktop-container
revision="$(git rev-parse HEAD)"
docker build \
  --build-arg "VCS_REF=${revision}" \
  --tag codex-desktop:chatgpt-26.820.60940-crd-152.0.7977.9-ts1.102.2-9 \
  .
```

Every downloaded Debian package is checked against its pinned SHA-256 digest.
If an upstream version changes, update the version, versioned URL, and checksum
together and rebuild as a new immutable image tag.

## Guided installation

On an Ubuntu 24.04 AMD64 Docker host, clone the repository and run:

```bash
sudo ./scripts/install.sh
```

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

## Register Chrome Remote Desktop

On a trusted browser signed into the intended Google account, visit
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

noVNC is an alternative view of the same persistent Xfce session used by
Chrome Remote Desktop. After Tailscale and Chrome Remote Desktop are configured,
create the persistent VNC password from a trusted interactive shell:

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

After Chrome Remote Desktop is registered, connect to the Xfce desktop. Codex
and Chrome should both open automatically. Complete this one-time setup in the
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

If a task needs console, network, DOM, or performance inspection, open
**Settings > Browser** and enable **full CDP access**. Full CDP is elevated-risk
and Codex asks for explicit approval before using it on a site. Ordinary
extension control is a better fit for unattended work when full CDP is not
necessary. See the official OpenAI documentation for the
[browser extension](https://learn.chatgpt.com/docs/chrome-extension) and
[browser developer mode](https://learn.chatgpt.com/docs/browser).

## Scheduled tasks

Scheduled local tasks require the host to remain powered on and the Codex
desktop app to remain running. This container keeps the registered CRD session,
Codex, and Chrome available without an attached CRD viewer. Test a task
manually with `@Chrome` before scheduling it, then verify one unattended run.

Full CDP approvals or new site-permission prompts can pause an unattended run.
Prefer an explicit site allowlist, avoid granting all-sites access, and reserve
full CDP for tasks that actually need browser internals.

## Verify

```bash
systemctl status codex-desktop.service --no-pager
docker inspect codex-desktop-desktop-1 \
  --format '{{.State.Health.Status}}'
docker exec codex-desktop-desktop-1 \
  dpkg-query -W chatgpt chrome-remote-desktop google-chrome-stable
docker exec codex-desktop-desktop-1 tailscale status
docker exec codex-desktop-desktop-1 tailscale ip -4
docker exec codex-desktop-desktop-1 \
  supervisorctl status chrome-remote-desktop x11vnc novnc
docker exec codex-desktop-desktop-1 \
  /usr/local/sbin/codex-desktop-healthcheck
docker inspect codex-desktop-desktop-1 \
  --format '{{json .NetworkSettings.Ports}}'
docker exec -u codex codex-desktop-desktop-1 \
  /opt/google/chrome-remote-desktop/chrome-remote-desktop --get-status
```

Finally, connect with Chrome Remote Desktop and confirm that Xfce, Codex, and
Chrome open. Confirm the extension reports connected in Codex, run one
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

Verify the package versions, Tailscale identity, CRD status, and a real desktop
connection. Roll back by restoring the prior `IMAGE_REF` and restarting the
same service. Never remove the persistent directories during an upgrade or
rollback.

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
