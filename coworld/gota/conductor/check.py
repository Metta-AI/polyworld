"""Qualify a native GotA game, replay publication, and the outer execution budget."""

import argparse
import gzip
import hashlib
import json
import secrets
import subprocess
import time
import uuid
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    args = parser.parse_args()
    token = secrets.token_hex(32)
    container = docker(
        "run",
        "--detach",
        "--rm",
        "--name",
        "gota-participation-" + uuid.uuid4().hex[:10],
        "--label",
        "owner=gota-participation-qualification",
        "--platform",
        "linux/amd64",
        "--cap-drop=ALL",
        "--security-opt",
        "no-new-privileges",
        "--memory",
        "1g",
        "--cpus",
        "2",
        "-p",
        "127.0.0.1::8080",
        "-e",
        "RUNNER_TOKEN=" + token,
        "-e",
        "WORLD_RUNTIME=gota",
        "-e",
        'WORLD_COMMAND=["python3","/opt/gota/host.py"]',
        args.image,
    )
    boot = None
    try:
        origin = "http://127.0.0.1:" + docker("port", container, "8080/tcp").rsplit(":", 1)[1]

        def call(path, body=None, method=None, raw=False):
            headers = {"Authorization": "Bearer " + token}
            if boot:
                headers["x-runner-boot"] = boot
            if isinstance(body, dict):
                body = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
            with urlopen(Request(origin + path, data=body, headers=headers, method=method), timeout=10) as response:
                data = response.read()
                return data if raw or not data else json.loads(data)

        for _ in range(100):
            try:
                boot = call("/health")["bootId"]
                break
            except (URLError, ConnectionError):
                time.sleep(0.1)
        assert boot, "Runner did not start"
        policies = []
        for slot in range(10):
            file = Path(__file__).parent.parent / "players" / ("rusher.bas" if slot < 5 else "puller.bas")
            source = file.read_bytes()
            digest = hashlib.sha256(source).hexdigest()
            call("/inputs/" + digest, source, "PUT")
            policies.append(
                {"role": f"seat-{slot}", "format": "basic-source-v1", "blob": {"digest": digest, "bytes": len(source)}}
            )
        attempt = secrets.token_hex(32)
        path = "/attempts/" + attempt
        started = time.monotonic()
        call(
            path,
            {
                "protocol": 1,
                "id": attempt,
                "runId": attempt,
                "runtime": "gota",
                "deadlineAt": int(time.time() * 1000) + 120_000,
                "seed": 0,
                "policies": policies,
                "config": {"max_ticks": 28800},
            },
            "PUT",
        )
        while True:
            result = call(path)
            if result["status"] not in ("running", "queued"):
                break
            assert time.monotonic() - started < 70, "Native game exceeded its 60 second budget"
            time.sleep(0.2)
        assert result["status"] == "succeeded", result
        assert len(result["result"]["scores"]) == 10, result
        replay = call(path + "/outputs/replay", raw=True)
        decoded = gzip.decompress(replay)
        assert len(decoded) > 1000, "Replay was empty"
        assert hashlib.sha256(replay).hexdigest() == result["outputs"][0]["digest"]
        print(
            f"Qualified: ten embedded policies, complete game, hashed replay; "
            f"{time.monotonic() - started:.2f}s, {len(replay)} replay bytes."
        )
    finally:
        subprocess.run(["docker", "stop", "--time", "5", container], check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
