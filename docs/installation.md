# Installation

This is a Tailscale-only deployment. It publishes no Docker host ports and
does not add a LAN or public-IP access mode. Tailscale SSH, Chrome Remote
Desktop, and tailnet-only noVNC are the supported access paths.

## Requirements

- Ubuntu 24.04 AMD64 with root/sudo access, or Apple silicon macOS with an
  administrator account for optional Docker Desktop installation
- Docker Engine and Docker Compose v2 on Linux, or Docker Desktop on macOS
- Git and tar; Linux also requires jq and `apparmor_parser`
- At least 8 GiB host memory recommended
- A Tailscale account with permission to add the device
- On Ubuntu only, a Google account authorized for Chrome Remote Desktop
- An interactive trusted terminal for secret and PIN entry

The one-line bootstrap asks before installing missing prerequisites. On Linux
it can configure Docker's official apt repository. On macOS it can install the
official Apple silicon Docker Desktop application, then waits for the user to
complete Docker's first-run and licensing screens. Neither path alters the host
firewall or publishes network ports.

Tailscale runs inside the container with `--tun=userspace-networking`. It does
not require `/dev/net/tun`, `NET_ADMIN`, or `NET_RAW` on either host.

## One-line bootstrap

Run from an interactive terminal:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/eladrave/codex-desktop-container/main/bootstrap.sh | sh
```

The bootstrap detects the supported platform, prepares prerequisites only
after confirmation, clones the selected repository revision, displays its full
commit SHA, and invokes `scripts/install.sh`. All installer prompts read from
the controlling terminal, not from the curl pipe.

## Guided installation

Clone the repository on the target host and run:

```bash
git clone https://github.com/eladrave/codex-desktop-container.git
cd codex-desktop-container
./scripts/install.sh
```

On Ubuntu, run `sudo ./scripts/install.sh`. On Apple silicon, run the same file
as the normal logged-in user. It dispatches internally to the platform-specific
lifecycle implementation while preserving the same questions and security
contract.

The repository must be clean. This ensures the deployed source archive exactly
matches the commit reported by Git.

The installer asks, in order, for:

1. Container hostname.
2. Tailscale/MagicDNS hostname.
3. Expected Tailscale account or tailnet label for operator confirmation.
4. Timezone.
5. Permitted desktop sizes.
6. Container memory limit.
7. Container memory reservation.
8. CPU limit.
9. Immutable image reference.
10. Whether to build the image from the checked-out commit.
11. Upgrade and full-state-backup confirmation when existing state is found.
12. Final confirmation before host changes.
13. Tailscale enrollment method when no persistent enrollment exists.
14. The one-time Tailscale auth key through a hidden prompt, or completion of
    the browser login URL flow.
15. Confirmation that the resulting identity belongs to the intended tailnet.
16. Whether to configure the persistent noVNC password.

It then prints the ordered user-only steps for Codex sign-in, the Chrome
extension, and optional full CDP access. Ubuntu also prints the Chrome Remote
Desktop registration steps.

The installer:

- builds or verifies the immutable image;
- stops only an existing Codex Desktop service and backs up its source,
  environment, systemd unit, and complete persistent state;
- installs the committed source under `/opt/services/codex-desktop`;
- writes `/etc/codex-desktop/deploy.env` as `root:root` mode `0600`;
- creates the persistent state directories with their required ownership;
- validates Compose and loads the executable-specific AppArmor profile;
- enables and starts `codex-desktop.service`;
- waits for Docker health;
- preserves an existing working Tailscale identity;
- performs a new Tailscale enrollment only when needed;
- removes the temporary auth-key file immediately after enrollment.

On Ubuntu it installs the committed source under `/opt/services/codex-desktop`
and manages `codex-desktop.service`. On Apple silicon it installs under
`~/.local/share/codex-desktop`, uses named Docker volumes for the three
persistent state stores, and installs a per-user launch agent that starts Docker
Desktop and the Compose project at login.

If noVNC or Ubuntu CRD setup is intentionally deferred, use the platform
verifier with `--allow-incomplete` for base checks. The normal Ubuntu verifier
requires both CRD and noVNC; the macOS verifier requires noVNC.

## Tailscale enrollment

The installer supports both enrollment methods below. See
[Tailscale operations](tailscale.md) for complete usage and recovery guidance.

### One-time auth key

Generate the key from the intended tailnet. A key belongs to the account and
tailnet that created it, which avoids ambiguity when you use multiple Tailscale
accounts. Prefer a one-time, non-ephemeral key. Use a tag only when the tailnet
policy intentionally grants that tag the required SSH and noVNC access, and use
pre-approval only when device approval is enabled.

The installer reads the key from a hidden terminal prompt, sends it through
standard input, writes it only to container tmpfs at
`/run/secrets/tailscale-auth-key`, runs:

```bash
docker exec -i codex-desktop-desktop-1 \
  tailscale up \
  --auth-key=file:/run/secrets/tailscale-auth-key \
  --hostname=codex-desktop \
  --ssh
```

It then deletes the temporary file. The key is never written to
`deploy.env`, the repository, an image layer, or command arguments.

### Browser login URL

The installer runs:

```bash
docker exec -i codex-desktop-desktop-1 \
  tailscale up --hostname=codex-desktop --ssh
```

The installer polls Tailscale's structured daemon status and prints the login
URL directly to the trusted terminal. Open that URL in a trusted browser, sign
in with the intended account, select the correct tailnet, and approve the
device. When multiple accounts share the browser, use a private browser window
so an old session does not silently select the wrong account.

The command returns after approval. The resulting identity persists at
`/var/lib/codex-desktop/tailscale` and is reused after container recreation and
host reboot.

## Configure noVNC

If skipped during installation, configure it later from a trusted host shell:

```bash
sudo docker exec -it codex-desktop-desktop-1 \
  /usr/local/bin/configure-codex-novnc
```

The password file persists at `/home/codex/.vnc/passwd`. Classic VNC uses only
the first eight password characters, so use a unique random value and rely on
tailnet identity and ACLs as the primary boundary.

After the desktop session is running, open from an allowed tailnet device:

```text
http://codex-desktop:6080/vnc.html?autoconnect=1&resize=scale
```

Replace `codex-desktop` with the configured Tailscale hostname. Tailscale's
userspace netstack forwards tailnet TCP 6080 to noVNC on container loopback.
Raw VNC uses the separate loopback address `127.0.0.2:5900`, outside the
netstack's same-port localhost forwarding target.

## Register Chrome Remote Desktop on Ubuntu

Skip this section on Apple silicon. Its native ARM64 image does not install
Chrome Remote Desktop and uses noVNC as the graphical access path.

This step requires a short-lived Google authorization code and a PIN chosen by
the user. Neither value belongs in chat, Git, logs, or a saved command.

1. Open <https://remotedesktop.google.com/headless> in the intended Google
   account.
2. Select the Debian/Linux instructions and generate the registration command.
3. Connect to the container:

   ```bash
   tailscale ssh root@codex-desktop
   ```

4. Run `set +o history`, paste and run the generated command directly, then run
   `set -o history` after it finishes. The short-lived code is necessarily
   present in the registration process arguments, but must not be retained in
   shell history, chat, or logs.
5. Enter the PIN only at the hidden prompt.

The image's compatibility wrapper runs registration as user `codex` and saves
the host configuration under the persistent home.

Verify without displaying the host configuration contents:

```bash
supervisorctl status desktop-session
setpriv --reuid=10001 --regid=10001 --init-groups \
  env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
  /opt/google/chrome-remote-desktop/chrome-remote-desktop --get-status
```

Expected status is `STARTED`.

## Connect Codex and Chrome

Connect through noVNC on Apple silicon, or through Chrome Remote Desktop or
noVNC on Ubuntu. Codex and Chrome start in the same Xfce session and
automatically recover from process exits.

1. Sign in to Codex.
2. Open **Settings > Computer Use**.
3. Select Chrome and install the required plugin.
4. Install the official ChatGPT extension in the Chrome profile opened by the
   container.
5. Return to Codex and confirm Chrome shows **Manage**.
6. Grant only the site permissions needed by scheduled tasks.
7. Test a real `@Chrome` task.
8. Enable full CDP under **Settings > Browser** only when a task needs browser
   internals. Full CDP is elevated-risk and may require approval during use.

The Chrome profile persists under
`/var/lib/codex-desktop/home/.config/google-chrome`.

## Verification

Run on the host:

```bash
sudo /opt/services/codex-desktop/scripts/verify-deployment.sh
```

On Apple silicon, run:

```bash
~/.local/share/codex-desktop/source/scripts/verify-macos.sh
```

Then perform the interactive acceptance checks:

1. Connect through noVNC. On Ubuntu, also connect through Chrome Remote Desktop
   and confirm both show the same desktop and Chrome tabs.
2. Run a real `@Chrome` action from Codex.
3. Restart only `codex-desktop.service` on Ubuntu or the Compose project on
   macOS.
4. Confirm Tailscale identity, Codex sign-in, Chrome extension,
   cookies, and noVNC password all survive.
5. On Ubuntu, confirm CRD registration also survives.
6. Trigger one scheduled task without leaving a remote viewer attached.

## Upgrade and rollback

Rerunning the installer requires an explicit upgrade confirmation, stops only
this service, and creates a consistent root-only backup under
`/var/backups/codex-desktop`. The backup includes deployed source, environment,
systemd unit, and the complete persistent state tree. The previous source is
also retained beside `/opt/services/codex-desktop`.

Every behavior or package update uses a commit-derived immutable image tag. A
second run at the same commit reuses only an image whose revision label matches;
a tag belonging to any other revision is rejected. The installer also records
the source Git revision in the image label and deployed `REVISION` file. This
ensures that the old environment still resolves to the old image ID.

On activation failure, the installer attempts to restore the previous source,
environment, and unit and restart the prior service. For a manual rollback:

1. Stop `codex-desktop.service`.
2. Restore the prior source directory or `service.tar`.
3. Restore both `deploy.env` and `codex-desktop.service` from the same backup.
4. Confirm the prior immutable image tag resolves to its original image ID.
5. Reload systemd and start only `codex-desktop.service`.
6. Run the complete verification and interactive acceptance sequence.

Restore `persistent-state.tar` only for state corruption or a failed state
migration, not for an ordinary image rollback. State restoration replaces
credential-bearing browser, Codex, CRD, and Tailscale data and therefore needs
separate explicit approval and a preserved rollback copy.

On macOS, upgrades create stopped-state archives under
`~/.local/share/codex-desktop/backups`. The archives contain all three named
volumes and must be treated as credential-bearing data. Image rollback keeps
the named volumes unchanged. Restoring volume archives is a separate,
destructive recovery operation and is not performed automatically.

## Apple silicon operating boundary

Apple silicon builds a native ARM64 Ubuntu image with the official ARM64 Codex
and Chrome packages, native Tailscale, Xvfb/Xfce, and noVNC. It does not use
Rosetta. Chrome Remote Desktop is omitted because Google does not publish the
pinned Linux CRD release for ARM64.

The installer verifies the Docker memory allocation, package architectures,
image architecture, Tailscale ELF architecture, and absence of CRD. The
operator must still complete real Codex, Chrome, noVNC, restart-persistence,
and scheduled-task acceptance.

The installed launch agent starts Docker Desktop and the Compose project when
the user logs in. It cannot run while the Mac is powered off, logged out, or
asleep. Configure macOS power settings appropriate for the intended scheduled
work and keep the user session logged in.
