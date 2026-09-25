"""Exercise the real HTTP server and native Gota worker with standard-library tools."""
import concurrent.futures
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "coworld/fast_xp/server"


def main():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    with tempfile.TemporaryDirectory(prefix="fast-xp-test-") as directory:
        environment = dict(os.environ, FAST_XP_PORT=str(port),
                           FAST_XP_HOST="127.0.0.1", FAST_XP_TOKEN="test-token",
                           FAST_XP_WORKERS="1", TMPDIR=directory)
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
                source = (ROOT / "coworld/gota/players/rusher.bas").read_text()
                body = {"seed": 743478993, "config": {"max_ticks": 240},
                        "players": [{"source": source} for _ in range(10)]}
                for invalid in [dict(body, seed=True), dict(body, seed=2**31),
                                dict(body, players=[]), dict(body, extra=1),
                                dict(body, config={"max_ticks": 0}),
                                dict(body, config={"max_ticks": 28801}),
                                dict(body, players=[{"policy_ref": "x:v1"}] * 10),
                                dict(body, players=[{"source": "x" * 65537}] * 10)]:
                    assert call(route, invalid)[0] == 400
                status, headers, data = call(route, body)
                assert status == 200, (status, data)
                assert headers.get_content_type() == "application/zip"
                assert "run;dur=" in headers["Server-Timing"]
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    assert set(archive.namelist()) == {"replay.replay"} | {
                        f"logs/slot-{slot}.txt" for slot in range(10)}
                    replay = archive.read("replay.replay")
                    assert len(replay) > 100
                    for slot in range(10):
                        assert b"completed" in archive.read(f"logs/slot-{slot}.txt")
                bad = dict(body, players=[{"source": "THIS IS INVALID BASIC ???"}] * 10)
                status, _, data = call(route, bad)
                assert status == 422, (status, data)
                assert "slot 0" in json.loads(data)["error"]
                # A failed compilation must release capacity and leave later games intact.
                status, _, data = call(route, body)
                assert status == 200, (status, data)
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    assert archive.read("replay.replay") == replay
                # Synchronize a long real match with a second request; capacity must reject it.
                long_body = dict(body, config={"max_ticks": 28800})
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    future = pool.submit(call, route, long_body)
                    deadline = time.monotonic() + 10
                    while not list(Path(directory).glob("fast-xp-*/config.json")):
                        assert time.monotonic() < deadline
                        time.sleep(0.01)
                    assert call("/healthz")[0] == 200
                    status, headers, _ = call(route, body)
                    assert status == 503
                    assert headers["Retry-After"] == "1"
                    status, _, data = future.result()
                    assert status == 200, (status, data)
                assert not list(Path(directory).glob("fast-xp-*")), "Leaked match files"
            except BaseException:
                print(Path(log.name).read_text())
                raise
            finally:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    main()
