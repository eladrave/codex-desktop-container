# Agent deployment playbook

This playbook tells a deployment agent how to install the repository while
keeping all secrets and user-only authentication steps out of chat and logs.
It does not authorize deployment by itself. Deploy only when the user explicitly
asks for installation on a named host.

For image, installer, Compose, and verification behavior, the clean checked-out
repository and its exact commit are authoritative. Private host runbooks may
provide connection aliases, current service ownership, and production
constraints, but older embedded Dockerfiles, tags, or procedures must not
override newer repository code without an explicit reconciliation.

The repository supports only the Tailscale-only topology. Do not add LAN/public
port mappings, a public proxy, or an in-container public SSH service during this
workflow.

## Supported target matrix

| Target | Host GUI | Required selection | User-only browser work |
| --- | --- | --- | --- |
| Apple silicon macOS | The user must remain logged in for Docker Desktop and launchd; the container does not use the host display | Native ARM64, noVNC only, CRD absent, no Rosetta | Approve Tailscale on this or another trusted device, then use noVNC for optional Codex and `@Chrome` setup |
| Ubuntu 24.04 AMD64 headless or graphical | Not required | noVNC-only, matched `INSTALL_CRD=0` image | Approve Tailscale on another trusted device, then use noVNC |
| Ubuntu 24.04 AMD64 headless or graphical | Not required | CRD enabled, matched `INSTALL_CRD=1` image | Approve Tailscale on another trusted device, then complete Google's headless CRD registration before expecting noVNC to show a desktop |

Reject or report as unsupported: Intel macOS, Linux ARM64, other Linux
distributions, Windows/WSL, rootless Docker, a remote Docker daemon, Linux
without systemd and AppArmor, and serverless container platforms. Do not invent
an installation path, force AMD64 emulation on Apple silicon, or weaken the
documented security profile.

## 1. Ask the user these questions in order

Ask only for decisions not already answered by current context or an applicable
host-specific runbook.

1. **Target host:** Is the local target Ubuntu 24.04 AMD64 or Apple silicon
   macOS? For a remote Linux host, what approved SSH alias should the agent use?
2. **Existing installation:** Is this a fresh install or an upgrade that must
   preserve the existing home, Tailscale identity, machine identity, browser
   profile, remote-browser credentials, and Ubuntu
   CRD registration when present?
3. **Container hostname:** What local container hostname should be used?
4. **Tailscale hostname:** What stable MagicDNS/device hostname should be used?
5. **Tailnet/account:** Which Tailscale account or tailnet should own the node?
   A descriptive answer is enough; do not request account credentials.
6. **Enrollment method:** Should enrollment use a one-time auth key or a browser
   login URL?
7. **Auth key, when selected:** Ask the user to enter the key into the installer's
   hidden terminal prompt. Never ask them to paste it into chat.
8. **Browser approval, when selected:** Run the enrollment command, relay the
   generated URL, and ask the user to open it, select the intended account and
   tailnet, approve the node, and report completion.
9. **Timezone and desktop sizes:** Confirm the timezone and desired Xfce sizes.
10. **Resources:** Confirm memory limit, memory reservation, and CPU limit.
11. **Image:** Confirm the immutable image tag and whether to build it on the
    target host or use a preloaded image.
12. **Gateway:** Confirm the default Tailscale Serve HTTPS mode and the ACL that
    permits intended clients to reach TCP 443. Do not request gateway secrets.
13. **Ubuntu desktop access:** Ask whether to keep the default CRD-enabled mode
    or use noVNC only. noVNC-only mode starts Xvfb/Xfce inside the container and
    does not require a GUI on the Docker host. When CRD is enabled, ask the user
    to choose the Google account in their own browser, generate the short-lived
    Linux command, paste it directly into the trusted Tailscale SSH session, and
    enter the PIN at its hidden prompt. Apple silicon omits CRD and uses noVNC.
14. **Codex and Chrome:** Ask the user to sign in to Codex, install the Chrome
    plugin and official extension, choose the required website permissions, and
    decide whether full CDP is truly necessary.
15. **Playwright MCP:** No browser extension or extension token is required.
    Confirm the installer brings the MCP backend up automatically against the
    persistent headed Chrome through its protected Unix endpoint.
16. **Acceptance:** Ask which harmless site and scheduled-task prompt should be
    used for the final real browser test.

The agent may group short non-secret configuration questions, but it must keep
the authentication steps in the order above because later services depend on
Tailscale and the graphical desktop session.

## 2. Preflight without changing the host

Verify:

- target identity and approved SSH path;
- Ubuntu 24.04 AMD64 or Apple silicon macOS;
- Docker Engine/Compose or Docker Desktop;
- AppArmor tooling on Linux, or Docker Desktop native ARM64 readiness on macOS;
- userspace Tailscale is configured without `/dev/net/tun`, `NET_ADMIN`, or
  `NET_RAW`;
- available memory and disk;
- repository status and exact commit;
- existing service, container, image, and persistent-state paths;
- no unexpected published ports;
- no Chrome `--remote-debugging-port` argument or TCP CDP listener on any port;
- exactly one headed Chrome using the nondefault persistent profile, with its
  sandbox and installed extensions enabled;
- the private browser Unix endpoint exists below
  `/run/remote-browser/browser` and UID 10002 cannot traverse its directory;
- only the gateway on `127.0.0.1:8443`, with MCP, noVNC, and VNC backends on
  their documented `127.0.0.2` addresses;
- backup destination and free space.

Do not inspect or print authentication files. Do not continue through an
ambiguous existing deployment or conflicting service ownership.

## 3. Run the guided installer

From a clean clone on the authorized target host:

```bash
./scripts/install.sh
```

Use `sudo ./scripts/install.sh` on Ubuntu and the normal user on macOS. The
one-line bootstrap invokes this same entry point after platform detection.

Use an interactive TTY. Answer the non-secret configuration prompts from the
user's confirmed choices.

For a remote Ubuntu host, first perform read-only host and repository checks
through the approved SSH alias. Then keep a PTY attached for the entire
installer, using the already-resolved checkout path:

```bash
ssh -t APPROVED_ALIAS \
  'cd /ABSOLUTE/PATH/TO/codex-desktop-container && sudo ./scripts/install.sh'
```

Do not invent the alias or checkout path. Do not pipe the installer through a
non-interactive executor: its confirmations, hidden secret input, and browser
enrollment all use `/dev/tty`. If the agent environment cannot preserve that
TTY and present the waiting enrollment URL directly to the user, stop and ask
the user to run the same command in their own SSH terminal.

### Auth-key pause

When the user selected an auth key, stop and let them type it into the hidden
installer prompt. The installer writes it only to container tmpfs and invokes:

```bash
docker exec -i codex-desktop-desktop-1 \
  tailscale up \
  --auth-key=file:/run/secrets/tailscale-auth-key \
  --hostname=codex-desktop \
  --ssh
```

Never echo, quote, log, summarize, or retain the key. Confirm the temporary file
is gone after enrollment without displaying its former contents.

### Browser-login pause

When the user selected browser login, keep the installer attached. Ubuntu's
foreground `tailscale up` prints the URL to the SSH/console terminal; macOS
polls structured Tailscale state and prints the discovered `AuthURL` to
`/dev/tty`.

The host does not need a browser. Hand the short-lived URL directly to the user,
who may open it on a different trusted Mac, PC, phone, or tablet. Do not put it
in a durable transcript, log, ticket, or document. Ask the user to select the
intended account and tailnet and approve the device. Do not choose an account
for them. After the command finishes, verify only the sanitized account,
MagicDNS suffix, node DNS name, and online state before confirming the
installer prompt. noVNC is not used for Tailscale enrollment.

If the URL expires or the TTY disconnects, preserve all volumes and rerun the
installer from the same clean commit. If the wrong tailnet appears, stop. Do not
automatically run `tailscale logout` or `tailscale switch`; either operation
changes access and requires explicit operator approval.

## 4. Coordinate user-only desktop steps

On Ubuntu with CRD enabled, the agent must not ask the user to paste the CRD
authorization code or PIN into chat. Direct the user to:

1. Generate the Linux registration command at
   <https://remotedesktop.google.com/headless>.
2. Connect with `tailscale ssh root@TAILSCALE_HOSTNAME`.
3. Run `set +o history`, paste and run the command directly, then restore
   history with `set -o history` after it finishes.
4. Enter the PIN at the hidden prompt.
5. Connect through CRD and sign in to Codex.
6. Install the Chrome plugin and official extension through Codex settings.
7. Configure website permissions and test `@Chrome`.
8. Configure full CDP only if required and accept that approval prompts may
   prevent fully unattended use.

Before CRD registration, CRD-enabled mode starts the same local Xvfb/Xfce
fallback as noVNC-only mode. This makes authenticated noVNC and remote MCP ready
immediately, without weakening the CRD requirement. After registration,
restart the service or container once so the desktop-session selector switches
to CRD; then verify CRD and noVNC show the registered persistent desktop.

On Apple silicon or Ubuntu with CRD disabled, omit steps 1-4. Retrieve the
one-click noVNC URL only in the trusted local container TTY, open it from the
tailnet, sign in to Codex, and continue with the Chrome integration steps.

For both platforms, remote Playwright MCP is ready without a Playwright browser
extension or token. The official ChatGPT extension remains a separate optional
integration for Codex `@Chrome`; its site permissions and approval flow do not
authenticate or constrain external MCP.

### Configure a distinct MCP client name

Ask the user for a short location name or derive one from an already confirmed
host label. Use names such as `browser_home`, `browser_office`, or
`browser_codexgui`. Preserve any existing remote-browser entry instead of
overwriting it.

For Codex, register the non-secret endpoint and environment-variable name:

```bash
codex mcp add browser_home \
  --url https://TAILSCALE_HOSTNAME/mcp \
  --bearer-token-env-var CODEX_BROWSER_HOME_TOKEN
```

The user, not the agent transcript, must move the bearer token shown by
`remote-browser-credentials` into the client's approved secret store or
launcher environment. A local `http_headers_helper` is acceptable only when it
reads from an OS secret manager or other root/user-protected store and emits no
logs. Do not run or capture `remote-browser-credentials` through agent tools.

Reload the client and confirm the new unique server name and the pre-existing
remote server both remain available.

## 5. Verify

Run:

```bash
sudo /opt/services/codex-desktop/scripts/verify-deployment.sh
```

On macOS use
`~/.local/share/codex-desktop/source/scripts/verify-macos.sh` instead.

Then complete real workflow acceptance:

- Tailscale SSH succeeds from an allowed device.
- authenticated noVNC shows the Xfce session; when enabled on Ubuntu, CRD shows
  that same session.
- Codex and Chrome are running as UID 10001.
- Chrome reports connected in Codex.
- One harmless `@Chrome` task succeeds.
- Remote MCP initializes, lists tools, snapshots the same visible Chrome, and
  explicitly deletes its test session without changing the Chrome PID.
- Restarting only Playwright MCP leaves the Chrome PID unchanged. Terminating
  Chrome causes the owner to recreate the private endpoint and the MCP to
  recover against the replacement browser.
- Container recreation preserves Tailscale, Codex, the Chrome profile and any
  installed extensions, browser state, gateway credentials, and Ubuntu CRD
  registration when present.
- One scheduled task runs with no viewer attached.
- Docker still reports no published ports.

## 6. Report

Report the target hostname, deployed commit, immutable image reference, service
health, non-sensitive Tailscale identity and Serve summary,
configured desktop mode, CRD/noVNC/Codex/Chrome/MCP test results, backup
location, and any incomplete user-only step.

Never include auth keys, CRD codes, PINs, browser cookies, gateway credentials,
OAuth material, private profile contents, or Tailscale state
in the report.

## 7. Resume and recovery rules

- An interrupted installer may leave a healthy base container intentionally.
  Reconnect with a PTY, inspect sanitized status, and rerun the same clean
  commit. Preserve the persistent state.
- An expired or lost enrollment URL is replaced by rerunning browser
  enrollment. Never reuse one from chat or logs.
- A wrong-tailnet result is an access-impacting mismatch. Preserve it for
  investigation and request explicit direction before logging out or switching.
- Missing Serve 443 requires checking Tailscale state, MagicDNS, HTTPS, and ACL
  prerequisites. Never publish a Docker port as a recovery shortcut.
- A CRD-enabled image and a noVNC-only runtime flag, or the reverse, is invalid.
  Rebuild or choose an image whose CRD label matches the configured mode.
- Base verification may use `--allow-incomplete` only while a named user-only
  CRD registration step remains. MCP itself must already be healthy and pass
  initialize, tool listing, snapshot, and deletion. Do not report full deployment
  success until the real MCP and browser acceptance checks pass.
