# Remote browser MCP

The container is a direct, single-container replacement for the browser,
gateway, and desktop capabilities of `remotechromemcp`. It adds a stock pinned
Playwright MCP server to the same persistent visible Chrome used by Codex and
noVNC. It does not start a second Chrome, require a Playwright browser
extension, or enable a TCP Chrome debugging port.

## Network and process contract

Docker publishes no ports. Tailscale Serve is the only inbound path:

```text
tailnet client
  -> Tailscale Serve HTTPS :443
    -> authenticated gateway 127.0.0.1:8443
      -> Playwright MCP 127.0.0.2:8932
      -> noVNC 127.0.0.2:6081
        -> x11vnc 127.0.0.2:5900
          -> the managed Xfce display and persistent Chrome
```

The `127.0.0.2` backend addresses are deliberate. In Tailscale userspace mode,
tailnet traffic to a port can be forwarded to the same port on `127.0.0.1`.
Putting an unauthenticated backend there would bypass the gateway. Never move
ports 5900, 6081, or 8932 to `127.0.0.1`, a wildcard address, or IPv6.

Supervisor independently owns `remote-browser-owner`, `playwright-mcp`,
`remote-browser-keeper`, and `remote-browser-gateway`. The owner launches one
headed persistent Chrome with stock Playwright `launchPersistentContext`,
extensions enabled, `chromiumSandbox: true`, and a nondefault profile at
`/home/codex/.config/remote-browser/chrome-profile`. It binds browser control
without a host or port, producing a Unix socket, and atomically publishes the
stable symlink `/run/remote-browser/browser/endpoint.sock`.

The endpoint directory is owned by `codex` with mode `0700`; UID 10002 cannot
traverse it. Playwright MCP connects with its supported `--endpoint` option.
Chrome must never receive `--remote-debugging-port` or a sandbox-disabling flag,
and no process may expose CDP over TCP on any port. Restarting or deleting MCP
sessions must not close Chrome. The keeper maintains one nonmutating MCP client
so the shared browser remains attached and reconnects after an MCP or browser
restart. If Chrome crashes, the owner creates a replacement endpoint and the
keeper restores the attachment. None of these integration processes rewrites
the pinned Playwright MCP package.

Playwright MCP runs as the same `codex` user that owns Chrome and the persistent
profile. Treat it as full desktop-user authority, not an OS isolation boundary.
The gateway limits who can invoke that authority, but it cannot constrain a
successfully authenticated MCP client to a subset of the user's browser data.
Avoid simultaneous browser-changing work from external MCP, Codex `@Chrome`,
and a human noVNC session because the controllers can navigate or edit the same
tabs. There is no enforceable global browser lease.

## Routes and authentication

The Tailscale HTTPS origin is normally:

```text
https://TAILSCALE_HOSTNAME
```

The gateway provides:

- `POST /mcp` and `DELETE /mcp` with `Authorization: Bearer ...`;
- `/<MCP_TOKEN>/mcp` as optional compatibility routing for clients that cannot
  send an Authorization header;
- `/login/?token=<LOGIN_TOKEN>` for one-click noVNC entry, which exchanges the
  token for an HttpOnly, Secure, SameSite=Strict cookie and redirects to the
  token-free `/login/?autoconnect=1&resize=scale` URL;
- `/login/` with independently generated HTTP Basic credentials as a fallback;
- `/healthz` for non-secret liveness checks.

Other methods on the MCP route return 405. Gateway access logs are discarded so
token-path and one-click URLs do not enter routine logs. Treat both URL forms as
password-equivalent anyway. Do not paste them into chat, tickets, or command
lines.

The original one-click URL is reusable until gateway credentials are rotated.
After the token-cookie exchange, noVNC automatically connects to the existing
Xfce session and scales it to the phone or browser viewport. No VNC password or
second Connect action is required.

## Credentials

Gateway credentials are created once at first start and stored in the persistent
machine-state volume:

```text
/var/lib/codex-desktop-persistent/remote-browser/credentials.env
```

The directory is root-owned mode `0700`; the file is root-owned mode `0600`.
It contains independent random MCP, one-click login, and Basic Auth credentials.
It is not an environment file supplied by the host and must not be copied into
`deploy.env`.

Retrieve connection details only in a trusted interactive root shell:

```bash
remote-browser-credentials
```

The command refuses non-interactive output because its result contains secrets.
Do not ask an agent to run it and do not redirect or capture its output. Store
the values in the intended MCP client's secret store or a password manager.

On macOS, enter the container interactively first:

```bash
docker exec -it codex-desktop-desktop-1 bash
remote-browser-credentials
```

## Browser attachment

No Playwright extension provisioning is required. On every start, the browser
owner opens the persistent headed Chrome and publishes its private Unix
endpoint. MCP and the keeper attach automatically. A healthy deployment has the
owner, keeper, and MCP processes running, the endpoint socket present, and the
MCP backend listening on `127.0.0.2:8932` before any human signs into Codex.

The official Codex browser extension remains separate. Install and approve it
through Codex settings for `@Chrome` work. External Playwright MCP access does
not bypass or replace Codex approvals.

## MCP client setup

Prefer the header-authenticated endpoint. Configure the client using the exact
HTTPS origin and bearer token displayed by `remote-browser-credentials`. Use the
token-path endpoint only when a client cannot send headers, because URLs are
more likely to be retained in history or diagnostics.

Use a unique MCP server name for each physical browser host. For example, keep
an existing remote service as `remote_browser` or `browser_codexgui` and add a
same-host deployment as `browser_home`. Do not replace one entry merely because
both servers expose the same Playwright tool names.

Codex clients can store the endpoint and only an environment-variable reference:

```bash
codex mcp add browser_home \
  --url https://TAILSCALE_HOSTNAME/mcp \
  --bearer-token-env-var CODEX_BROWSER_HOME_TOKEN
```

The user must place the bearer token in the client's approved secret store or
launcher environment through a trusted local surface. Never put the value in
the command, repository, shared shell profile, or an agent transcript. When a
client supports `http_headers_helper`, it may instead invoke a local secret
manager command that returns the Authorization header; the helper must not log
or persist the value.

After the client reloads its MCP configuration, confirm both named servers are
visible. Initialize the new server, list tools, take one harmless snapshot, and
delete the session. Restart the container and repeat the initialize/list/snapshot/delete
sequence to verify that Tailscale identity, gateway credentials, Chrome state,
and installed extensions persist.

The server injects the browser-operation playbook and the human-handoff tools
from `remotechromemcp`. Use the handoff URL when a person must complete login,
MFA, CAPTCHA, consent, payment, or another sensitive step. Never send website
credentials, recovery codes, cookies, or MFA material through MCP or chat.

## Permanent and temporary noVNC links

`get_novnc_link` and `remote_chrome_request_human_intervention` return the
permanent tailnet-only one-click link. Its token and origin persist across
container recreation, so the user can keep it in a password manager or trusted
bookmark. It remains protected by tailnet identity and ACLs as well as the
gateway token.

When the user explicitly says the current machine cannot use Tailscale, call
`create_temporary_novnc_link`. It accepts no arguments and returns two links:

- the unchanged permanent tailnet-only link;
- a new public guest link on Funnel HTTPS 8443.

The guest link is password-equivalent. Its token is independent from every
persistent credential, may be redeemed exactly once, and is exchanged through
a token-free POST for a distinct guest cookie. Link previews do not consume it.
The cookie and the entire guest session retain the original fixed 30-minute
deadline; redemption and reconnection never extend that deadline. The guest
proxy authenticates every asset and WebSocket request, serves only noVNC, and
cannot route MCP, permanent login, Basic Auth, or arbitrary upstreams.

The guest Funnel is a foreground, session-bound Tailscale configuration on
external port 8443. Private Serve remains on 443. The Funnel targets a separate
unprivileged guest proxy on `127.0.0.1:8444`, never the permanent gateway on
8443. On expiry, revocation, proxy failure, broker failure, or container stop,
the implementation destroys open HTTP/WebSocket connections and terminates the
Funnel process. Guest tokens and cookies exist only in memory, so old guest
links fail after restart.

Call `revoke_temporary_novnc_link` as soon as the user finishes. The user should
use a private browsing window on an untrusted machine, close it afterward, and
avoid saving the guest URL, cookie, downloads, or browser credentials there.

Funnel requires the tailnet's Funnel capability, MagicDNS, and HTTPS support.
If those prerequisites are absent, creation fails without returning a usable
URL or changing tailnet policy. An operator must complete Tailscale's one-time
administrative enablement separately.

The broker requires `tailscale status --json` to report a non-empty
`MagicDNSSuffix` matching the node DNS name before it starts Funnel. Local
`AllowFunnel` configuration alone is not sufficient evidence of public
reachability. Before returning a URL, the broker resolves the hostname through
public DNS and fetches the preview-safe landing page over the real Funnel HTTPS
route. The live acceptance client independently repeats the full redemption,
noVNC, WebSocket, and revocation workflow without printing its token.

This is trusted full-desktop access, not tenant isolation. A person controlling
the existing desktop can open a terminal and access browser/profile state under
the desktop user's authority. The enforceable network boundary is that the
temporary public URL and cookie cannot authenticate MCP HTTP requests and the
Funnel has no MCP route.

## Optional codexgui edge compatibility

The default deployment is Tailscale-only and does not join Docker's external
`edge` network. `compose.codexgui.yaml` is the opt-in direct-replacement
override for the existing `remotechromemcp` service. Its contract is:

- join the existing external `edge` network with alias `remote-chrome`;
- expose no host ports from this container;
- let only the existing central edge publish host TCP 80 and 443;
- present private compatibility ports 8931 for MCP and 6080 for noVNC;
- keep the actual MCP, noVNC, and VNC backends on their `127.0.0.2` addresses;
- preserve the central edge's bearer/token-path MCP authentication, noVNC
  token-cookie exchange, Basic Auth fallback, WebSocket handling, rewrites, and
  secret-path log suppression;
- use `https://chrome.eladrave.com` as the handoff origin and disable Tailscale
  Serve only in that compatibility deployment.

The override sets `REMOTE_BROWSER_EDGE_COMPAT=1`, disables Tailscale Serve,
joins `edge` as `remote-chrome`, and exposes only container-network ports 8931
and 6080. The compatibility listeners intentionally do not duplicate public
authentication: the central Caddy owns bearer and token-path MCP auth, the
noVNC login-cookie exchange, Basic Auth, WebSocket handling, and secret-path
log suppression. They proxy only to the private loopback backends.

For an actual replacement, the override also mounts the existing
`/var/lib/remote-chrome/profile` directly at the managed nondefault profile path
`/home/codex/.config/remote-browser/chrome-profile` and
mounts `/etc/remote-chrome/credentials.env` read-only for the root gateway
process. The profile is not copied or reformatted, UID/GID 10001 remain the
same, and the old one-click handoff URL remains valid. Only the validated URL is
shared with the unprivileged MCP process through a root-created mode-`0440`
runtime file; the legacy credential file itself is not readable by Codex,
Chrome, or Playwright MCP. The interactive `remote-browser-credentials` helper
reports the existing edge connection values in this mode rather than generating
a second public identity.

`EDGE_NETWORK_NAME`, `REMOTE_BROWSER_EDGE_ALIAS`,
`REMOTE_BROWSER_PROFILE_PATH`, and `REMOTE_BROWSER_EDGE_CREDENTIALS_PATH` may
be changed only for an isolated pre-deployment test. Production uses their
defaults: `edge`, `remote-chrome`, `/var/lib/remote-chrome/profile`, and
`/etc/remote-chrome/credentials.env`.

Before any production replacement, compare the live central Caddy files and
environment schema with the authoritative CodexGUI runbook, validate this
override against an isolated alias, and prove both public authentication forms,
noVNC HTTP/WebSocket behavior, MCP session deletion, persistent profile reuse,
and rollback. Do not attach this container as `remote-chrome`, stop the current
service, or change its state without explicit user approval.

The old and new containers must never run concurrently against the shared
profile. A production cutover must stop the old browser, verify the profile has
no live owner, start the unified container with the override, and leave the old
service and release available but stopped for rollback. Rollback stops the
unified container before restarting the old service against the same profile.

## Operations

Inspect the independent processes without displaying credentials:

```bash
supervisorctl status remote-browser-owner remote-browser-keeper \
  playwright-mcp remote-browser-gateway
tailscale serve status
ss -lnt
```

Restart only a failed MCP or gateway process:

```bash
supervisorctl restart playwright-mcp
supervisorctl restart remote-browser-gateway
```

If the private endpoint is missing, inspect `remote-browser-owner` before MCP.
MCP must never launch a second browser or damage the existing profile.

The normal Docker health check is non-mutating. It checks process/listener state
but does not initialize MCP sessions, create tabs, or attach a debugger. Run a
real initialize, `tools/list`, browser snapshot, and DELETE canary separately
when validating functional browser control.

Deployment acceptance must additionally exercise lifecycle recovery: keep the
MCP process running, restart only the supervised Chrome process, initialize a
new MCP session, take a visible snapshot, and delete the session. The MCP PID
must remain unchanged, Chrome must receive a new PID, and the persistent profile
must remain intact. This disruptive recovery check is manual acceptance only;
the hourly canary never restarts Chrome.

After the normal verifier passes, install the optional hourly functional canary:

```bash
# Ubuntu
sudo /opt/services/codex-desktop/scripts/install-functional-canary.sh

# Apple silicon
~/.local/share/codex-desktop/source/scripts/install-functional-canary.sh
```

The installer first runs the canary once, then creates a systemd timer on
Ubuntu or a per-user launch agent on macOS. Each run uses a non-overlapping lock,
keeps the bearer token in a temporary mode-0600 file inside the container,
initializes one MCP session, verifies tools and a visible snapshot, and deletes
the session. It never restarts Chrome or retries a failed browser action. The
scheduled probe is read-only: it lists tools and snapshots the current visible
page without navigating, clicking, or typing.

## Backup, upgrade, and rollback

The existing stopped-container backup flow preserves everything required by the
unified service:

- `/home/codex`, including Chrome, Codex, the browser profile, and any installed
  extensions;
- `/var/lib/tailscale`, including the node identity and Serve configuration;
- `/var/lib/codex-desktop-persistent`, including machine identity and gateway
  credentials.

Do not rotate credentials during an ordinary rebuild, upgrade, or rollback.
Back up all three state stores while the container is stopped and restore them
as one matching set only during an explicitly authorized state recovery. Treat
every archive as credential-bearing data.

After an immutable-image upgrade or rollback, verify that credential file hashes
are unchanged without printing their contents, that Tailscale Serve still maps
HTTPS 443 to the gateway, and that browser cookies, extensions, Codex sign-in,
MCP connectivity, and authenticated noVNC all survive.

The older `remotechromemcp` repository includes optional GCS backup machinery.
It is not active on the current codexgui deployment and is not duplicated here.
This repository's supported backup is the existing quiesced full-state local
backup, which now includes gateway credentials. Adding
off-host GCS export remains a separate, explicitly authorized infrastructure
task because it requires cloud credentials, bucket policy, retention, and
restore validation.
