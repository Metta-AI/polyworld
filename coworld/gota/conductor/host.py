"""Run the native GotA engine through Conductor's process protocol."""

import gzip
import hashlib
import json
import os
import secrets
import subprocess
import time
from pathlib import Path


def run():
    root = Path(os.environ["WORLD_SCRATCH_PATH"])
    request = json.loads(Path(os.environ["WORLD_INPUT_PATH"]).read_text())
    policies = {policy["role"]: policy for policy in request["policies"]}
    roles = [f"seat-{slot}" for slot in range(10)]
    if request.get("seats") or set(policies) != set(roles):
        raise ValueError("GotA requires ten embedded seats")
    supplied = request["config"]
    if set(supplied) - {"max_ticks", "draft_mode"}:
        raise ValueError("Unknown GotA configuration")
    ticks = supplied.get("max_ticks", 28_800)
    if type(ticks) is not int or not 1 <= ticks <= 28_800:
        raise ValueError("Invalid tick budget")
    draft_mode = supplied.get("draft_mode", "open")
    if draft_mode not in ("open", "team"):
        raise ValueError("Invalid draft mode")
    seed = request["seed"]
    if seed >= 2**31:
        seed -= 2**32
    config = {"seed": seed, "max_ticks": ticks, "draft_mode": draft_mode, "tokens": [], "players": []}
    seats = []
    for slot, role in enumerate(roles):
        policy = policies[role]
        if policy["format"] != "basic-source-v1":
            raise ValueError("Unsupported policy format")
        source = Path(policy["path"])
        if source.stat().st_size > 1024 * 1024:
            raise ValueError("Policy is too large")
        body = source.read_bytes()
        body.decode("utf-8")
        config["tokens"].append(secrets.token_hex(24))
        config["players"].append({"name": role})
        seats.append(
            {
                "slot": slot,
                "file_uri": source.as_uri(),
                "content_hash": hashlib.sha256(body).hexdigest(),
                "size_bytes": len(body),
                "log_uri": (root / f"private-{slot}.log").as_uri(),
                "artifact_uri": (root / f"private-{slot}.zip").as_uri(),
            }
        )
    files = {
        "CONFIG": ("game-config.json", config),
        "PLAYER_SEATS": ("game-seats.json", {"schema": "coworld-player-seats/1", "seats": seats}),
    }
    environment = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": str(root),
        "COGAME_LLM": "off",
        "COGAME_ORACLE": "off",
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": "8081",
    }
    for key, (name, value) in files.items():
        path = root / name
        path.write_text(json.dumps(value))
        environment[f"COGAME_{key}_URI"] = path.as_uri()
    for key, name in (
        ("RESULTS", "game-result.json"),
        ("SAVE_REPLAY", "game-replay"),
        ("PLAYER_FAILURE", "game-failure.json"),
    ):
        environment[f"COGAME_{key}_URI"] = (root / name).as_uri()
    deadline = min(request["deadlineAt"] / 1000, time.time() + 60)
    child = subprocess.Popen(
        ["/usr/local/bin/polyworld"], env=environment, cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    try:
        while not (root / "game-result.json").exists():
            if (root / "game-failure.json").exists():
                raise RuntimeError("Policy execution failed")
            if child.poll() is not None:
                raise RuntimeError("Game exited before publishing its result")
            if time.time() >= deadline:
                raise TimeoutError("GotA exceeded its execution budget")
            time.sleep(0.02)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    result = json.loads((root / "game-result.json").read_text())
    if len(result.get("scores", [])) != 10:
        raise ValueError("Invalid GotA result")
    with (root / "game-replay").open("rb") as source, gzip.open(root / "replay.gz", "wb") as target:
        while block := source.read(64 * 1024):
            target.write(block)
    output = {
        "result": result,
        "artifacts": [{"name": "replay", "path": "replay.gz", "mediaType": "application/gzip"}],
    }
    path = Path(os.environ["WORLD_OUTPUT_PATH"])
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(output))
    temporary.replace(path)


if __name__ == "__main__":
    run()
