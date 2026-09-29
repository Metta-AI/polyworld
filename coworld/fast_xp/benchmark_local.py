"""Benchmark real policy fetching and matches against the Richard replay reference."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time
import urllib.request
import zipfile

POLICY = "109b99c1-3bb7-4276-b17e-378b43a97874"
SOURCE_HASH = "cac27d33df9ab132d86e6db0fc3407e1ee6275bfad4ea2138e7f194d99259720"
REPLAY_HASH = "7e020bba67058ef023df716bb0e9259cf58d110df28f5cb1e1d7d991de83419e"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New directory for timings and replays")
    parser.add_argument("--repetitions", type=int, default=3, help="Cold/warm pairs (default: 3)")
    parser.add_argument("--cpu", type=int, help="Optional Linux CPU affinity for server and workers")
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[2]
    # Load the personal token explicitly, not a possibly active player session.
    from softmax.auth import load_user_token

    token = load_user_token(server="https://softmax.com/api")
    if not token:
        raise SystemExit("Sign in with your personal Softmax account first.")
    request = urllib.request.Request(
        "https://softmax.com/api/observatory/v2/policy-files/download?policy_ref=" + POLICY,
        headers={"Authorization": "Bearer " + token, "X-Use-Elevated-Privileges": "true",
                 "User-Agent": "polyworld-fast-xp/0.1"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        metadata = json.load(response)
    # This setup fetch supplies the inline seat; it does not populate the server cache.
    with urllib.request.urlopen(metadata["download_url"], timeout=20) as response:
        source = response.read()
    assert len(source) == metadata["size_bytes"]
    assert hashlib.sha256(source).hexdigest() == metadata["content_hash"] == SOURCE_HASH
    del token, request, metadata
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    cache = root / "policies"
    env = dict(os.environ, FAST_XP_HOST="127.0.0.1", FAST_XP_PORT=str(port),
               FAST_XP_TOKEN="local-benchmark", FAST_XP_WORKERS="1", FAST_XP_CACHE_DIR=str(cache))
    # Exercise the saved-token launcher, regardless of the caller's server configuration.
    for key in ["FAST_XP_OBSERVATORY_TOKEN", "FAST_XP_OBSERVATORY_ELEVATED",
                "FAST_XP_OBSERVATORY_URL", "FAST_XP_GOTA_WORKER"]:
        env.pop(key, None)
    command = [sys.executable, str(Path(__file__).with_name("run_local.py"))]
    if args.cpu is not None:
        command = ["taskset", "-c", str(args.cpu), *command]
    log_path = root / "server.log"
    rows = []
    with log_path.open("wb") as log:
        server = subprocess.Popen(command, cwd=repo, env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                assert server.poll() is None, log_path.read_text()
                try:
                    with urllib.request.urlopen(base + "/healthz", timeout=1) as response:
                        assert response.status == 200
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError("Server did not start")
            body = json.dumps({"seed": 743478993, "config": {"max_ticks": 28800}, "roster": [
                {"slot": 0, "player": {"source": source.decode()}},
                {"player": {"policy_ref": POLICY}},
            ]}).encode()
            for repetition in range(args.repetitions):
                for mode in ["cold", "warm"]:
                    if mode == "cold" and cache.exists():
                        shutil.rmtree(cache)
                    offset = log_path.stat().st_size
                    request = urllib.request.Request(base + "/v1/games/gota/run", data=body,
                        headers={"Authorization": "Bearer local-benchmark", "Content-Type": "application/json"})
                    started = time.monotonic()
                    with urllib.request.urlopen(request, timeout=180) as response:
                        assert response.status == 200
                        assert response.headers.get_content_type() == "application/zip"
                        timings = {item.split(";dur=")[0].strip(): int(item.split(";dur=")[1]) / 1000
                                   for item in response.headers["Server-Timing"].split(",")}
                        archive_bytes = response.read()
                    wall = time.monotonic() - started
                    output = log_path.read_bytes()[offset:].decode()
                    dest = root / f"{repetition}-{mode}"
                    dest.mkdir()
                    (dest / "worker.log").write_text(output)
                    (dest / "response.zip").write_bytes(archive_bytes)
                    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
                        assert set(archive.namelist()) == {"replay.replay", "logs/slot-0.txt"}
                        replay = archive.read("replay.replay")
                        assert hashlib.sha256(replay).hexdigest() == REPLAY_HASH
                        bot_log = archive.read("logs/slot-0.txt").decode()
                        assert "completed" in bot_log and "BASIC error" not in bot_log
                    assert "scripts: 10/10 active, 288010 decisions" in output
                    assert "hash: 00000000A55D7AB7" in output
                    gameplay = float(re.search(r"simulated: [\d.]+ s in ([\d.]+) s", output)[1])
                    row = {"mode": mode, "repetition": repetition, "wall_s": wall, "gameplay_s": gameplay,
                           "timings_s": timings, "replay_sha256": REPLAY_HASH, "response_bytes": len(archive_bytes)}
                    rows.append(row)
                    (root / "measurements.json").write_text(json.dumps(rows, indent=2))
                    print(json.dumps(row), flush=True)
            summary = {mode: {
                "wall_s": statistics.median(r["wall_s"] for r in rows if r["mode"] == mode),
                "gameplay_s": statistics.median(r["gameplay_s"] for r in rows if r["mode"] == mode),
                **{key + "_s": statistics.median(r["timings_s"][key] for r in rows if r["mode"] == mode)
                   for key in ["fetch", "worker", "zip"]},
            } for mode in ["cold", "warm"]}
            (root / "summary.json").write_text(json.dumps(summary, indent=2))
            print(json.dumps(summary, indent=2), flush=True)
        finally:
            server.terminate()
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
