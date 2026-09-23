import
  std/[json, os],
  sync_dependencies, tooling

proc resolvedPath(path: string): string =
  ## Resolves existing ancestors so nonexistent outputs cannot hide symlinks.
  if fileExists(path) or dirExists(path) or symlinkExists(path):
    return expandFilename(path)
  let parent = path.parentDir
  require(parent != path, "Unable to resolve output path: " & path)
  resolvedPath(parent) / path.extractFilename()

proc main() =
  ## Builds a clean static viewer from pinned dependencies and assets.
  let args = commandLineParams()
  require(args.len == 2,
    "Usage: nim r coworld/tools/build_replay_viewer.nim GAME OUTPUT")
  let
    game = args[0]
    output = args[1]
  var directory = ""
  for spec in Games:
    if spec.name == game:
      directory = spec.directory
  require(directory.len > 0, "Unknown replay game: " & game)
  require(output.isAbsolute() and not output.symlinkExists(),
    "Replay bundle output must be an absolute directory, not a symlink")
  let
    resolved = resolvedPath(output)
    root = expandFilename(Root)
  require(resolved != root and not root.isRelativeTo(resolved),
    "Replay bundle output must not contain the repository: " & output)
  putEnv("POLYWORLD_DEPS",
    absolutePath(getEnv("POLYWORLD_DEPS", Root / "tmp/coworld/deps")))
  putEnv("POLYWORLD_ART",
    absolutePath(getEnv("POLYWORLD_ART", Root.parentDir / "polyworld_art")))
  syncDependencies()
  let
    data = getEnv("POLYWORLD_ART")
    assets = parseJson(readFile(Root / "coworld/assets.json"))
    revision = assets["revision"].getStr()
    actual = command(["git", "-C", data, "rev-parse", "HEAD"])
  require(revision.len > 0 and actual == revision,
    "Asset revision mismatch: expected " & revision & ", got " & actual)
  if dirExists(output):
    removeDir(output)
  createDir(output)
  run([
    "nim", "c", "-d:emscripten", "-d:replayViewer",
    "examples" / directory / (game & ".nim")
  ])
  let source = Root / "examples" / directory / "emscripten"
  for suffix in ["js", "wasm", "data"]:
    copyFile(source / (game & "." & suffix), output / (game & "." & suffix))
  copyFile(source / (game & ".html"), output / "index.html")
  copyFile(source / "loading-logo.png", output / "loading-logo.png")

runTool(main)
