## The UI atlas the game builds at startup: every card face part, each
## choice's whole faces for the choose screen, the HUD's images and its
## fonts must fit it. Building it raises when they outgrow it.
import std/os
import ../src/app, ../src/paths, ../src/ui/cardfaces

proc testAtlasFits() =
  let originalDir = getCurrentDir()
  try:
    setCurrentDir(polyworldRoot())
    let cardAssets = artworkRoot() / "cards"
    initCardAssets(cardAssets)
    discard buildUiAtlas(cardAssets)
    echo "Every card face part, the HUD and its fonts fit the UI atlas"
  finally:
    setCurrentDir(originalDir)

testAtlasFits()
