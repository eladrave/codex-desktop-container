# Tailscale operations

Tailscale is the default deployment's only inbound network. Docker publishes no
host ports. `tailscaled` runs with `--tun=userspace-networking`, so it requires
no TUN device or network-administration capabilities. Tailscale SSH provides the
administrative shell. Tailscale Serve terminates tailnet HTTPS on TCP 443 and
forwards only to the authenticated gateway on `127.0.0.1:8443`.

## How the tailnet is selected

The image does not choose an account or tailnet automatically.

- With an auth key, the device joins the tailnet that issued the key.
- With browser enrollment, the account and tailnet selected in the login page
  own the new device.
- After enrollment, the identity is stored in
  `/var/lib/codex-desktop/tailscale` and survives restarts.

A single Tailscale daemon can have only one active account/tailnet at a time.
For this server, keep one designated tailnet active rather than switching it
during scheduled work.

## Enroll with a one-time auth key

Generate a one-time, non-ephemeral key from the intended tailnet. Use a tag only
when the tailnet policy intentionally grants that tag the required SSH and
HTTPS gateway access. Use pre-approval only when device approval is enabled. Do not
paste the key into chat, Git, `deploy.env`, shell history, or a command argument.

Create the temporary file through standard input from a trusted terminal:

```bash
sudo docker exec codex-desktop-desktop-1 \
  install -d -o root -g root -m 0700 /run/secrets
read -rsp 'Tailscale auth key: ' TS_ENROLLMENT_KEY; echo
printf '%s' "$TS_ENROLLMENT_KEY" | \
  sudo docker exec -i codex-desktop-desktop-1 \
  sh -c 'umask 077; cat > /run/secrets/tailscale-auth-key'
unset TS_ENROLLMENT_KEY
```

Enroll using the file-backed key:

```bash
sudo docker exec -i codex-desktop-desktop-1 \
  tailscale up \
  --auth-key=file:/run/secrets/tailscale-auth-key \
  --hostname=codex-desktop \
  --ssh
```

Remove the temporary file even when enrollment fails:

```bash
sudo docker exec codex-desktop-desktop-1 \
  rm -f /run/secrets/tailscale-auth-key
```

The guided installer performs these steps automatically and registers an exit
trap so the temporary file is removed after errors.

## Enroll with a browser login URL

On Ubuntu, run the guided installer in an attached SSH or console TTY. Its
foreground enrollment step is equivalent to:

```bash
sudo docker exec -i codex-desktop-desktop-1 \
  tailscale up --hostname=codex-desktop --ssh
```

On Apple silicon the installer starts enrollment in the background and polls
`tailscale status --json` until `AuthURL` appears. In both cases, the installer
prints the short-lived login URL to the trusted terminal and waits.

The Docker host does not need a GUI or browser. Copy the URL directly to a
trusted browser on another Mac, PC, phone, or tablet, sign in with the intended
Tailscale account, select the correct tailnet, and approve the device. Use a
private browser window when multiple accounts may already be signed in. Treat
the URL as a short-lived sensitive enrollment link: give it only to the user
performing approval and do not retain it in chat, logs, tickets, or docs.

Do not interrupt the command while browser approval is pending. It returns when
the device is enrolled. The installer then displays a sanitized account,
MagicDNS suffix, node DNS name, and online state and requires the operator to
confirm that they match the intended tailnet. noVNC is not needed until after
this enrollment succeeds.

If the URL expires, the terminal disconnects, or approval never completes,
leave the persistent state intact and rerun the guided installer from the same
clean commit to obtain a new URL. If the wrong tailnet was selected, stop: the
installer deliberately preserves the observed identity for investigation and
does not log out or switch accounts without explicit operator approval.

## Connect to the container

From an allowed tailnet device:

```bash
tailscale ssh root@codex-desktop
```

You can also use the current Tailscale IPv4:

```bash
tailscale ssh root@100.x.y.z
```

The hostname is the configured `TAILSCALE_HOSTNAME`. Root is the intentional
Tailscale SSH administrative account. The desktop and browser processes run as
the unprivileged `codex` user.

After connecting as root, enter the persistent workspace:

```bash
cd /home/codex/Projects
```

Run user-scoped commands as the desktop user:

```bash
setpriv --reuid=10001 --regid=10001 --init-groups \
  env HOME=/home/codex USER=codex LOGNAME=codex \
  CODEX_HOME=/home/codex/.codex \
  bash -lc 'id; pwd'
```

## Use Tailscale inside the container

From a Tailscale SSH shell, the CLI uses the local daemon socket automatically:

```bash
tailscale status
tailscale ip -4
tailscale ping PEER_NAME
tailscale netcheck
tailscale debug prefs | jq '{WantRunning,RunSSH,Hostname,CorpDNS}'
```

From the Docker host, prefix the same operations with `docker exec`:

```bash
sudo docker exec codex-desktop-desktop-1 tailscale status
sudo docker exec codex-desktop-desktop-1 tailscale ip -4
sudo docker exec codex-desktop-desktop-1 tailscale ping PEER_NAME
```

The daemon state is `/var/lib/tailscale/tailscaled.state`. Ubuntu backs it with
the host directory `/var/lib/codex-desktop/tailscale`; Apple silicon uses the
named Docker volume `codex-desktop-tailscale`. Its local socket is
`/run/tailscale/tailscaled.sock`, which is ephemeral and recreated at startup.

Do not print the state file or copy it into Git. Treat it as authentication
material.

Because the daemon uses userspace networking, the operating system does not
receive a Tailscale network interface. Tailscale SSH is handled by the daemon,
and incoming tailnet TCP connections are forwarded by its netstack to matching
container-loopback listeners. Ordinary Codex and Chrome internet traffic keeps
using Docker's normal outbound network.

## Multiple accounts

Inspect remembered accounts without changing the active one:

```bash
tailscale switch --list
```

Tailscale supports switching an existing device to another remembered account:

```bash
tailscale switch ACCOUNT_OR_NICKNAME
```

Do not switch this server casually. Only one tailnet is active, and switching
changes SSH reachability, noVNC reachability, ACLs, MagicDNS, and potentially
the Tailscale IP. Scheduled work can be interrupted.

If simultaneous membership in two tailnets is required, use separate container
instances with separate Tailscale state and hostnames.

## HTTPS gateway over Tailscale

The gateway process configures the equivalent of:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8443
```

Inspect the active mapping without displaying gateway credentials:

```bash
tailscale serve status
```

Tailnet ACLs must allow intended MCP clients and noVNC viewers to reach TCP
443. Use the one-click URL or Basic Auth connection details retrieved locally
with `remote-browser-credentials`. Do not route tailnet traffic directly to the
MCP, noVNC, or VNC backend ports.
Keep every other node port denied except the explicitly authorized Tailscale
SSH path. Do not grant this node broad `*:*` access. Playwright browser control
uses a mode-`0700` private Unix endpoint, never a TCP CDP listener, while
userspace networking can forward tailnet traffic to matching localhost TCP
listeners even though Docker publishes no ports.

The backends use `127.0.0.2:8932`, `127.0.0.2:6081`, and
`127.0.0.2:5900`. That alias keeps them outside userspace networking's
same-port `127.0.0.1` forwarding behavior. If a verifier finds any of those
services on `127.0.0.1`, `0.0.0.0`, or bracketed IPv6, treat the deployment as
unsafe and stop it before accepting traffic.

## Temporary guest access without a Tailscale client

The permanent noVNC link remains private behind Tailscale Serve HTTPS 443. If
the user explicitly needs access from a guest machine that cannot run
Tailscale, the MCP tool `create_temporary_novnc_link` starts a separate
foreground Funnel on HTTPS 10000. It targets only the guest proxy on
`127.0.0.1:8444`; it never exposes the permanent gateway, MCP, Basic Auth, or
the permanent login token.

The guest link may be redeemed once and the resulting guest session ends at the
original 30-minute deadline. `revoke_temporary_novnc_link` closes it earlier.
Serve 443 and Funnel 10000 use different ports and can coexist. Do not manually
move Funnel to 443, run it with `--bg`, or use `tailscale funnel reset`.

Funnel requires MagicDNS, HTTPS, and the Funnel node capability. The broker
does not change tailnet policy. If `MagicDNSSuffix` is absent from `tailscale
status --json`, an administrator must enable MagicDNS before the guest tool can
return a public link. The live regression also requires a public DNS answer and
tests the real HTTPS endpoint before the feature is accepted.

## Restart and recovery

Normal service and container restarts reuse the stored identity. Do not run
`tailscale logout` during an ordinary upgrade or recovery.

Inspect safely:

```bash
sudo docker exec codex-desktop-desktop-1 tailscale status
sudo docker exec codex-desktop-desktop-1 tailscale ip -4
sudo docker logs --tail 200 codex-desktop-desktop-1
```

If the persistent state is actually lost or invalid, create a new one-time key
or repeat the browser enrollment. Never reuse a key from chat or logs.

Back up `/var/lib/codex-desktop/tailscale` only while the service is stopped,
preserving root ownership and restrictive permissions. Restore it together with
the persistent home and machine identity, then verify the same hostname,
Tailscale IP, and Serve mapping before considering recovery complete.

## Authoritative references

- [Tailscale auth keys](https://tailscale.com/docs/features/access-control/auth-keys)
- [`tailscale up` reference](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel)
- [Fast user switching](https://tailscale.com/kb/1225/fast-user-switching)
- [Userspace networking mode](https://tailscale.com/docs/concepts/userspace-networking)
