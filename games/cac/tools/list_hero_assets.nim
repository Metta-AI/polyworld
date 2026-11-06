## Prints the CharGen files the CaC heroes load, one per line, relative to
## polyworld_art/characters/chargen. The browser build stages exactly these.

import ../src/scene/heroes

for path in heroAssetFiles():
  echo path
