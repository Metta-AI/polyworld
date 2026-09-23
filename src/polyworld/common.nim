## Shared paths and constants for Polyworld.
## Native games load assets from the sibling polyworld_art folder.
## Wasm packs that folder at /polyworld_art.

const
  DataRoot* =
    when defined(emscripten):
      "/polyworld_art"
    else:
      "../polyworld_art"
  # Generated files that do not belong in polyworld_art.
  TmpRoot* =
    when defined(emscripten):
      "/tmp"
    else:
      "tmp"
