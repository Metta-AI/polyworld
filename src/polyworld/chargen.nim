## Loads a modular character library with individually shippable assets.

import
  std/os,
  chargen/[brows, eyes, hairs, models, parts]

export brows, eyes, hairs, models, parts

const ChargenLibrary* =
  when defined(emscripten):
    "/polyworld_data/characters/chargen"
  else:
    currentSourcePath().parentDir.parentDir.parentDir.parentDir /
      "polyworld_data/characters/chargen"
