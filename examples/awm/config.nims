import std/os

# POLYWORLD_REPO is the Polyworld repository (the folder with src/).
# Dependencies are resolved from the nimby workspace (parent of the repo).
let
  awmProjectDir = currentSourcePath().parentDir
  awmPolyworldRepo = absolutePath(getEnv("POLYWORLD_REPO",
    awmProjectDir / ".." / ".."))
  awmDependenciesDir = awmPolyworldRepo.parentDir

switch("path", awmPolyworldRepo / "src")
for dependency in [
  "windy", "silky", "bumpy", "chroma", "vmath", "pixie", "jsony", "opengl",
  "shady", "gltf", "benchy", "noisy", "fluffy", "flatty", "urlly", "metal4",
  "ws", "dx12", "vk14", "nimsimd", "crunchy", "zippy", "webby"
]:
  let d = awmDependenciesDir / dependency
  switch("path", if dirExists(d / "src"): d / "src" else: d)

--define:nimTypeNames
--define:flatty64

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck

when defined(emscripten):
  # Match Polyworld's emscripten.nims backend and URL-input conventions, with
  # only AWM's required assets staged by tools/build_web.sh.
  let
    awmWebDir = absolutePath(getEnv("AWM_WEB_DIR", awmProjectDir / "build/web"))
    awmWebAssets = awmWebDir / "assets"
  switch("nimcache", awmWebDir / "nimcache")
  switch("out", awmWebDir / "awm.html")
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
    quoteShell(awmWebAssets / "polyworld_art" & "@/polyworld_art"))
  switch("passL", "--preload-file " &
    quoteShell(awmWebAssets / "players" & "@/players"))
  switch("passL", "--pre-js " &
    quoteShell(awmPolyworldRepo / "src/polyworld/webinputs.js"))
  switch("passL", "--pre-js " & quoteShell(awmProjectDir / "web/inputs.js"))
  switch("passL", "--shell-file " & quoteShell(awmProjectDir / "web/shell.html"))
  switch("passL", "-s ASYNCIFY -s FETCH -s USE_WEBGL2=1 " &
    "-s MAX_WEBGL_VERSION=2 -s MIN_WEBGL_VERSION=2 -s FULL_ES3=1 " &
    "-s GL_ENABLE_GET_PROC_ADDRESS=1 -s ALLOW_MEMORY_GROWTH " &
    "-s STACK_SIZE=8388608 -s INITIAL_MEMORY=134217728 --profiling")
