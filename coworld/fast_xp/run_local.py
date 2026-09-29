"""Launch fast-XP with the saved personal Observatory credential, without printing it."""

import os
from pathlib import Path


def main():
    server = Path(__file__).resolve().with_name("server")
    if not server.is_file() or not server.with_name("gota_worker").is_file():
        raise SystemExit("Build coworld/fast_xp/server.nim and gota_worker.nim first.")
    if not os.environ.get("FAST_XP_OBSERVATORY_TOKEN"):
        from softmax.auth import load_user_token

        token = load_user_token(server="https://softmax.com/api")
        if not token:
            raise SystemExit("Sign in with your personal Softmax user account first.")
        os.environ["FAST_XP_OBSERVATORY_TOKEN"] = token
        os.environ["FAST_XP_OBSERVATORY_ELEVATED"] = "1"
    os.chdir(server.resolve().parents[2])
    os.execv(str(server.resolve()), [str(server.resolve())])


if __name__ == "__main__":
    main()
