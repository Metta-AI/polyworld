import std/[os, strutils]

# POLYWORLD_REPO is the Polyworld repository (the folder with src/).
# Dependencies are resolved from the nimby workspace (parent of the repo).
let
  cacProjectDir = currentSourcePath().parentDir
  cacPolyworldRepo = absolutePath(getEnv("POLYWORLD_REPO",
    cacProjectDir / ".." / ".."))
  cacDependenciesDir = cacPolyworldRepo.parentDir

switch("path", cacPolyworldRepo / "src")
# With POLYWORLD_DEPS the repository's config.nims adds the pinned
# dependencies (as for the Coworld builds); otherwise use the workspace.
if getEnv("POLYWORLD_DEPS").len == 0:
  for dependency in [
    "windy", "silky", "bumpy", "chroma", "vmath", "pixie", "jsony", "opengl",
    "shady", "gltf", "benchy", "noisy", "fluffy", "flatty", "urlly", "metal4",
    "ws", "dx12", "vk14", "nimsimd", "crunchy", "zippy", "webby"
  ]:
    let d = cacDependenciesDir / dependency
    switch("path", if dirExists(d / "src"): d / "src" else: d)

# The sources live in src/, but the game is built into the project folder,
# next to players/ and web/. An -o on the command line (Coworld) still wins.
if projectName() == "cac":
  switch("out", cacProjectDir / "cac")

--define:nimTypeNames
--define:flatty64

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck

when defined(emscripten):
  # Match Polyworld's emscripten.nims backend and URL-input conventions, with
  # only CaC's required assets staged by tools/build_web.sh.
  let
    cacWebDir = absolutePath(getEnv("CAC_WEB_DIR", cacProjectDir / "build/web"))
    cacWebAssets = cacWebDir / "assets"
  switch("nimcache", cacWebDir / "nimcache")
  switch("out", cacWebDir / "cac.html")
  switch("threads", "off")
  --os:linux
  --cpu:wasm32
  --cc:clang
  --clang.exe:emcc
  --clang.linkerexe:emcc
  --clang.cpp.exe:emcc
  --clang.cpp.linkerexe:emcc
  --gc:arc
  --exceptions:goto
  --define:noSignalHandler
  --define:noAutoGLerrorCheck
  switch("passL", "--preload-file " &
    quoteShell(cacWebAssets / "polyworld_art" & "@/polyworld_art"))
  switch("passL", "--preload-file " &
    quoteShell(cacWebAssets / "players" & "@/players"))
  when defined(replayViewer):
    # The Coworld replay viewer: Polyworld's replay page fetches the episode
    # and passes --replay itself, so no URL inputs.
    let replayShell = cacWebDir / "replay-shell.html"
    writeFile(replayShell,
      readFile(cacPolyworldRepo / "src/polyworld/replay.html").replace(
        "<!-- GAME_LOGO -->",
        "<img id=\"loading-logo\" alt=\"Cards and Casters\" " &
          "width=\"320\" height=\"240\" src=\"loading-logo.svg\" " &
          "fetchpriority=\"high\">"))
    switch("passL", "--shell-file " & quoteShell(replayShell))
  else:
    switch("passL", "--pre-js " &
      quoteShell(cacPolyworldRepo / "src/polyworld/webinputs.js"))
    switch("passL", "--pre-js " & quoteShell(cacProjectDir / "web/inputs.js"))
    switch("passL", "--shell-file " &
      quoteShell(cacProjectDir / "web/shell.html"))
  # Nim's release -O3 only reaches the compile step. emcc also needs it at
  # link time, or Binaryen leaves the wasm (and Asyncify's
  # instrumentation) unoptimized.
  when not defined(debug):
    switch("passL", "-O3")
  switch("passL", "-s ASYNCIFY -s FETCH -s USE_WEBGL2=1 " &
    "-s MAX_WEBGL_VERSION=2 -s MIN_WEBGL_VERSION=2 -s FULL_ES3=1 " &
    "-s GL_ENABLE_GET_PROC_ADDRESS=1 -s ALLOW_MEMORY_GROWTH " &
    "-s STACK_SIZE=8388608 -s INITIAL_MEMORY=134217728 --profiling")
