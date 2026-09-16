"""HTTP and WebSocket integration coverage for the AWM browser server.

Run with: python3 tests/test_server.py
Set AWM_SERVER_BIN to test an existing binary instead of compiling one.
The test server uses temporary assets, a free loopback port, and real timers.
"""
import contextlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class BrowserServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="awm http tests ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.web = cls.root / "browser assets"
        cls.web.mkdir()
        (cls.web / "awm.html").write_text(
            '<!doctype html><title>AWM</title><body>'
            '<script async type="text/javascript" src="awm.js"></script>'
            '</body>'
        )
        (cls.web / "awm.wasm").write_bytes(b"\x00asm\x01\x00\x00\x00")
        (cls.web / "awm.data").write_bytes(b"asset bundle")
        (cls.web / "awm.js").write_text("var Module = {};")
        (cls.root / "secret.txt").write_text("outside asset root")
        (cls.web / "linked.txt").symlink_to(cls.root / "secret.txt")
        (cls.web / "linked-dir").symlink_to(cls.root, target_is_directory=True)
        cls.binary = Path(os.environ.get("AWM_SERVER_BIN", cls.root / "awmserver"))
        if not os.environ.get("AWM_SERVER_BIN"):
            subprocess.run(
                [os.environ.get("NIM", "nim"), "c", "--hints:off",
                 f"--nimcache:{cls.root / 'nimcache'}",
                 f"--out:{cls.binary}", "awmserver.nim"],
                cwd=PROJECT, check=True,
            )

    @contextlib.contextmanager
    def server(self, *options):
        """Start the server and yield (port, stdout_text).

        The server's stdout is captured so tests can extract tokens.
        """
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            port = available.getsockname()[1]
        process = subprocess.Popen(
            [str(self.binary), "--port", str(port), "--web-dir", str(self.web),
             *options], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 10
            lines = b""
            while True:
                if process.poll() is not None:
                    self.fail(process.stdout.read().decode())
                try:
                    self.request(port, "/api/health")
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        self.fail("Server did not start")
                    time.sleep(0.02)
            yield port, process
        finally:
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()

    @staticmethod
    def request(port, path, method="GET"):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            connection.request(method, path)
            response = connection.getresponse()
            return response.status, response.headers, response.read()
        finally:
            connection.close()

    def read_stdout_lines(self, process, max_lines=20):
        """Non-blocking read of available stdout."""
        import select
        lines = []
        fd = process.stdout.fileno()
        while len(lines) < max_lines:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                break
            line = process.stdout.readline()
            if not line:
                break
            lines.append(line.decode().strip())
        return lines

    def extract_player_url(self, process, player_num):
        """Read startup lines and extract the player URL with token."""
        deadline = time.monotonic() + 3
        lines = []
        while time.monotonic() < deadline:
            line = process.stdout.readline()
            if not line:
                time.sleep(0.01)
                continue
            text = line.decode().strip()
            lines.append(text)
            if f"Player {player_num}:" in text and "token=" in text:
                match = re.search(r'(http://[^\s]+)', text)
                if match:
                    return match.group(1)
            if len(lines) > 20:
                break
        self.fail(f"Could not find Player {player_num} URL in: {lines}")

    def snapshot(self, port):
        status, headers, body = self.request(port, "/api/global")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        return json.loads(body)

    def test_assets_routes_and_head(self):
        """Test static assets, global routes, and player route with token."""
        with self.server("--player0=bot", "--player1=bot") as (port, proc):
            for path, mime in [
                ("/", "text/html; charset=utf-8"),
                ("/client/global", "text/html; charset=utf-8"),
                ("/awm.html?mode=global", "text/html; charset=utf-8"),
                ("/awm.wasm", "application/wasm"),
                ("/awm.data", "application/octet-stream"),
                ("/awm.js", "text/javascript; charset=utf-8"),
                ("/api/global", "application/json"),
                ("/healthz", "text/plain; charset=utf-8"),
                ("/api/health", "text/plain; charset=utf-8"),
            ]:
                status, headers, body = self.request(port, path)
                self.assertEqual(status, 200, path)
                self.assertEqual(headers["Content-Type"], mime, path)
                self.assertEqual(headers["Cache-Control"], "no-store", path)
                status, head_headers, head_body = self.request(port, path, "HEAD")
                self.assertEqual(status, 200, path)
                self.assertEqual(head_body, b"", path)
                self.assertEqual(int(head_headers["Content-Length"]),
                                 len(body), path)
            for route in ["/client/global"]:
                _, _, body = self.request(port, route)
                self.assertIn(b"<title>AWM", body)
                self.assertIn(b'src="/awm.js"', body)
                self.assertNotIn(b'src="awm.js"', body)
                self.assertIn(b"Module.locateFile", body)
            _, _, global_body = self.request(port, "/client/global")
            self.assertIn(b'"global"', global_body)

    def test_player_route_requires_token(self):
        with self.server("--player0=human", "--player1=bot") as (port, proc):
            status, _, _ = self.request(port, "/client/player")
            self.assertEqual(status, 403)
            status, _, _ = self.request(port, "/client/player?slot=0&token=bad")
            self.assertEqual(status, 403)

    def test_player_route_with_valid_token(self):
        with self.server("--player0=human", "--player1=bot") as (port, proc):
            url = self.extract_player_url(proc, 1)
            path = url.split(str(port), 1)[1]
            status, _, body = self.request(port, path)
            self.assertEqual(status, 200)
            self.assertIn(b"<title>AWM", body)
            self.assertIn(b'"player"', body)
            self.assertIn(b'"--slot"', body)
            self.assertIn(b'"--token"', body)

    def test_bot_vs_bot_progresses(self):
        with self.server("--player0=bot", "--player1=bot",
                         "--step-ms=500") as (port, _):
            first = self.snapshot(port)
            self.assertEqual(first["schemaVersion"], 5)
            self.assertEqual(len(first["game"]["players"]), 2)
            time.sleep(1.1)
            later = self.snapshot(port)
            self.assertEqual(first["matchId"], later["matchId"])
            self.assertGreaterEqual(later["revision"] - first["revision"], 2)
            self.assertNotEqual(later["game"], first["game"])

            start_time = time.monotonic()
            before = self.snapshot(port)
            for _ in range(40):
                self.snapshot(port)
            after = self.snapshot(port)
            elapsed = time.monotonic() - start_time
            self.assertLessEqual(after["revision"] - before["revision"],
                                 math.ceil(elapsed / 0.5))

    def test_read_only_and_static_path_confinement(self):
        with self.server("--player0=bot", "--player1=bot") as (port, _):
            for path in ["/api/global", "/awm.html", "/api/player"]:
                status, headers, _ = self.request(port, path, "POST")
                self.assertEqual(status, 405)
                self.assertEqual(headers["Allow"], "GET, HEAD")
            for path in [
                "/missing", "/api/player", "/../secret.txt",
                "/%2e%2e/secret.txt", "/%2e%2e%2fsecret.txt",
                "/%5c..%5csecret.txt", "/awm.html%00", "/linked.txt",
                "/linked-dir/secret.txt",
            ]:
                status, _, body = self.request(port, path)
                self.assertEqual(status, 404, path)
                self.assertNotIn(b"outside asset root", body)
            self.assertEqual(self.request(port, "/api/health")[0], 200)

    def test_presentation_cycle_changes_match_identity(self):
        with self.server("--player0=bot", "--player1=bot",
                         "--step-ms=100", "--max-turns=1") as (port, _):
            first = self.snapshot(port)
            time.sleep(0.25)
            later = self.snapshot(port)
            self.assertNotEqual(first["matchId"], later["matchId"])
            self.assertEqual(later["revision"], 0)
            self.assertEqual(later["game"]["turnNumber"], 1)

    def test_invalid_configuration_exits_cleanly(self):
        for options in [["--port=0"], ["--step-ms=0"], ["--max-turns=-1"],
                        ["--port"], ["--unknown"], ["--seed=nope"],
                        ["--web-dir", str(self.root / "missing")]]:
            completed = subprocess.run(
                [str(self.binary), *options], capture_output=True, timeout=3,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(b"AWM server:", completed.stdout + completed.stderr)

    def test_human_seat_waits_for_connection(self):
        """With a human seat, /api/global returns waiting until game starts."""
        with self.server("--player0=human", "--player1=bot") as (port, _):
            data = self.snapshot(port)
            self.assertIn("waiting", data)
            self.assertTrue(data["waiting"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
