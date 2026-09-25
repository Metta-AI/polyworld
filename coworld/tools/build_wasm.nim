import std/[os, strutils], tooling, sync_dependencies

proc main() =
  require(NimVersion == "2.2.10", "The Wasm runner requires Nim 2.2.10")
  require(command(["emcc", "--version"]).splitLines()[0].contains(" 6.0.9 ("),
    "The Wasm runner requires Emscripten 6.0.9")
  let dependencies = getEnv("POLYWORLD_DEPS", Root / "tmp/coworld/deps")
  putEnv("POLYWORLD_DEPS", dependencies)
  syncDependencies()
  let output = Root / "tmp/coworld/wasm"
  createDir(output)
  run([getCurrentCompilerExe(), "c", "-d:coworldWasm",
    "-o:" & output / "gota.mjs",
    Root / "examples/gods_of_the_arena/wasm_runner.nim"])
  echo "Wasm runner: ", output

when isMainModule:
  runTool(main)
