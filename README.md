# Codex Desktop container

[![CI](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml/badge.svg)](https://github.com/eladrave/codex-desktop-container/actions/workflows/ci.yml)

A persistent Linux desktop container for the official Codex desktop app, with
Xfce, Chrome Remote Desktop, Google Chrome, Tailscale, and Tailscale SSH.

The image uses the official unified Linux package named `chatgpt`; the desktop
application it launches is Codex. Package versions, download URLs, base images,
and checksums are pinned in the `Dockerfile` for reproducible builds.

## What persists

The Compose configuration keeps the state that must survive container
recreation in these host directories:

| Host path | Container path | Contents |
| --- | --- | --- |
| `/var/lib/codex-desktop/home` | `/home/codex` | Codex login and settings, CRD registration, Xfce settings, browser data, and projects |
| `/var/lib/codex-desktop/tailscale` | `/var/lib/tailscale` | Tailscale node identity and preferences |
| `/var/lib/codex-desktop/machine` | `/var/lib/codex-desktop-persistent` | Stable DBus machine identity |

No ports are published. Tailscale and Chrome Remote Desktop establish outbound
connections. No Docker socket is mounted, and no existing Codex profile is
copied into the image.

## Requirements

- Ubuntu 24.04 or another compatible AMD64 Linux Docker host
- Docker Engine with the Compose plugin
- AppArmor tools on an AppArmor-enabled host
- `/dev/net/tun`
- A Tailscale account and policy that permits Tailscale SSH
- A Google account authorized for Chrome Remote Desktop

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
docker build \
  --tag codex-desktop:chatgpt-26.820.60940-crd-152.0.7977.9-ts1.102.2-7 \
  .
```

Every downloaded Debian package is checked against its pinned SHA-256 digest.
If an upstream version changes, update the version, versioned URL, and checksum
together and rebuild as a new immutable image tag.

## Install on the host

The supplied systemd unit expects the deployment under
`/opt/services/codex-desktop` and its environment file under
`/etc/codex-desktop`:

```bash
sudo install -d -m 0755 /opt/services/codex-desktop
git archive --format=tar HEAD | sudo tar -x -C /opt/services/codex-desktop
sudo install -d -m 0755 /etc/codex-desktop
sudo install -m 0600 deploy.env.example /etc/codex-desktop/deploy.env
sudo install -m 0644 codex-desktop.service \
  /etc/systemd/system/codex-desktop.service
sudo systemctl daemon-reload
```

Edit `/etc/codex-desktop/deploy.env` if you want a different timezone,
container hostname, Tailscale hostname, or desktop sizes. Do not put Tailscale
keys, CRD codes, PINs, or other credentials in that file.

## First start and Tailscale enrollment

Create the persistent directories, start the Compose project, and enroll the
node interactively:

```bash
sudo install -d -o 10001 -g 10001 -m 0700 /var/lib/codex-desktop/home
sudo install -d -o 0 -g 0 -m 0700 \
  /var/lib/codex-desktop/tailscale \
  /var/lib/codex-desktop/machine
sudo docker compose \
  --project-name codex-desktop \
  --env-file /etc/codex-desktop/deploy.env \
  -f /opt/services/codex-desktop/compose.yaml \
  up -d
sudo docker exec -it codex-desktop-desktop-1 tailscale up --ssh
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

## Verify

```bash
systemctl status codex-desktop.service --no-pager
docker inspect codex-desktop-desktop-1 \
  --format '{{.State.Health.Status}}'
docker exec codex-desktop-desktop-1 \
  dpkg-query -W chatgpt chrome-remote-desktop google-chrome-stable
docker exec codex-desktop-desktop-1 tailscale status
docker exec codex-desktop-desktop-1 tailscale ip -4
docker exec -u codex codex-desktop-desktop-1 \
  /opt/google/chrome-remote-desktop/chrome-remote-desktop --get-status
```

Finally, connect with Chrome Remote Desktop and confirm that Xfce opens and the
Codex app starts. Complete Codex sign-in interactively inside that desktop.

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

## Platform boundary

This is a Linux workstation container, not a stateless web service. It requires
device and capability access that ordinary serverless container platforms do
not provide. A Linux VM is the appropriate host when moving it to a cloud.

Third-party packages remain subject to their respective vendors' terms. This
repository does not include authentication state or redistribute package
binaries; the build downloads verified packages from their official sources.
This is an independent deployment project and is not affiliated with or
endorsed by OpenAI, Google, or Tailscale.
