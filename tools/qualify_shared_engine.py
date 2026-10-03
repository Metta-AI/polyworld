"""Run the asset-free shared engine cohort and retain source identities."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

COHORT = (
    "test_animblend_controls",
    "test_characters",
    "test_picking",
    "test_pathing",
    "test_tile_paths",
    "test_terrainmaps",
)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dependencies", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test", choices=COHORT, action="append")
    parser.add_argument("--target", choices=("native", "wasm"), default="native")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    lock = root / "nimby.lock"
    dependencies = []
    paths = []
    for line in lock.read_text().splitlines():
        name, _, _, expected = line.split()
        directory = args.dependencies.resolve() / name
        source = directory / "src" if (directory / "src").is_dir() else directory
        if not source.is_dir():
            raise FileNotFoundError(source)
        actual = subprocess.check_output(
            ["git", "-C", str(directory), "rev-parse", "HEAD"], text=True
        ).strip()
        dependencies.append({"name": name, "expected": expected, "actual": actual})
        paths.append(f"--path:{source}")
    report = {
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "engine_source": subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip(),
        "nim_version": subprocess.check_output(["nim", "--version"], text=True),
        "target": args.target,
        "lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
        "dependencies": dependencies,
        "dependency_lock_matches": all(
            row["expected"] == row["actual"] for row in dependencies
        ),
        "scope": "Asset-free native or WebAssembly assertions. Does not establish rendered browser or downstream game acceptance.",
        "results": [],
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["dependency_lock_matches"]:
        raise ValueError("Qualification requires every dependency to match nimby.lock")
    if args.target == "wasm":
        report["emscripten_version"] = subprocess.check_output(
            ["emcc", "--version"], text=True
        )
        report["node_version"] = subprocess.check_output(
            ["node", "--version"], text=True
        )
    for test in args.test or COHORT:
        source = root / "tests" / f"{test}.nim"
        command = [
            "nim",
            "c",
            "--parallelBuild:1",
            "--skipUserCfg:on",
            "--skipParentCfg:on",
            "--skipProjCfg:on",
            "-d:release",
            "-d:nimTypeNames",
            "-d:flatty64",
            "-d:bassyNative",
            f"--path:{root / 'src'}",
            *paths,
            f"--nimcache:{output / 'cache' / test}",
        ]
        executable = output / (test + ".js" if args.target == "wasm" else test)
        if args.target == "wasm":
            command.extend(
                (
                    "-d:emscripten",
                    "--os:linux",
                    "--cpu:wasm32",
                    "--cc:clang",
                    "--clang.exe:emcc",
                    "--clang.linkerexe:emcc",
                    "--gc:arc",
                    "--exceptions:goto",
                    "-d:noSignalHandler",
                    "--threads:off",
                    "--passL:-O3",
                    "--passL:-sEXIT_RUNTIME=1",
                    "--passL:-sEXPORTED_FUNCTIONS=_main,_malloc",
                )
            )
        command.extend((f"--out:{executable}", str(source)))
        with (output / f"{test}.log").open("w") as log:
            result = subprocess.run(
                command,
                cwd=root,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=90,
                check=False,
            )
        report["results"].append(
            {
                "test": test,
                "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "command": command,
                "exit_code": result.returncode,
            }
        )
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if result.returncode:
            raise SystemExit(result.returncode)
        execution = (
            ["node", str(executable)] if args.target == "wasm" else [str(executable)]
        )
        with (output / f"{test}.run.log").open("w") as log:
            run = subprocess.run(
                execution,
                cwd=root,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
        report["results"][-1].update(
            execution=execution,
            runtime_exit_code=run.returncode,
            executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
            runtime_artifacts_sha256={
                artifact.name: hashlib.sha256(artifact.read_bytes()).hexdigest()
                for artifact in (
                    [executable, executable.with_suffix(".wasm")]
                    if args.target == "wasm"
                    else [executable]
                )
            },
            output_sha256=hashlib.sha256(
                (output / f"{test}.run.log").read_bytes()
            ).hexdigest(),
        )
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if run.returncode:
            raise SystemExit(run.returncode)
