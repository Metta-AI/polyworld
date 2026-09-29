"""Check queue fairness, worker bounds, partial failures and graceful shutdown."""
import io
import json
import os
from pathlib import Path
import signal
import socket
import sys
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

SERVER = Path(__file__).resolve().with_name("server")


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        worker = root / "worker.py"
        worker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, time
from urllib.parse import unquote, urlsplit
root = pathlib.Path(__file__).parent
path = lambda key: pathlib.Path(unquote(urlsplit(os.environ[key]).path))
config = json.loads(path("COGAME_CONFIG_URI").read_text())
seed = config["seed"]
with (root / "started").open("a") as file:
    file.write(str(seed) + "\\n")
while (root / "gate").exists(): time.sleep(.01)
if seed == 999: time.sleep(180)
time.sleep(.1)
# A full pipe would deadlock a runner that waits without consuming output.
print("x" * 100000)
seats = json.loads(path("COGAME_PLAYER_SEATS_URI").read_text())
for seat in seats["seats"]:
    pathlib.Path(unquote(urlsplit(seat["log_uri"]).path)).write_text("completed\\n")
if seed == 202:
    path("COGAME_PLAYER_FAILURE_URI").write_text(json.dumps({"failed_policy_index":0}))
    raise SystemExit(1)
path("COGAME_RESULTS_URI").write_text("{}")
path("COGAME_SAVE_REPLAY_URI").write_bytes(str(seed).encode())
''')
        worker.chmod(0o700)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = dict(os.environ, FAST_XP_PORT=str(port), FAST_XP_HOST="127.0.0.1",
                   FAST_XP_WORKERS="2", FAST_XP_GOTA_WORKER=str(worker), FAST_XP_TOKEN="", TMPDIR=directory)
        log = root / "server.log"
        with log.open("wb") as output:
            process = subprocess.Popen([SERVER], env=env, stdout=output, stderr=output)
            try:
                def call(seed, count=1):
                    body = {"seed": seed, "num_episodes": count, "roster": [{"player": {"source": "end"}}]}
                    request = urllib.request.Request(f"http://127.0.0.1:{port}/v1/games/gota/run",
                        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
                    try:
                        response = urllib.request.urlopen(request, timeout=150)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        return response.status, response.read()

                def records():
                    return [json.loads(line) for line in log.read_text().splitlines()]

                def wait_for(predicate, timeout=10):
                    deadline = time.monotonic() + timeout
                    while not predicate():
                        assert process.poll() is None, log.read_text()
                        assert time.monotonic() < deadline, log.read_text()
                        time.sleep(.02)

                wait_for(lambda: any(r["event"] == "server_started" for r in records()))
                gate = root / "gate"
                gate.touch()
                with ThreadPoolExecutor(max_workers=10) as pool:
                    first = pool.submit(call, 100, 10)
                    wait_for(lambda: (root / "started").exists() and len((root / "started").read_text().splitlines()) == 2)
                    second = pool.submit(call, 500)
                    wait_for(lambda: sum(r["event"] == "request_accepted" for r in records()) == 2)
                    time.sleep(.2)
                    assert len((root / "started").read_text().splitlines()) == 2
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz") as response:
                        assert response.status == 200
                    gate.unlink()
                    assert first.result()[0] == second.result()[0] == 200
                order = [int(line) for line in (root / "started").read_text().splitlines()]
                assert order.index(500) <= 4, order
                status, data = call(200, 3)
                assert status == 200
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    games = json.loads(archive.read("manifest.json"))["games"]
                    assert [g["http_status"] for g in games] == [200, 200, 422]
                    assert "games/000/replay.replay" in archive.namelist()
                    assert "games/002/replay.replay" not in archive.namelist()
                with ThreadPoolExecutor(max_workers=10) as pool:
                    assert all(r[0] == 200 for r in pool.map(call, range(600, 610)))
                # Exercise the real execution deadline and process termination.
                if "--skip-deadline" not in sys.argv:
                    began = time.monotonic()
                    timeout_status, timeout_body = call(999)
                    assert timeout_status == 504, (timeout_status, timeout_body)
                    assert 120 <= time.monotonic() - began < 130
                gate.touch()
                before = len((root / "started").read_text().splitlines())
                with ThreadPoolExecutor(max_workers=1) as pool:
                    pending = pool.submit(call, 700, 10)
                    wait_for(lambda: len((root / "started").read_text().splitlines()) == before + 2)
                    process.send_signal(signal.SIGTERM)
                    time.sleep(.2)
                    gate.unlink()
                    status, data = pending.result()
                    assert status == 200
                    with zipfile.ZipFile(io.BytesIO(data)) as archive:
                        statuses = [g["http_status"] for g in json.loads(archive.read("manifest.json"))["games"]]
                        assert statuses.count(200) == 2 and statuses.count(503) == 8, statuses
                exit_code = process.wait(timeout=10)
                assert exit_code == 0, (exit_code, log.read_text())
                assert not list(root.glob("fast-xp-*")), "Temporary results leaked"
                assert "xxxx" not in log.read_text(), "Worker transcripts reached the journal"
                assert len(log.read_bytes()) < 100000
                print("Queue, fairness, partial-result and shutdown checks passed")
                if "--skip-deadline" not in sys.argv:
                    print("120-second deadline and worker termination check passed")
            finally:
                if process.poll() is None:
                    (root / "gate").unlink(missing_ok=True)
                    process.terminate()
                    process.wait(timeout=140)


if __name__ == "__main__":
    main()
