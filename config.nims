import std/[os, strutils]

--path:"src"
let
  projectRoot = currentSourcePath().parentDir
  dependencyRoot = getEnv("POLYWORLD_DEPS", projectRoot.parentDir)
for line in readFile(projectRoot / "coworld/dependencies.lock").splitLines():
  let fields = line.splitWhitespace()
  if fields.len == 0:
    continue
  let
    name = fields[0]
    directory = dependencyRoot / name
    source =
      if dirExists(directory / "src"):
        directory / "src"
      else:
        directory
  switch("path", getEnv(name.toUpperAscii() & "_PATH", source))

--define:nimTypeNames
--define:flatty64

# Compile BASIC policies to machine code on supported native targets.
--define:bassyNative

when defined(coworld):
  when defined(emscripten):
    error("Coworld servers are native. Build replay viewers without -d:coworld.")
  --define:headless
  --threads:on

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck
