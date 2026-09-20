# Installation

This is a Tailscale-only deployment. It publishes no Docker host ports and
does not add a LAN or public-IP access mode. Tailscale SSH, Tailscale Serve
HTTPS, authenticated noVNC, remote Playwright MCP, and optional Chrome Remote
Desktop on Ubuntu are the supported access paths. Ubuntu does not require a
host graphical environment: noVNC-only mode runs Xvfb/Xfce in the container.

## Requirements

- Ubuntu 24.04 AMD64 with root/sudo access, or Apple silicon macOS with an
  administrator account for optional Docker Desktop installation
- Docker Engine and Docker Compose v2 on Linux, or Docker Desktop on macOS
- Git and tar; Linux also requires jq and `apparmor_parser`
- At least 8 GiB host memory recommended
- A Tailscale account with permission to add the device
- On Ubuntu only when CRD is enabled, a Google account authorized for Chrome
  Remote Desktop
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
5. Whether to enable Chrome Remote Desktop on Ubuntu. The default is enabled.
6. Permitted desktop sizes.
7. Container memory limit.
8. Container memory reservation.
9. CPU limit.
10. Immutable image reference.
11. Whether to build the image from the checked-out commit.
12. Upgrade and full-state-backup confirmation when existing state is found.
13. Final confirmation before host changes.
14. Tailscale enrollment method when no persistent enrollment exists.
15. The one-time Tailscale auth key through a hidden prompt, or completion of
    the browser login URL flow.
16. Confirmation that the resulting identity belongs to the intended tailnet.
17. Confirmation that Tailscale Serve exposes only the authenticated HTTPS
    gateway on TCP 443.

It then prints the ordered user-only steps for Codex sign-in, the official
ChatGPT extension, Playwright extension token provisioning, remote MCP
configuration, and optional Codex full CDP access. Ubuntu prints Chrome Remote
Desktop registration steps only when CRD is enabled.

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
- removes the temporary auth-key file immediately after enrollment;
- preserves or creates independent root-only gateway credentials in the
  persistent machine-state volume;
- configures Tailscale Serve HTTPS 443 to the authenticated gateway without
  publishing a Docker port.

On Ubuntu it installs the committed source under `/opt/services/codex-desktop`
and manages `codex-desktop.service`. On Apple silicon it installs under
`~/.local/share/codex-desktop`, uses named Docker volumes for the three
persistent state stores, and installs a per-user launch agent that starts Docker
Desktop and the Compose project at login.

If Playwright extension provisioning or enabled Ubuntu CRD setup is
intentionally deferred, use the platform verifier with `--allow-incomplete`
for base checks. The normal verifier requires the Playwright extension token
and running MCP; the normal Ubuntu verifier requires CRD only when configured.

## Ubuntu noVNC-only mode

Set `CODEX_DESKTOP_CRD_ENABLED=0` in `/etc/codex-desktop/deploy.env`, or answer
no to the guided installer's CRD prompt. The default is `1`, preserving the
existing CRD-enabled behavior. The installer builds or accepts only an image
whose `io.google.chrome-remote-desktop.enabled` label matches this setting; a
noVNC-only image is built with `INSTALL_CRD=0` and contains no CRD package.

With CRD disabled, the platform-selecting desktop wrapper immediately starts
Xvfb and Xfce inside the container. x11vnc and noVNC attach to that display, so
the Docker host itself needs no window system or logged-in graphical user. The
same persistent Chrome, Codex, and Playwright MCP workflow remains available.
Tailscale Serve is still the only permanent ingress and no Docker ports are
published.

## Tailscale enrollment

The installer supports both enrollment methods below. See
[Tailscale operations](tailscale.md) for complete usage and recovery guidance.

### One-time auth key

Generate the key from the intended tailnet. A key belongs to the account and
tailnet that created it, which avoids ambiguity when you use multiple Tailscale
accounts. Prefer a one-time, non-ephemeral key. Use a tag only when the tailnet
policy intentionally grants that tag the required SSH and HTTPS gateway access,
and use
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

## Open authenticated noVNC

The gateway creates independent one-click and Basic Auth credentials during
first start. Retrieve them only from a trusted interactive root shell:

```bash
remote-browser-credentials
```

Use the displayed one-click HTTPS URL from an allowed tailnet device. The
gateway exchanges the query token for a secure cookie and redirects to a clean
`/login/` URL. Use the displayed Basic Auth credentials only as the fallback.

x11vnc and websockify are private backends at `127.0.0.2:5900` and
`127.0.0.2:6081`. They have no direct tailnet or Docker route and must never be
moved to `127.0.0.1`, a wildcard listener, or IPv6. A legacy
`/home/codex/.vnc/passwd` may remain after an upgrade, but the unified gateway
does not use it.

## Register Chrome Remote Desktop on Ubuntu

Skip this section on Apple silicon and on Ubuntu when
`CODEX_DESKTOP_CRD_ENABLED=0`; authenticated noVNC uses the already-running
local Xvfb/Xfce session. When CRD is enabled, this step requires a short-lived
Google authorization code and a PIN chosen by the user. Neither value belongs
in chat, Git, logs, or a saved command.

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

Connect through noVNC on Apple silicon or noVNC-only Ubuntu, or through Chrome
Remote Desktop or noVNC when Ubuntu CRD is enabled. Codex and Chrome start in
the same Xfce session and
automatically recover from process exits.
At container startup, Chrome is registered as the default HTTP/HTTPS browser
and Codex is registered for the `codex:` OAuth callback. This lets the Codex
sign-in button open Chrome and return the completed login to the app.

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

## Provision Playwright MCP

The external MCP server uses stock pinned Playwright MCP in extension mode. It
does not use Chrome's debugging port.

1. In the same persistent Chrome, install the Playwright MCP extension.
2. Obtain its connection token through the extension's trusted UI.
3. In a trusted interactive root shell inside the container, run:

   ```bash
   remote-browser-extension-token
   ```

4. Paste the token only into the helper's hidden prompt.
5. Confirm `supervisorctl status playwright-mcp` reports `RUNNING`.
6. Run `remote-browser-credentials` locally in that TTY and configure the MCP
   client with the displayed HTTPS URL and bearer token.

Do not put either token in `deploy.env`, a command argument, chat, logs, or a
saved shell command. Prefer bearer authentication. Use the token-path MCP URL
only for clients that cannot set headers. See
[Remote browser MCP](remote-browser-mcp.md) for routes and recovery.

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

1. Connect through authenticated noVNC. When Ubuntu CRD is enabled, also connect
   through Chrome Remote Desktop and confirm both show the same desktop and
   Chrome tabs.
2. Run a real `@Chrome` action from Codex.
3. Restart only `codex-desktop.service` on Ubuntu or the Compose project on
   macOS.
4. Initialize a remote MCP session, list tools, take a harmless snapshot, and
   explicitly delete the session. Confirm the action is visible through noVNC.
5. Confirm Tailscale identity and Serve route, Codex sign-in, both Chrome
   extensions, cookies, gateway credentials, and extension token all survive.
6. When Ubuntu CRD is enabled, confirm its registration also survives.
7. Trigger one scheduled task without leaving a remote viewer attached.

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
