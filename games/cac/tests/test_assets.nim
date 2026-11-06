import
  std/[os, strutils],
  pixie,
  ../src/baseset, ../src/ui/cardfaces, ../src/paths,
  ../tools/stage_card_art

proc testAssets() =
  ## Render cards and decode VFX using data assets from another directory.
  let
    originalDir = getCurrentDir()
    artwork = artworkRoot()
  try:
    setCurrentDir(getTempDir())
    doAssert artworkRoot() == artwork
    for card in baseCards:
      let face = renderCardFace(card)
      doAssert face.width == CardFaceWidth
      doAssert face.height == CardFaceHeight
    initCardAssets(artwork / "cards")
    let back = renderCardBack()
    doAssert back.width == CardFaceWidth
    doAssert back.height == CardFaceHeight
    for name in ["lightning-strike", "ooze-droplet", "ooze-splat"]:
      let texture = readImage(artwork / "vfx/textures" / (name & ".png"))
      doAssert texture.width > 0 and texture.height > 0
    echo "Rendered ", baseCards.len, " cards and loaded CaC VFX from ", artwork
  finally:
    setCurrentDir(originalDir)

proc testStagedArt() =
  ## The browser build stages every illustration pre-cropped to the art
  ## window. The game must draw a staged illustration exactly as it draws
  ## the full-size original, and every base card must have one.
  let
    source = artworkRoot() / "cards/art"
    staged = getTempDir() / "cac-staged-card-art"
  removeDir(staged)
  try:
    let count = stageCardArt(source, staged)
    doAssert fileExists(staged / "unknown.svg")
    var checked = 0
    for kind, path in walkDir(source):
      if kind != pcFile or path.splitFile.ext != ".png":
        continue
      let
        stagedImage = readImage(staged / path.extractFilename)
        original = cropToArtWindow(readImage(path))
        drawn = cropToArtWindow(stagedImage)
      doAssert stagedImage.width == ArtRect.w.int and
        stagedImage.height == ArtRect.h.int, path
      doAssert drawn.data == original.data, "Staged art differs: " & path
      inc checked
    doAssert checked == count
    for card in baseCards:
      let name = card.name.toLowerAscii().replace(" ", "-") & ".png"
      doAssert fileExists(staged / name), "No staged art for " & card.name
    echo "Staged ", count, " illustrations; each draws exactly as its original"
  finally:
    removeDir(staged)

testAssets()
testStagedArt()
