#!/usr/bin/env python3
"""Isolated tests for the root guest-access broker.

All subprocesses are local fakes.  The suite never changes a real Tailscale
configuration and never opens a public listener.
"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import stat
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
BROKER_PATH = ROOT / "lib" / "remote-browser" / "guest-access-broker.py"
SPEC = importlib.util.spec_from_file_location("guest_access_broker", BROKER_PATH)
assert SPEC and SPEC.loader
broker_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(broker_module)


def executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class Fixture:
    def __init__(
        self,
        directory: Path,
        *,
        stale: bool = False,
        fail_funnel: bool = False,
        redeem: bool = False,
        backend_state: str = "Running",
    ) -> None:
        self.directory = directory
        self.state = directory / "funnel-state.json"
        self.log = directory / "arguments.jsonl"
        self.config = directory / "session-config.json"
        self.tailscale = directory / "tailscale"
        self.setpriv = directory / "setpriv"
        self.session = directory / "session"
        self.state.write_text(json.dumps({"active": stale, "backend": backend_state}), encoding="utf-8")
        self.log.write_text("", encoding="utf-8")

        executable(
            self.tailscale,
            f'''#!/usr/bin/env python3
import json, os, signal, sys, time
state_path = {str(self.state)!r}
log_path = {str(self.log)!r}
fail_funnel = {fail_funnel!r}
args = sys.argv[1:]
with open(log_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(["tailscale", *args]) + "\\n")
def read_state():
    try:
        with open(state_path, encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return {{"active": False, "backend": "NeedsLogin"}}
def write_state(active):
    current = read_state()
    temporary = state_path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump({{"active": active, "backend": current.get("backend", "NeedsLogin")}}, handle)
    os.replace(temporary, state_path)
def status():
    if read_state().get("active"):
        return {{"Foreground": {{
            "test-session": {{
                "TCP": {{"10000": {{"HTTPS": True}}}},
                "Web": {{"device.example.ts.net:10000": {{"Handlers": {{"/": {{"Proxy": "http://127.0.0.1:8444"}}}}}}}},
                "AllowFunnel": {{"device.example.ts.net:10000": True}}
            }}
        }}}}
    return {{}}
if args[-2:] == ["status", "--json"] and "funnel" not in args:
    print(json.dumps({{"BackendState": read_state().get("backend"), "MagicDNSSuffix": "example.ts.net", "Self": {{"DNSName": "device.example.ts.net."}}}}))
    raise SystemExit(0)
if len(args) >= 3 and args[1:4] == ["funnel", "status", "--json"]:
    print(json.dumps(status()))
    raise SystemExit(0)
if len(args) >= 3 and args[1:3] == ["debug", "netmap"]:
    funnel = ["https://device.example.ts.net:10000"] if read_state().get("active") else None
    print(json.dumps({{"SelfNode": {{"Funnel": funnel}}}}))
    raise SystemExit(0)
if "funnel" in args and "--https=10000" in args:
    if fail_funnel:
        raise SystemExit(2)
    write_state(True)
    def stop(*_):
        write_state(False)
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True:
        time.sleep(0.1)
raise SystemExit(2)
''',
        )
        executable(
            self.setpriv,
            f'''#!/usr/bin/env python3
import json, os, sys
with open({str(self.log)!r}, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(["setpriv", *sys.argv[1:]]) + "\\n")
command_index = next(
    index for index, argument in enumerate(sys.argv[3:], start=3)
    if not argument.startswith("-")
)
os.execv(sys.argv[command_index], sys.argv[command_index:])
''',
        )
        executable(
            self.session,
            f'''#!/usr/bin/env python3
import json, sys, time
line = sys.stdin.readline()
with open({str(self.config)!r}, "w", encoding="utf-8") as handle:
    json.dump(json.loads(line), handle)
print("READY", flush=True)
if {redeem!r}:
    time.sleep(0.2)
    print("REDEEMED", flush=True)
for _line in sys.stdin:
    pass
''',
        )

    def env(self, *, ttl: float = 2.0) -> dict[str, str]:
        return {
            "REMOTE_BROWSER_GUEST_TEST_MODE": "true",
            "REMOTE_BROWSER_GUEST_ACCESS_ENABLED": "true",
            "REMOTE_BROWSER_GUEST_TEST_SOCKET_PATH": str(self.directory / "control.sock"),
            "REMOTE_BROWSER_GUEST_TEST_STATUS_PATH": str(self.directory / "status.json"),
            "REMOTE_BROWSER_GUEST_TEST_TAILSCALE_BIN": str(self.tailscale),
            "REMOTE_BROWSER_GUEST_TEST_SETPRIV_BIN": str(self.setpriv),
            "REMOTE_BROWSER_GUEST_TEST_SESSION_BIN": str(self.session),
            "REMOTE_BROWSER_GUEST_TEST_ALLOWED_UID": str(os.getuid()),
            "REMOTE_BROWSER_GUEST_TEST_OWNER_GID": str(os.getgid()),
            "REMOTE_BROWSER_GUEST_TEST_TTL": str(ttl),
            "REMOTE_BROWSER_GUEST_TEST_IO_TIMEOUT": "0.2",
            "REMOTE_BROWSER_GUEST_TEST_COMMAND_TIMEOUT": "0.5",
            "REMOTE_BROWSER_GUEST_TEST_READY_TIMEOUT": "1.5",
            "REMOTE_BROWSER_GUEST_TEST_FUNNEL_TIMEOUT": "1.5",
            "REMOTE_BROWSER_GUEST_TEST_CLEANUP_TIMEOUT": "1.5",
            "REMOTE_BROWSER_GUEST_TEST_POLL_INTERVAL": "0.02",
        }

    def calls(self) -> list[list[str]]:
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]


class GuestAccessBrokerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_broker(self, fixture: Fixture, *, ttl: float = 2.0):
        with mock.patch.dict(os.environ, fixture.env(ttl=ttl), clear=True):
            instance = broker_module.GuestAccessBroker()
        instance.initialize()
        instance._public_funnel_ready = mock.Mock(return_value=True)
        return instance

    def test_success_nested_foreground_exact_args_and_secret_free_status(self) -> None:
        fixture = Fixture(self.directory)
        instance = self.make_broker(fixture)
        response = instance.handle_request({"action": "create"})
        self.assertTrue(response["ok"])
        self.assertEqual(response["state"], "ISSUED")
        self.assertRegex(response["guestUrl"], r"^https://device\.example\.ts\.net:10000/guest/\?token=[A-Za-z0-9_-]{40,}$")

        config = json.loads(fixture.config.read_text(encoding="utf-8"))
        self.assertNotEqual(config["linkToken"], config["sessionToken"])
        self.assertEqual(config["publicOrigin"], "https://device.example.ts.net:10000")
        self.assertEqual(config["listenHost"], "127.0.0.1")
        self.assertEqual(config["listenPort"], 8444)
        self.assertEqual(config["upstreamHost"], "127.0.0.2")
        self.assertEqual(config["upstreamPort"], 6081)

        calls = fixture.calls()
        self.assertIn(
            ["tailscale", "--socket=/run/tailscale/tailscaled.sock", "funnel", "--yes", "--https=10000", "http://127.0.0.1:8444"],
            calls,
        )
        self.assertIn(
            [
                "setpriv", "--pdeathsig", "TERM", "--reuid=10002", "--regid=10002",
                "--clear-groups", "--no-new-privs", "--reset-env", str(fixture.session),
            ],
            calls,
        )
        self.assertIn(
            [
                "setpriv", "--pdeathsig", "TERM", str(fixture.tailscale),
                "--socket=/run/tailscale/tailscaled.sock", "funnel", "--yes",
                "--https=10000", "http://127.0.0.1:8444",
            ],
            calls,
        )
        self.assertFalse(any("funnel" in call and "reset" in call for call in calls))

        status_text = (self.directory / "status.json").read_text(encoding="utf-8")
        self.assertNotIn(config["linkToken"], status_text)
        self.assertNotIn(config["sessionToken"], status_text)
        self.assertNotIn("guestUrl", status_text)
        self.assertEqual(stat.S_IMODE((self.directory / "status.json").stat().st_mode), 0o440)
        self.assertEqual(set(json.loads(status_text)), {"state", "expiresAt", "redeemed"})
        self.assertEqual(instance.revoke(), {"ok": True, "state": "CLOSED"})

    def test_strict_schema_and_frame_bound(self) -> None:
        fixture = Fixture(self.directory)
        instance = self.make_broker(fixture)
        for request in ({}, {"action": "create", "port": 1}, {"action": 1}, [], None):
            response = instance.handle_request(request)
            self.assertFalse(response["ok"])
            self.assertNotIn("guestUrl", response)

        left, right = socket.socketpair()
        try:
            right.sendall(b"x" * (broker_module.MAX_FRAME + 1))
            with self.assertRaises(broker_module.BrokerError):
                instance._read_frame(left)
        finally:
            left.close()
            right.close()

    def test_funnel_verification_does_not_combine_separate_configs(self) -> None:
        split = {
            "Foreground": {
                "tcp": {"TCP": {"10000": {"HTTPS": True}}},
                "web": {
                    "Web": {
                        "device.example.ts.net:10000": {
                            "Handlers": {"/": {"Proxy": "http://127.0.0.1:8444"}}
                        }
                    }
                },
                "allow": {"AllowFunnel": {"device.example.ts.net:10000": True}},
            }
        }
        self.assertFalse(broker_module._exact_funnel_config(split, "device.example.ts.net"))

    def test_create_race_has_one_winner(self) -> None:
        fixture = Fixture(self.directory)
        instance = self.make_broker(fixture)
        barrier = threading.Barrier(3)
        results: list[dict[str, object]] = []

        def create() -> None:
            barrier.wait()
            results.append(instance.create())

        threads = [threading.Thread(target=create) for _ in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join()
        self.assertEqual(sum(result["ok"] is True for result in results), 1)
        self.assertEqual(sum("guestUrl" in result for result in results), 1)
        instance.revoke()

    def test_redeemed_event_and_ttl_cleanup(self) -> None:
        fixture = Fixture(self.directory, redeem=True)
        instance = self.make_broker(fixture, ttl=2.0)
        self.assertTrue(instance.create()["ok"])
        monitor = threading.Thread(target=instance._monitor, daemon=True)
        monitor.start()
        deadline = time.monotonic() + 5.0
        saw_redeemed = False
        while time.monotonic() < deadline:
            saw_redeemed |= instance._status_response()["state"] == "REDEEMED"
            if instance._status_response()["state"] == "CLOSED":
                break
            time.sleep(0.01)
        instance._shutdown.set()
        self.assertTrue(saw_redeemed)
        self.assertEqual(instance._status_response(), {"ok": True, "state": "CLOSED", "expiresAt": None, "redeemed": False})
        self.assertFalse(json.loads(fixture.state.read_text(encoding="utf-8"))["active"])

    def test_funnel_failure_returns_no_url_and_cleans_up(self) -> None:
        fixture = Fixture(self.directory, fail_funnel=True)
        instance = self.make_broker(fixture)
        response = instance.create()
        self.assertFalse(response["ok"])
        self.assertNotIn("guestUrl", response)
        self.assertEqual(response["state"], "CLOSED")

    def test_stale_10000_blocks_without_reset(self) -> None:
        fixture = Fixture(self.directory, stale=True)
        instance = self.make_broker(fixture)
        self.assertEqual(instance._status_response()["state"], "BLOCKED")
        response = instance.create()
        self.assertFalse(response["ok"])
        self.assertNotIn("guestUrl", response)
        self.assertFalse(any("funnel" in call and "reset" in call for call in fixture.calls()))

    def test_startup_needs_login_recovers_only_after_running_and_free(self) -> None:
        fixture = Fixture(self.directory, backend_state="NeedsLogin")
        instance = self.make_broker(fixture)
        self.assertEqual(instance._status_response()["state"], "BLOCKED")
        unavailable = instance.create()
        self.assertFalse(unavailable["ok"])
        self.assertNotIn("guestUrl", unavailable)

        fixture.state.write_text(json.dumps({"active": False, "backend": "Running"}), encoding="utf-8")
        recovered = instance.create()
        self.assertTrue(recovered["ok"])
        self.assertEqual(recovered["state"], "ISSUED")
        self.assertEqual(instance.revoke(), {"ok": True, "state": "CLOSED"})

    def test_edge_mode_and_disabled_are_fail_closed(self) -> None:
        fixture = Fixture(self.directory)
        env = fixture.env()
        env["REMOTE_BROWSER_EDGE_COMPAT"] = "true"
        with mock.patch.dict(os.environ, env, clear=True):
            edge = broker_module.GuestAccessBroker()
        edge.initialize()
        self.assertEqual(edge.create()["error"], "Guest access is unavailable in edge mode")

        env["REMOTE_BROWSER_EDGE_COMPAT"] = "false"
        env["REMOTE_BROWSER_GUEST_ACCESS_ENABLED"] = "false"
        with mock.patch.dict(os.environ, env, clear=True):
            disabled = broker_module.GuestAccessBroker()
        disabled.initialize()
        self.assertEqual(disabled.create()["error"], "Guest access is disabled")

    def test_missing_magicdns_fails_before_funnel_configuration(self) -> None:
        fixture = Fixture(self.directory)
        instance = self.make_broker(fixture)
        with mock.patch.object(instance, "_run_json", return_value={
            "BackendState": "Running",
            "MagicDNSSuffix": "",
            "Self": {"DNSName": "device.example.ts.net."},
        }):
            with self.assertRaisesRegex(broker_module.BrokerError, "MagicDNS"):
                instance._tailscale_status()

    def test_public_funnel_readiness_fails_closed(self) -> None:
        fixture = Fixture(self.directory)
        instance = self.make_broker(fixture)
        instance._public_funnel_ready = broker_module.GuestAccessBroker._public_funnel_ready.__get__(instance)
        instance._public_addresses = mock.Mock(return_value=[])
        self.assertFalse(instance._public_funnel_ready("device.example.ts.net", "x" * 43))

    @unittest.skipUnless(os.name == "posix" and hasattr(socket, "SO_PEERCRED"), "Linux SO_PEERCRED required")
    def test_peer_credentials_are_kernel_supplied(self) -> None:
        if not __import__("sys").platform.startswith("linux"):
            self.skipTest("Linux SO_PEERCRED required")
        fixture = Fixture(self.directory)
        instance = self.make_broker(fixture)
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.assertEqual(instance._peer_uid(left), os.getuid())
        finally:
            left.close()
            right.close()


if __name__ == "__main__":
    unittest.main()
