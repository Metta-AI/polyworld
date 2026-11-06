import
  std/os,
  polyworld/common

# This file is in games/cac/src: the repository is three folders up.
const SourceRepo = currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc artworkRoot*(): string =
  ## Locate CaC artwork in the shared Polyworld data folder.
  when defined(emscripten):
    DataRoot / "cac"
  else:
    let repo = absolutePath(getEnv("POLYWORLD_REPO", SourceRepo))
    absolutePath(DataRoot, repo) / "cac"
