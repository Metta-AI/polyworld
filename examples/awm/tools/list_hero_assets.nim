## Prints the CharGen files the AWM heroes load, one per line, relative to
## polyworld_art/characters/chargen. The browser build stages exactly these.

import ../awmheroes

for path in heroAssetFiles():
  echo path
