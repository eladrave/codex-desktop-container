# Agent deployment playbook

This playbook tells a deployment agent how to install the repository while
keeping all secrets and user-only authentication steps out of chat and logs.
It does not authorize deployment by itself. Deploy only when the user explicitly
asks for installation on a named host.

The repository supports only the Tailscale-only topology. Do not add LAN/public
port mappings, a public proxy, or an in-container public SSH service during this
workflow.

## 1. Ask the user these questions in order

Ask only for decisions not already answered by current context or an applicable
host-specific runbook.

1. **Target host:** Is the local target Ubuntu 24.04 AMD64 or Apple silicon
   macOS? For a remote Linux host, what approved SSH alias should the agent use?
2. **Existing installation:** Is this a fresh install or an upgrade that must
   preserve the existing home, Tailscale identity, machine identity, browser
   profile, remote-browser credentials, Playwright extension token, and Ubuntu
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
13. **Ubuntu Chrome Remote Desktop:** On Ubuntu only, ask the user to choose the
    Google account in their own browser, generate the short-lived Linux command,
    paste it directly into the trusted Tailscale SSH session, and enter the PIN
    at its hidden prompt. Apple silicon omits CRD and uses noVNC.
14. **Codex and Chrome:** Ask the user to sign in to Codex, install the Chrome
    plugin and official extension, choose the required website permissions, and
    decide whether full CDP is truly necessary.
15. **Playwright MCP:** Ask the user to install the Playwright extension in the
    same persistent Chrome and enter its token only into the hidden
    `remote-browser-extension-token` prompt.
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
- no Chrome `--remote-debugging-port` argument or listener on TCP 9222;
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

When the user selected browser login, the installer prints a URL. Relay that URL
only to the user, wait while they select the correct account/tailnet and approve
the node, then let the waiting command finish. Do not choose an account for them.

## 4. Coordinate user-only desktop steps

On Ubuntu, the agent must not ask the user to paste the CRD authorization code
or PIN into chat. Direct the user to:

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

On Apple silicon, omit steps 1-4. Retrieve the one-click noVNC URL only in the
trusted local container TTY, open it from the tailnet, sign in to Codex, and
continue with the Chrome integration steps.

For both platforms, direct the user to install the Playwright extension in the
same Chrome profile and run `remote-browser-extension-token` in a trusted
interactive root shell. They must paste the token only into that helper's hidden
prompt. Never ask for the token in chat and never put it in a command argument.

## 5. Verify

Run:

```bash
sudo /opt/services/codex-desktop/scripts/verify-deployment.sh
```

On macOS use
`~/.local/share/codex-desktop/source/scripts/verify-macos.sh` instead.

Then complete real workflow acceptance:

- Tailscale SSH succeeds from an allowed device.
- authenticated noVNC shows the Xfce session; on Ubuntu, CRD shows that same
  session.
- Codex and Chrome are running as UID 10001.
- Chrome reports connected in Codex.
- One harmless `@Chrome` task succeeds.
- Remote MCP initializes, lists tools, operates the same visible Chrome, and
  explicitly deletes its test session.
- Container recreation preserves Tailscale, Codex, both extensions, browser
  state, gateway credentials, extension token, and Ubuntu CRD registration when
  present.
- One scheduled task runs with no viewer attached.
- Docker still reports no published ports.

## 6. Report

Report the target hostname, deployed commit, immutable image reference, service
health, non-sensitive Tailscale identity and Serve summary,
CRD/noVNC/Codex/Chrome/MCP test results, backup location, and any incomplete
user-only step.

Never include auth keys, CRD codes, PINs, browser cookies, gateway credentials,
extension tokens, OAuth material, private profile contents, or Tailscale state
in the report.
