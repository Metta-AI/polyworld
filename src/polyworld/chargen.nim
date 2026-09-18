## Loads a modular character library with individually shippable assets.

import
  std/os,
  chargen/[brows, clothes, eyes, hairs, models, parts]

export brows, clothes, eyes, hairs, models, parts

const ChargenLibrary* =
  when defined(emscripten):
    "/polyworld_data/characters/chargen"
  else:
    currentSourcePath().parentDir.parentDir.parentDir.parentDir /
      "polyworld_data/characters/chargen"
