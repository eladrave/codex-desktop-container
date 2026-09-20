#!/usr/bin/env python3
"""Root-only broker for short-lived, one-time remote-browser guest access.

The wire protocol is deliberately tiny: one newline-delimited JSON request and
one newline-delimited JSON response per Unix-domain socket connection.  The
only accepted request field is ``action`` and the only actions are ``create``,
``status`` and ``revoke``.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import signal
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


SOCKET_PATH = "/run/remote-browser/guest-control.sock"
STATUS_PATH = "/run/remote-browser/guest-status.json"
TAILSCALE_SOCKET = "/run/tailscale/tailscaled.sock"
TAILSCALE_BIN = "/usr/local/bin/tailscale"
SETPRIV_BIN = "/usr/bin/setpriv"
SESSION_BIN = "/usr/local/libexec/remote-browser-guest-session"
CODEX_UID = 10001
CODEX_GID = 10001
GUEST_UID = 10002
GUEST_GID = 10002
GUEST_PORT = 8443
PROXY_PORT = 8444
UPSTREAM_HOST = "127.0.0.2"
UPSTREAM_PORT = 6081
PROXY_TARGET = f"http://127.0.0.1:{PROXY_PORT}"
PRODUCTION_TTL = 1800.0
MAX_FRAME = 4096
STATES = {"CLOSED", "STARTING", "ISSUED", "REDEEMED", "CLOSING", "BLOCKED"}
_DNS_RE = re.compile(r"(?=^.{1,253}$)^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(?:\.(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?))*$")


class BrokerError(Exception):
    """An expected failure whose message is safe to return to a client."""


def _bool_env(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _compact_json(value: object) -> bytes:
    return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")


def _walk_dicts(value: Any):
    if isinstance(value, dict):
        yield value
        for nested in value.values():
            yield from _walk_dicts(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from _walk_dicts(nested)


def _port_is_configured(value: Any, port: int = GUEST_PORT) -> bool:
    needle = str(port)
    for mapping in _walk_dicts(value):
        for key, configured in mapping.items():
            key_text = str(key).rstrip(".")
            if (key_text == needle or key_text.endswith(f":{needle}")) and configured not in (None, False, {}, []):
                return True
    return False


def _exact_funnel_config(value: Any, dns_name: str) -> bool:
    endpoint = f"{dns_name}:{GUEST_PORT}"
    for mapping in _walk_dicts(value):
        tcp_ok = web_ok = allow_ok = False
        tcp = mapping.get("TCP")
        if isinstance(tcp, dict):
            port_value = tcp.get(str(GUEST_PORT), tcp.get(GUEST_PORT))
            if isinstance(port_value, dict) and port_value.get("HTTPS") is True:
                tcp_ok = True

        web = mapping.get("Web")
        if isinstance(web, dict):
            endpoint_value = web.get(endpoint)
            if isinstance(endpoint_value, dict):
                handlers = endpoint_value.get("Handlers")
                if isinstance(handlers, dict):
                    root = handlers.get("/")
                    if isinstance(root, dict) and root.get("Proxy") == PROXY_TARGET:
                        proxies = [
                            handler.get("Proxy")
                            for handler in handlers.values()
                            if isinstance(handler, dict) and "Proxy" in handler
                        ]
                        if proxies and all(proxy == PROXY_TARGET for proxy in proxies):
                            web_ok = True

        allow = mapping.get("AllowFunnel")
        if isinstance(allow, dict) and allow.get(endpoint) is True:
            allow_ok = True
        if tcp_ok and web_ok and allow_ok:
            return True
    return False


def _dns_name_end(packet: bytes, offset: int) -> int:
    while True:
        if offset >= len(packet):
            raise BrokerError("Public Funnel DNS is unavailable")
        length = packet[offset]
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(packet):
                raise BrokerError("Public Funnel DNS is unavailable")
            return offset + 2
        offset += 1
        if length == 0:
            return offset
        if length > 63 or offset + length > len(packet):
            raise BrokerError("Public Funnel DNS is unavailable")
        offset += length


class GuestAccessBroker:
    def __init__(self) -> None:
        self.test_mode = _bool_env("REMOTE_BROWSER_GUEST_TEST_MODE")
        if os.geteuid() != 0 and not self.test_mode:
            raise RuntimeError("guest broker must run as root")

        self.socket_path = Path(self._test_override("REMOTE_BROWSER_GUEST_TEST_SOCKET_PATH", SOCKET_PATH))
        self.status_path = Path(self._test_override("REMOTE_BROWSER_GUEST_TEST_STATUS_PATH", STATUS_PATH))
        self.tailscale_bin = self._test_override("REMOTE_BROWSER_GUEST_TEST_TAILSCALE_BIN", TAILSCALE_BIN)
        self.setpriv_bin = self._test_override("REMOTE_BROWSER_GUEST_TEST_SETPRIV_BIN", SETPRIV_BIN)
        self.session_bin = self._test_override("REMOTE_BROWSER_GUEST_TEST_SESSION_BIN", SESSION_BIN)
        self.allowed_uid = int(self._test_override("REMOTE_BROWSER_GUEST_TEST_ALLOWED_UID", str(CODEX_UID)))
        self.allow_root_peer = self.test_mode and _bool_env("REMOTE_BROWSER_GUEST_TEST_ALLOW_ROOT_PEER")
        self.owner_uid = 0 if os.geteuid() == 0 else os.geteuid()
        self.owner_gid = int(self._test_override("REMOTE_BROWSER_GUEST_TEST_OWNER_GID", str(CODEX_GID)))

        self.ttl = float(self._test_override("REMOTE_BROWSER_GUEST_TEST_TTL", str(PRODUCTION_TTL)))
        self.io_timeout = float(self._test_override("REMOTE_BROWSER_GUEST_TEST_IO_TIMEOUT", "2.0"))
        self.command_timeout = float(self._test_override("REMOTE_BROWSER_GUEST_TEST_COMMAND_TIMEOUT", "4.0"))
        self.ready_timeout = float(self._test_override("REMOTE_BROWSER_GUEST_TEST_READY_TIMEOUT", "10.0"))
        self.funnel_timeout = float(self._test_override("REMOTE_BROWSER_GUEST_TEST_FUNNEL_TIMEOUT", "30.0"))
        self.cleanup_timeout = float(self._test_override("REMOTE_BROWSER_GUEST_TEST_CLEANUP_TIMEOUT", "10.0"))
        self.poll_interval = float(self._test_override("REMOTE_BROWSER_GUEST_TEST_POLL_INTERVAL", "0.25"))
        if not self.test_mode and self.ttl != PRODUCTION_TTL:
            raise RuntimeError("production guest TTL is fixed")
        if self.ttl <= 0 or min(self.io_timeout, self.command_timeout, self.ready_timeout, self.funnel_timeout, self.cleanup_timeout, self.poll_interval) <= 0:
            raise RuntimeError("invalid broker timing configuration")

        self.enabled = _bool_env("REMOTE_BROWSER_GUEST_ACCESS_ENABLED", False)
        deployment_mode = os.environ.get("REMOTE_BROWSER_DEPLOYMENT_MODE", "").strip().lower()
        self.edge_mode = any(
            _bool_env(name)
            for name in (
                "REMOTE_BROWSER_EDGE_COMPAT",
                "REMOTE_BROWSER_CODEXGUI_EDGE_MODE",
                "CODEXGUI_EDGE_MODE",
                "REMOTE_CHROME_EDGE_MODE",
            )
        ) or deployment_mode in {"edge", "codexgui", "codexgui-edge"}

        self.state = "CLOSED"
        self.redeemed = False
        self.expires_at: str | None = None
        self._deadline: float | None = None
        self._link_token: str | None = None
        self._session_token: str | None = None
        self._session: subprocess.Popen[str] | None = None
        self._funnel: subprocess.Popen[str] | None = None
        self._ready = threading.Event()
        self._shutdown = threading.Event()
        self._closing = False
        self._cleanup_scheduled = False
        self._pending_redeemed = False
        self._state_lock = threading.RLock()
        self._operation_lock = threading.Lock()
        self._server: socket.socket | None = None
        self._write_status()

    def _test_override(self, name: str, production_value: str) -> str:
        if self.test_mode and name in os.environ:
            return os.environ[name]
        return production_value

    @staticmethod
    def _minimal_env() -> dict[str, str]:
        return {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}

    def _safe_chown(self, path: Path) -> None:
        try:
            os.chown(path, self.owner_uid, self.owner_gid)
        except PermissionError:
            if not self.test_mode:
                raise

    def _write_status(self) -> None:
        with self._state_lock:
            document = {"state": self.state, "expiresAt": self.expires_at, "redeemed": self.redeemed}
        self.status_path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        try:
            self._safe_chown(self.status_path.parent)
        except OSError:
            if not self.test_mode:
                raise
        fd, temporary = tempfile.mkstemp(prefix=".guest-status.", dir=self.status_path.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(_compact_json(document))
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o440)
            self._safe_chown(Path(temporary))
            os.replace(temporary, self.status_path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    def _set_state(self, state: str, *, redeemed: bool | None = None) -> None:
        if state not in STATES:
            raise RuntimeError("invalid internal state")
        with self._state_lock:
            self.state = state
            if redeemed is not None:
                self.redeemed = redeemed
        self._write_status()

    def _run_json(self, args: list[str]) -> Any:
        try:
            result = subprocess.run(
                args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                errors="strict",
                timeout=self.command_timeout,
                check=False,
                env=self._minimal_env(),
            )
            if result.returncode != 0 or len(result.stdout.encode("utf-8")) > 1024 * 1024:
                raise BrokerError("Tailscale status is unavailable")
            return json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, UnicodeError, json.JSONDecodeError) as exc:
            raise BrokerError("Tailscale status is unavailable") from exc

    def _tailscale_status(self) -> tuple[str, Any]:
        status = self._run_json([self.tailscale_bin, f"--socket={TAILSCALE_SOCKET}", "status", "--json"])
        if not isinstance(status, dict) or status.get("BackendState") != "Running":
            raise BrokerError("Tailscale is not running")
        self_value = status.get("Self")
        dns_name = self_value.get("DNSName") if isinstance(self_value, dict) else None
        if not isinstance(dns_name, str):
            raise BrokerError("Tailscale DNS name is unavailable")
        dns_name = dns_name.rstrip(".")
        if not _DNS_RE.fullmatch(dns_name):
            raise BrokerError("Tailscale DNS name is unavailable")
        magic_dns_suffix = status.get("MagicDNSSuffix")
        if not isinstance(magic_dns_suffix, str) or not magic_dns_suffix:
            raise BrokerError("Tailscale MagicDNS is not enabled")
        magic_dns_suffix = magic_dns_suffix.rstrip(".")
        if not _DNS_RE.fullmatch(magic_dns_suffix) or not dns_name.endswith(f".{magic_dns_suffix}"):
            raise BrokerError("Tailscale MagicDNS is not enabled")
        funnel = self._run_json([self.tailscale_bin, f"--socket={TAILSCALE_SOCKET}", "funnel", "status", "--json"])
        if not isinstance(funnel, dict):
            raise BrokerError("Tailscale Funnel status is unavailable")
        return dns_name, funnel

    def _funnel_status(self) -> Any:
        value = self._run_json([self.tailscale_bin, f"--socket={TAILSCALE_SOCKET}", "funnel", "status", "--json"])
        if not isinstance(value, dict):
            raise BrokerError("Tailscale Funnel status is unavailable")
        return value

    def _public_addresses(self, dns_name: str) -> list[str]:
        labels = dns_name.encode("ascii").split(b".")
        if any(not label or len(label) > 63 for label in labels):
            return []
        question = b"".join(bytes([len(label)]) + label for label in labels) + b"\0"
        transaction = secrets.randbits(16)
        query = struct.pack("!HHHHHH", transaction, 0x0100, 1, 0, 0, 0) + question + struct.pack("!HH", 1, 1)
        for resolver in ("8.8.8.8", "1.1.1.1"):
            client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                client.settimeout(min(self.command_timeout, 2.0))
                client.sendto(query, (resolver, 53))
                packet, _ = client.recvfrom(4096)
            except OSError:
                continue
            finally:
                client.close()
            try:
                if len(packet) < 12:
                    continue
                response_id, flags, questions, answers, _, _ = struct.unpack("!HHHHHH", packet[:12])
                if response_id != transaction or flags & 0x000F or questions != 1:
                    continue
                offset = _dns_name_end(packet, 12)
                offset += 4
                addresses: list[str] = []
                for _index in range(answers):
                    offset = _dns_name_end(packet, offset)
                    if offset + 10 > len(packet):
                        raise BrokerError("Public Funnel DNS is unavailable")
                    record_type, record_class, _ttl, length = struct.unpack("!HHIH", packet[offset : offset + 10])
                    offset += 10
                    if offset + length > len(packet):
                        raise BrokerError("Public Funnel DNS is unavailable")
                    if record_type == 1 and record_class == 1 and length == 4:
                        addresses.append(socket.inet_ntop(socket.AF_INET, packet[offset : offset + length]))
                    offset += length
                if addresses:
                    return addresses
            except (BrokerError, OSError, struct.error):
                continue
        return []

    def _public_funnel_ready(self, dns_name: str, link_token: str) -> bool:
        request = (
            f"GET /guest/?token={link_token} HTTP/1.1\r\n"
            f"Host: {dns_name}:{GUEST_PORT}\r\n"
            "Connection: close\r\n"
            "Accept: text/html\r\n\r\n"
        ).encode("ascii")
        context = ssl.create_default_context()
        for address in self._public_addresses(dns_name):
            raw: socket.socket | None = None
            wrapped: ssl.SSLSocket | None = None
            try:
                raw = socket.create_connection((address, GUEST_PORT), timeout=min(self.command_timeout, 3.0))
                wrapped = context.wrap_socket(raw, server_hostname=dns_name)
                wrapped.settimeout(min(self.command_timeout, 3.0))
                wrapped.sendall(request)
                response = bytearray()
                while len(response) <= 128 * 1024:
                    chunk = wrapped.recv(16384)
                    if not chunk:
                        break
                    response.extend(chunk)
                if response.startswith(b"HTTP/1.1 200") and b"/guest/redeem.js" in response:
                    return True
            except (OSError, ssl.SSLError):
                pass
            finally:
                if wrapped is not None:
                    wrapped.close()
                elif raw is not None:
                    raw.close()
        return False

    def initialize(self) -> None:
        """Inspect port ownership once before accepting requests."""
        try:
            _, funnel = self._tailscale_status()
        except BrokerError:
            self._set_state("BLOCKED", redeemed=False)
            return
        if _port_is_configured(funnel):
            self._set_state("BLOCKED", redeemed=False)
        else:
            self._set_state("CLOSED", redeemed=False)

    def _status_response(self) -> dict[str, object]:
        with self._state_lock:
            return {"ok": True, "state": self.state, "expiresAt": self.expires_at, "redeemed": self.redeemed}

    def _error(self, message: str) -> dict[str, object]:
        with self._state_lock:
            return {"ok": False, "error": message, "state": self.state}

    def handle_request(self, request: Any) -> dict[str, object]:
        if not isinstance(request, dict) or set(request) != {"action"} or not isinstance(request.get("action"), str):
            return self._error("Invalid request")
        action = request["action"]
        if action == "status":
            return self._status_response()
        if action == "create":
            return self.create()
        if action == "revoke":
            return self.revoke()
        return self._error("Invalid action")

    def create(self) -> dict[str, object]:
        with self._operation_lock:
            if not self.enabled:
                return self._error("Guest access is disabled")
            if self.edge_mode:
                return self._error("Guest access is unavailable in edge mode")
            with self._state_lock:
                current_state = self.state
            if current_state == "BLOCKED":
                try:
                    _, blocked_status = self._tailscale_status()
                except BrokerError:
                    return self._error("Guest access is blocked")
                if _port_is_configured(blocked_status):
                    return self._error("Guest access is blocked")
                self._set_state("CLOSED", redeemed=False)
                current_state = "CLOSED"
            if current_state != "CLOSED":
                return self._error("Guest access is already active")

            self._set_state("STARTING", redeemed=False)
            try:
                dns_name, funnel_status = self._tailscale_status()
                if _port_is_configured(funnel_status):
                    self._set_state("BLOCKED", redeemed=False)
                    return self._error("Guest access is blocked")

                link_token = secrets.token_urlsafe(32)
                session_token = secrets.token_urlsafe(32)
                if link_token == session_token:
                    session_token = secrets.token_urlsafe(32)
                    if link_token == session_token:
                        raise BrokerError("Guest session could not be created")

                started_wall = time.time()
                deadline = time.monotonic() + self.ttl
                expires_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started_wall + self.ttl))
                expires_at_ms = int((started_wall + self.ttl) * 1000)
                public_origin = f"https://{dns_name}:{GUEST_PORT}"
                config = {
                    "linkToken": link_token,
                    "sessionToken": session_token,
                    "expiresAt": expires_at_ms,
                    "publicOrigin": public_origin,
                    "listenHost": "127.0.0.1",
                    "listenPort": PROXY_PORT,
                    "upstreamHost": UPSTREAM_HOST,
                    "upstreamPort": UPSTREAM_PORT,
                }

                self._ready.clear()
                self._closing = False
                self._pending_redeemed = False
                self._session = subprocess.Popen(
                    [
                        self.setpriv_bin,
                        "--pdeathsig",
                        "TERM",
                        f"--reuid={GUEST_UID}",
                        f"--regid={GUEST_GID}",
                        "--clear-groups",
                        "--no-new-privs",
                        "--reset-env",
                        self.session_bin,
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    encoding="utf-8",
                    errors="strict",
                    bufsize=1,
                    close_fds=True,
                    start_new_session=True,
                    env=self._minimal_env(),
                )
                assert self._session.stdin is not None
                self._session.stdin.write(json.dumps(config, separators=(",", ":")) + "\n")
                self._session.stdin.flush()
                threading.Thread(target=self._event_loop, args=(self._session,), daemon=True, name="guest-session-events").start()

                ready_until = time.monotonic() + self.ready_timeout
                while not self._ready.wait(min(self.poll_interval, max(0.0, ready_until - time.monotonic()))):
                    if self._session.poll() is not None or time.monotonic() >= ready_until:
                        raise BrokerError("Guest session could not be created")
                if self._session.poll() is not None:
                    raise BrokerError("Guest session could not be created")

                self._funnel = subprocess.Popen(
                    [
                        self.setpriv_bin,
                        "--pdeathsig",
                        "TERM",
                        self.tailscale_bin,
                        f"--socket={TAILSCALE_SOCKET}",
                        "funnel",
                        "--yes",
                        f"--https={GUEST_PORT}",
                        PROXY_TARGET,
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    close_fds=True,
                    start_new_session=True,
                    env=self._minimal_env(),
                )

                funnel_until = time.monotonic() + self.funnel_timeout
                while True:
                    if self._session.poll() is not None or self._funnel.poll() is not None:
                        raise BrokerError("Guest session could not be created")
                    try:
                        current = self._funnel_status()
                    except BrokerError:
                        current = None
                    if current is not None and _exact_funnel_config(current, dns_name) and \
                            self._public_funnel_ready(dns_name, link_token):
                        break
                    if time.monotonic() >= funnel_until:
                        raise BrokerError("Guest session could not be created")
                    time.sleep(self.poll_interval)

                with self._state_lock:
                    self._link_token = link_token
                    self._session_token = session_token
                    self._deadline = deadline
                    self.expires_at = expires_at
                self._set_state("ISSUED", redeemed=False)
                with self._state_lock:
                    pending_redeemed = self._pending_redeemed
                if pending_redeemed:
                    self._set_state("REDEEMED", redeemed=True)
                guest_url = f"{public_origin}/guest/?token={link_token}"
                return {
                    "ok": True,
                    "state": "REDEEMED" if pending_redeemed else "ISSUED",
                    "guestUrl": guest_url,
                    "expiresAt": expires_at,
                }
            except (BrokerError, OSError, subprocess.SubprocessError, UnicodeError, BrokenPipeError):
                self._cleanup_locked()
                return self._error("Guest session could not be created")

    def _event_loop(self, process: subprocess.Popen[str]) -> None:
        assert process.stdout is not None
        try:
            for raw_line in process.stdout:
                event = raw_line.strip()
                if event == "READY":
                    self._ready.set()
                elif event == "REDEEMED":
                    with self._state_lock:
                        if process is self._session and self.state == "STARTING":
                            self._pending_redeemed = True
                        elif process is self._session and self.state == "ISSUED":
                            self.state = "REDEEMED"
                            self.redeemed = True
                            self._write_status()
                elif event == "EXPIRED":
                    self._schedule_cleanup()
                    return
        except (OSError, UnicodeError):
            pass
        finally:
            with self._state_lock:
                unexpected = process is self._session and not self._closing and self.state in {"STARTING", "ISSUED", "REDEEMED"}
            if unexpected:
                self._schedule_cleanup()

    def _schedule_cleanup(self) -> None:
        with self._state_lock:
            if self._cleanup_scheduled:
                return
            self._cleanup_scheduled = True

        def cleanup() -> None:
            try:
                with self._operation_lock:
                    self._cleanup_locked()
            finally:
                with self._state_lock:
                    self._cleanup_scheduled = False

        threading.Thread(target=cleanup, daemon=True, name="guest-cleanup").start()

    def _stop_process(self, process: subprocess.Popen[Any] | None, deadline: float) -> None:
        if process is None or process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            try:
                process.terminate()
            except ProcessLookupError:
                return
        remaining = max(0.0, deadline - time.monotonic())
        try:
            process.wait(timeout=remaining)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            try:
                process.kill()
            except ProcessLookupError:
                return
        try:
            process.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass

    @staticmethod
    def _close_process_streams(process: subprocess.Popen[Any] | None) -> None:
        if process is None:
            return
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass

    def _cleanup_locked(self) -> bool:
        with self._state_lock:
            if self.state == "CLOSED" and self._session is None and self._funnel is None:
                return True
            self._closing = True
        self._set_state("CLOSING")
        deadline = time.monotonic() + self.cleanup_timeout

        if self._session is not None and self._session.stdin is not None:
            try:
                self._session.stdin.close()
            except OSError:
                pass
        self._stop_process(self._funnel, deadline)
        self._stop_process(self._session, deadline)

        self._close_process_streams(self._funnel)
        self._close_process_streams(self._session)

        clean = False
        while time.monotonic() < deadline:
            try:
                if not _port_is_configured(self._funnel_status()):
                    clean = True
                    break
            except BrokerError:
                pass
            time.sleep(self.poll_interval)

        with self._state_lock:
            self._session = None
            self._funnel = None
            self._deadline = None
            self._link_token = None
            self._session_token = None
            self.expires_at = None
            self.redeemed = False
            self._closing = False
            self._pending_redeemed = False
        self._set_state("CLOSED" if clean else "BLOCKED", redeemed=False)
        return clean

    def revoke(self) -> dict[str, object]:
        with self._operation_lock:
            with self._state_lock:
                current = self.state
            if current == "BLOCKED":
                return self._error("Guest access is blocked")
            if current == "CLOSED":
                return {"ok": True, "state": "CLOSED"}
            if not self._cleanup_locked():
                return self._error("Guest access cleanup could not be verified")
            return {"ok": True, "state": "CLOSED"}

    def _monitor(self) -> None:
        while not self._shutdown.wait(self.poll_interval):
            with self._state_lock:
                active = self.state in {"ISSUED", "REDEEMED"}
                expired = self._deadline is not None and time.monotonic() >= self._deadline
                child_failed = active and (
                    self._session is None
                    or self._funnel is None
                    or self._session.poll() is not None
                    or self._funnel.poll() is not None
                )
            if expired or child_failed:
                self._schedule_cleanup()

    def _peer_uid(self, connection: socket.socket) -> int:
        if not sys.platform.startswith("linux") or not hasattr(socket, "SO_PEERCRED"):
            raise BrokerError("Peer credentials are unavailable")
        raw = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _, uid, _ = struct.unpack("3i", raw)
        return uid

    def _read_frame(self, connection: socket.socket) -> Any:
        connection.settimeout(self.io_timeout)
        received = bytearray()
        while True:
            chunk = connection.recv(min(1024, MAX_FRAME + 2 - len(received)))
            if not chunk:
                raise BrokerError("Invalid request")
            received.extend(chunk)
            newline = received.find(b"\n")
            if newline >= 0:
                if newline > MAX_FRAME or received[newline + 1 :]:
                    raise BrokerError("Invalid request")
                payload = bytes(received[:newline])
                break
            if len(received) > MAX_FRAME:
                raise BrokerError("Invalid request")
        try:
            return json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise BrokerError("Invalid request") from exc

    def _serve_connection(self, connection: socket.socket) -> None:
        with connection:
            try:
                peer_uid = self._peer_uid(connection)
                if peer_uid != self.allowed_uid and not (peer_uid == 0 and self.allow_root_peer):
                    response = self._error("Unauthorized peer")
                else:
                    response = self.handle_request(self._read_frame(connection))
            except (BrokerError, OSError, socket.timeout):
                response = self._error("Invalid request")
            try:
                connection.sendall(_compact_json(response))
            except OSError:
                pass

    def _prepare_socket_path(self) -> None:
        self.socket_path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        self._safe_chown(self.socket_path.parent)
        try:
            info = self.socket_path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISSOCK(info.st_mode):
            raise RuntimeError("guest control path exists and is not a socket")
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.2)
            probe.connect(str(self.socket_path))
        except OSError:
            self.socket_path.unlink()
        else:
            raise RuntimeError("guest control socket is already active")
        finally:
            probe.close()

    def serve_forever(self) -> None:
        self.initialize()
        self._prepare_socket_path()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server = server
        server.bind(str(self.socket_path))
        os.chmod(self.socket_path, 0o660)
        self._safe_chown(self.socket_path)
        server.listen(16)
        server.settimeout(0.5)
        threading.Thread(target=self._monitor, daemon=True, name="guest-monitor").start()
        while not self._shutdown.is_set():
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                if self._shutdown.is_set():
                    break
                raise
            worker = threading.Thread(target=self._serve_connection, args=(connection,), daemon=True)
            worker.start()

    def shutdown(self) -> None:
        self._shutdown.set()
        if self._server is not None:
            try:
                self._server.close()
            except OSError:
                pass
        with self._operation_lock:
            with self._state_lock:
                needs_cleanup = self.state in {"STARTING", "ISSUED", "REDEEMED", "CLOSING"}
            if needs_cleanup:
                self._cleanup_locked()
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Remote-browser guest access broker")
    parser.parse_args()
    broker = GuestAccessBroker()

    def stop(_signum: int, _frame: object) -> None:
        broker._shutdown.set()
        if broker._server is not None:
            try:
                broker._server.close()
            except OSError:
                pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        broker.serve_forever()
    finally:
        broker.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
