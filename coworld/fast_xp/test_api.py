"""Exercise inline matches, seating, private references, and request validation."""
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
                body = {"seed": 743478993, "config": {"max_ticks": 240},
                        "roster": [{"player": {"policy_ref": "relh:v231"}, "slot": -1}]}
                for invalid in [dict(body, seed=True), dict(body, seed=2**31),
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
                # References remain private and unresolved, even beside supplied source.
                for roster in [mixed, body["roster"],
                               [{"player": {"policy_ref": "109b99c1-3bb7-4276-b17e-378b43a97874"}}],
                               [{"player": {"policy_ref": "my-bot:v12"}, "slot": 0},
                                {"player": {"policy_ref": "relh:v231"}, "slot": -1}],
                               [{"player": {"policy_ref": "relh:v231"}, "slot": i}
                                for i in range(10)]]:
                    status, headers, data = call(route, dict(body, roster=roster))
                    assert status == 501, (status, data)
                    assert headers.get_content_type() == "application/json"
                    assert "not implemented" in json.loads(data)["error"]
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


if __name__ == "__main__":
    main()
