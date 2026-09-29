"""Exercise inline matches, seating, private references, and request validation."""
import base64
import io
import hashlib
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from urllib.parse import parse_qs, urlsplit
import json
import os
from pathlib import Path
import socket
import sys
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "coworld/fast_xp/server"


class PolicyService(BaseHTTPRequestHandler):
    source = b'print "private-opponent"\nend'
    lookups = []
    downloads = []
    failures = []
    deny = False
    hold = threading.Event()
    entered = threading.Event()
    hold.set()

    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path)
        if path.path == "/v2/policy-files/download":
            ref = parse_qs(path.query)["policy_ref"][0]
            self.lookups.append(ref)
            if self.headers.get("Authorization") != "Bearer fake-observatory-token":
                self.failures.append("Missing Observatory credential")
            if self.headers.get("X-Use-Elevated-Privileges") != "true":
                self.failures.append("Missing elevation header")
            errors = {"missing:v1": 404, "invalid:v1": 400, "nofile:v1": 409,
                      "denied:v1": 403, "expired:v1": 401}
            status = 401 if self.deny else errors.get(ref, 200)
            if ref == "lookup-redirect:v1":
                self.send_response(302)
                self.send_header("Location", "/must-not-follow")
                self.end_headers()
                return
            self.send_response(status)
            self.end_headers()
            if status != 200:
                self.wfile.write(b'{"detail":"do not expose upstream response bodies"}')
                return
            source = b'print "private-compile-secret"\nif\n' if ref == "broken:v1" else self.source
            digest = hashlib.sha256(source).hexdigest()
            if ref == "hash-mismatch:v1":
                digest = "b" * 64
            if ref == "bad-metadata:v1":
                self.wfile.write(b'{"oops": true}')
                return
            data = {"policy_version_id": "11111111-1111-4111-8111-111111111111",
                    "content_hash": digest, "size_bytes": len(source),
                    "expires_in_seconds": 300,
                    "download_url": f"http://127.0.0.1:{self.server.server_port}/artifact?ref={ref}"}
            if ref == "size-mismatch:v1":
                data["size_bytes"] += 1
            if ref == "oversize:v1":
                data["size_bytes"] = 16 * 1024 * 1024 + 1
            if ref == "unsafe-url:v1":
                data["download_url"] = "http://example.com/bot"
            self.wfile.write(json.dumps(data).encode())
        elif path.path == "/artifact":
            ref = parse_qs(path.query)["ref"][0]
            self.downloads.append(ref)
            if self.headers.get("Authorization") or self.headers.get("X-Use-Elevated-Privileges"):
                self.failures.append("Credentials leaked to artifact host")
            self.entered.set()
            self.hold.wait(15)
            if ref == "slow:v1":
                time.sleep(11)
                return
            if ref == "download-fails:v1":
                self.send_response(403)
                self.end_headers()
                return
            if ref == "redirect:v1":
                self.send_response(302)
                self.send_header("Location", "/must-not-follow")
                self.end_headers()
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'print "private-compile-secret"\nif\n' if ref == "broken:v1" else self.source)
        else:
            self.failures.append("Unexpected request: " + self.path)
            self.send_response(404)
            self.end_headers()


def main():
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), PolicyService)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    with tempfile.TemporaryDirectory(prefix="fast-xp-test-") as directory:
        environment = dict(os.environ, FAST_XP_PORT=str(port),
                           FAST_XP_HOST="127.0.0.1", FAST_XP_TOKEN="test-token",
                           FAST_XP_WORKERS="2", TMPDIR=directory,
                           FAST_XP_OBSERVATORY_URL=f"http://127.0.0.1:{upstream.server_port}",
                           FAST_XP_OBSERVATORY_TOKEN="fake-observatory-token",
                           FAST_XP_OBSERVATORY_ELEVATED="1",
                           FAST_XP_CACHE_DIR=str(Path(directory) / "policies"))
        wrapper = Path(directory) / "worker"
        real_worker = str(SERVER.with_name("gota_worker"))
        wrapper.write_text(f"#!{sys.executable}\nimport os\n"
                           "assert not any(k.startswith('FAST_XP_') for k in os.environ)\n"
                           "assert 'FAKE_OTHER_SECRET' not in os.environ\n"
                           f"os.execv({real_worker!r}, [{real_worker!r}])\n")
        wrapper.chmod(0o700)
        environment["FAST_XP_GOTA_WORKER"] = str(wrapper)
        environment["FAKE_OTHER_SECRET"] = "must-not-reach-worker"
        with open(Path(directory) / "server.log", "wb") as log:
            process = subprocess.Popen([str(SERVER)], cwd=ROOT, env=environment,
                                       stdout=log, stderr=log)
            try:
                def call(path, body=None, token="test-token", method=None):
                    headers = {"Content-Type": "application/json",
                               "Authorization": "Bearer " + token}
                    data = json.dumps(body).encode() if body is not None else None
                    req = urllib.request.Request(base + path, data=data,
                                                 headers=headers, method=method)
                    try:
                        response = urllib.request.urlopen(req, timeout=150)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        return response.status, response.headers, response.read()

                for _ in range(100):
                    if process.poll() is not None:
                        raise AssertionError(Path(log.name).read_text())
                    try:
                        if call("/healthz")[0] == 200:
                            break
                    except urllib.error.URLError:
                        time.sleep(0.1)
                else:
                    raise AssertionError("Server did not start")
                route = "/v1/games/gota/run"
                assert call("/docs/llms.txt")[0] == 200
                assert b"run.md" in call("/docs/llms.txt")[2]
                assert b"policy" in call("/docs/run.md")[2]
                assert call("/unknown")[0] == 404
                assert call(route)[0] == 405
                assert call(route, {}, token="wrong")[0] == 401
                body = {"seed": 743478993, "config": {"max_ticks": 240},
                        "roster": [{"player": {"policy_ref": "relh:v231"}, "slot": -1}]}
                for invalid in [dict(body, num_episodes=0), dict(body, num_episodes=11),
                                dict(body, num_episodes=True), dict(body, num_episodes=2, seed=2**31-1),
                                dict(body, seed=True), dict(body, seed=2**31),
                                dict(body, roster=[]), dict(body, extra=1),
                                dict(body, config={"max_ticks": 0}),
                                dict(body, config={"max_ticks": 28801}),
                                dict(body, players=[{"source": "END"}] * 10),
                                dict(body, roster=[{"player": {}}]),
                                dict(body, roster=[{"player": {"source": "END", "policy_ref": "x:v1"}}]),
                                dict(body, roster=[{"player": {"source": " "}}]),
                                dict(body, roster=[{"player": {"source": 123}}]),
                                dict(body, roster=[{"player": {"source": "END\0"}}]),
                                dict(body, roster=[{"player": {"source": "END", "canReadLog": True}}]),
                                dict(body, roster=[{"player": {"policy_ref": ""}}]),
                                dict(body, roster=[{"player": {"policy_ref": 123}}]),
                                dict(body, roster=[{"player": {"policy_ref": "x:v1"}, "slot": 10}]),
                                dict(body, roster=[{"player": {"policy_ref": "x:v1"}, "slot": 0}]),
                                dict(body, roster=[{"player": {"policy_ref": "x:v1"}, "slot": 0}] * 10)]:
                    assert call(route, invalid)[0] == 400, invalid
                mixed = [{"player": {"source": 'print "mine"\nend'}, "slot": 0},
                         {"player": {"policy_ref": "relh:v231"}, "slot": -1}]
                cache = Path(directory) / "policies"
                digest = hashlib.sha256(PolicyService.source).hexdigest()
                for roster in [mixed, body["roster"],
                               [{"player": {"policy_ref": "109b99c1-3bb7-4276-b17e-378b43a97874"}}]]:
                    before = len(PolicyService.lookups)
                    status, _, data = call(route, dict(body, roster=roster))
                    assert status == 200, (status, data)
                    assert len(PolicyService.lookups) == before + 1, "Repeated seats must resolve once"
                    with zipfile.ZipFile(io.BytesIO(data)) as archive:
                        expected = {"replay.replay"}
                        if roster == mixed:
                            expected.add("logs/slot-0.txt")
                            assert "mine" in archive.read("logs/slot-0.txt").decode()
                        assert set(archive.namelist()) == expected
                assert len(PolicyService.downloads) == 1, "Same content must download only once"
                assert (cache / digest).read_bytes() == PolicyService.source
                assert (cache.stat().st_mode & 0o777) == 0o700
                assert ((cache / digest).stat().st_mode & 0o777) == 0o600
                # Cached source never bypasses a fresh authorization decision.
                PolicyService.deny = True
                assert call(route, body)[0] == 502
                PolicyService.deny = False
                # A damaged cache entry is fetched again and verified.
                (cache / digest).write_bytes(b"corrupt")
                assert call(route, body)[0] == 200
                assert len(PolicyService.downloads) == 2
                assert (cache / digest).read_bytes() == PolicyService.source
                for ref, expected in [("missing:v1", 404), ("invalid:v1", 400),
                                      ("nofile:v1", 409), ("denied:v1", 502), ("expired:v1", 502),
                                      ("hash-mismatch:v1", 502), ("size-mismatch:v1", 502),
                                      ("bad-metadata:v1", 502), ("unsafe-url:v1", 502),
                                      ("oversize:v1", 502), ("download-fails:v1", 502),
                                      ("redirect:v1", 502), ("lookup-redirect:v1", 502),
                                      ("slow:v1", 504), ("broken:v1", 422)]:
                    # Force a download even when the mock uses the same content hash.
                    (cache / digest).unlink(missing_ok=True)
                    status, _, data = call(route, dict(body, roster=[{"player": {"policy_ref": ref}}]))
                    assert status == expected, (ref, status, data)
                    assert b"private-compile-secret" not in data
                    assert b"upstream response bodies" not in data
                    assert b"fake-observatory-token" not in data
                assert not (cache / ("b" * 64)).exists(), "Never cache failed verification"
                assert not list(cache.glob("*.part")), "Leaked partial download"
                # Sixteen admitted requests share one download; only admission overflow is refused.
                (cache / digest).unlink(missing_ok=True)
                PolicyService.entered.clear()
                PolicyService.hold.clear()
                before = len(PolicyService.downloads)
                lookup_start = len(PolicyService.lookups)
                with ThreadPoolExecutor(max_workers=16) as pool:
                    futures = [pool.submit(call, route, body) for _ in range(16)]
                    try:
                        assert PolicyService.entered.wait(5)
                        for _ in range(250):
                            if len(PolicyService.lookups) >= lookup_start + 16:
                                break
                            time.sleep(.02)
                        assert len(PolicyService.lookups) == lookup_start + 16
                        assert call("/healthz")[0] == 200
                        status, headers, _ = call(route, body)
                        assert status == 429 and headers["Retry-After"] == "5"
                    finally:
                        PolicyService.hold.set()
                    assert all(future.result()[0] == 200 for future in futures)
                assert len(PolicyService.downloads) == before + 1
                assert not PolicyService.failures, PolicyService.failures
                assert "fake-observatory-token" not in Path(log.name).read_text()
                # Package bytes can exceed the BASIC source limit: keep resources
                # intact and let the production loader compile only the .bas entry.
                package = io.BytesIO()
                with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_STORED) as archive:
                    archive.writestr("policy.bas", "end\n")
                    archive.writestr("model.bin", b"x" * (2 * 1024 * 1024))
                PolicyService.source = package.getvalue()
                package_roster = [{"slot": 0, "player": {"policy_ref": "package:v1"}},
                                  {"player": {"source": "end"}}]
                status, _, data = call(route, dict(body, roster=package_roster))
                assert status == 200, (status, data)
                assert (cache / hashlib.sha256(PolicyService.source).hexdigest()).read_bytes() == PolicyService.source
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    assert set(archive.namelist()) == {"replay.replay"} | {
                        f"logs/slot-{slot}.txt" for slot in range(1, 10)}
                # Uploaded ZIPs use the same loader, but only uploaded seats get logs.
                upload = io.BytesIO()
                with zipfile.ZipFile(upload, "w", compression=zipfile.ZIP_STORED) as archive:
                    archive.writestr("nested/policy.bas", 'print "uploaded-package"\nend\n')
                    archive.writestr("assets/data.bin", b"x" * (5 * 1024 * 1024))
                uploaded = {"package_base64": base64.b64encode(upload.getvalue()).decode()}
                upload_roster = [{"slot": 0, "player": uploaded},
                                 {"slot": 5, "player": {"source": 'print "inline-seat"\nend'}},
                                 {"player": {"policy_ref": "package:v1"}}]
                status, _, data = call(route, dict(body, roster=upload_roster))
                assert status == 200, (status, data)
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    assert set(archive.namelist()) == {"replay.replay", "logs/slot-0.txt", "logs/slot-5.txt"}
                    assert b"uploaded-package" in archive.read("logs/slot-0.txt")
                    assert b"inline-seat" in archive.read("logs/slot-5.txt")
                for player in [{"package_base64": "!invalid!"},
                               {"package_base64": "ZW5k"},
                               {"package_base64": 1},
                               {"package_base64": ""},
                               dict(uploaded, source="end"),
                               dict(uploaded, policy_ref="package:v1")]:
                    assert call(route, dict(body, roster=[{"player": player}]))[0] == 400
                too_large = base64.b64encode(b"PK\x03\x04" + b"x" * (16 * 1024 * 1024 - 3)).decode()
                assert call(route, dict(body, roster=[{"player": {"package_base64": too_large}}]))[0] == 413
                for files in [[("../escape.bas", "end")], [("a.bas", "end"), ("b.bas", "end")],
                              [("data.bin", "x")], [("policy.bas", "if\n")]]:
                    invalid_zip = io.BytesIO()
                    with zipfile.ZipFile(invalid_zip, "w") as archive:
                        for name, contents in files:
                            archive.writestr(name, contents)
                    player = {"package_base64": base64.b64encode(invalid_zip.getvalue()).decode()}
                    assert call(route, dict(body, roster=[{"player": player}]))[0] == 422
                # Rotate private references and uploaded seats without changing log ownership.
                batch_body = dict(body, num_episodes=3, roster=[
                    {"slot": 0, "player": {"source": 'print "pinned"\nend'}},
                    {"player": {"source": 'print "moving"\nend'}},
                    {"player": {"policy_ref": "package:v1"}}])
                hashes = []
                before = len(PolicyService.lookups)
                for _ in range(2):
                    status, headers, data = call(route, batch_body)
                    assert status == 200, (status, data)
                    with zipfile.ZipFile(io.BytesIO(data)) as archive:
                        manifest = json.loads(archive.read("manifest.json"))
                        assert manifest["request_id"] == headers["X-Request-ID"]
                        current = []
                        expected = {"manifest.json"}
                        for i, game in enumerate(manifest["games"]):
                            assert game["seed"] == body["seed"] + i
                            assert game["status"] == "completed" and game["active_bots"] == 10
                            seats = [0] + [1 + ((j-i) % 2) for j in range(9)]
                            assert game["roster_entries_by_slot"] == seats
                            prefix = f"games/{i:03d}/"
                            expected.add(prefix + "replay.replay")
                            current.append(hashlib.sha256(archive.read(prefix + "replay.replay")).hexdigest())
                            for slot, entry in enumerate(seats):
                                if entry != 2:
                                    path = prefix + f"logs/slot-{slot}.txt"
                                    expected.add(path)
                                    assert (b"pinned" if slot == 0 else b"moving") in archive.read(path)
                        assert set(archive.namelist()) == expected
                        hashes.append(current)
                assert hashes[0] == hashes[1]
                assert len(PolicyService.lookups) == before + 2, "Resolve once per batch"
                def source(marker):
                    return {"source": f'print "{marker}"\nend'}

                rosters = [
                    ([{"player": source("all-seats")}], ["all-seats"] * 10),
                    ([{"slot": slot, "player": source(f"seat-{slot}")}
                      for slot in reversed(range(10))], [f"seat-{slot}" for slot in range(10)]),
                    ([{"slot": 5, "player": source("pinned")},
                      {"player": source("open-a")}, {"player": source("open-b")}],
                     ["open-a", "open-b", "open-a", "open-b", "open-a",
                      "pinned", "open-b", "open-a", "open-b", "open-a"]),
                ]
                for roster, markers in rosters:
                    status, headers, data = call(route, dict(body, roster=roster))
                    assert status == 200, (status, data)
                    assert headers.get_content_type() == "application/zip"
                    assert headers["Cache-Control"] == "no-store"
                    assert headers["Server-Timing"].startswith("run;dur=")
                    with zipfile.ZipFile(io.BytesIO(data)) as archive:
                        assert set(archive.namelist()) == {"replay.replay"} | {
                            f"logs/slot-{slot}.txt" for slot in range(10)}
                        assert len(archive.read("replay.replay")) > 0
                        for slot, marker in enumerate(markers):
                            output = archive.read(f"logs/slot-{slot}.txt").decode()
                            assert marker in output, (slot, output)
                            assert "completed" in output and "BASIC error" not in output
                status, _, data = call(route, dict(body, roster=[{"player": {"source": "if\n"}}]))
                assert status == 422, (status, data)
                assert "slot 0" in json.loads(data)["error"]
                assert call("/healthz")[0] == 200
                assert not list(Path(directory).glob("fast-xp-*")), "Leaked match files"
            except BaseException:
                print(Path(log.name).read_text())
                raise
            finally:
                process.terminate()
                process.wait(timeout=10)
                upstream.shutdown()
                upstream.server_close()


if __name__ == "__main__":
    main()
