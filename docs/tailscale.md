# Tailscale operations

Tailscale is the container's only inbound network. Docker publishes no host
ports. Tailscale SSH provides administrative shell access, and noVNC listens
only on the active Tailscale IPv4.

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
noVNC access. Use pre-approval only when device approval is enabled. Do not
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

Run:

```bash
sudo docker exec -i codex-desktop-desktop-1 \
  tailscale up --hostname=codex-desktop --ssh
```

Open the printed URL in a trusted browser. Sign in with the intended Tailscale
account, select the correct tailnet, and approve the device. Use a private
browser window when multiple accounts may already be signed in.

Do not interrupt the command while browser approval is pending. It returns when
the device is enrolled.

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

The daemon state is `/var/lib/tailscale/tailscaled.state`, backed by the host
directory `/var/lib/codex-desktop/tailscale`. Its local socket is
`/run/tailscale/tailscaled.sock`, which is ephemeral and recreated at startup.

Do not print the state file or copy it into Git. Treat it as authentication
material.

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

## noVNC over Tailscale

After configuring the password and starting the CRD desktop session, open:

```text
http://codex-desktop:6080/vnc.html?autoconnect=1&resize=scale
```

The noVNC listener follows the active Tailscale IPv4 and restarts if that
address changes. Tailnet ACLs must allow intended viewers to reach TCP 6080.
Docker does not publish TCP 6080, and raw VNC TCP 5900 is loopback-only.

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
the persistent home and machine identity, then verify the same hostname and
Tailscale IP before considering recovery complete.

## Authoritative references

- [Tailscale auth keys](https://tailscale.com/docs/features/access-control/auth-keys)
- [`tailscale up` reference](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [Fast user switching](https://tailscale.com/kb/1225/fast-user-switching)
