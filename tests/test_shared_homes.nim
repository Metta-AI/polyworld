import std/[os, tables]
import pixie, silky
import polyworld/homes

# Packing a game's differently named sources must still produce the sprite
# contract consumed by the shared home renderer, including trimmed buttons.
block:
  let root = getTempDir() / "polyworld-shared-homes-test"
  createDir(root)
  defer: removeDir(root)
  let sources = ["backdrop", "crest", "solo", "online", "options", "quit"]
  for i, name in sources:
    let picture = newImage(20, 20)
    if i < 2:
      picture.fill(rgba(50, 80, 100, 255))
    else:
      for y in 5 .. 14:
        for x in 5 .. 14:
          picture[x, y] = rgbx(50, 80, 100, 255)
    picture.writeFile(root / (name & ".png"))
  let builder = newAtlasBuilder(1024, 1)
  builder.addHomeAssets(root, sources)
  doAssert MenuImages == ["background", "logo", "button-single-player",
    "button-multiplayer", "button-settings", "button-exit"]
  doAssert builder.atlas.entries.hasKey("home-shade")
  for i, name in MenuImages:
    let entry = builder.atlas.entries["home-" & name]
    doAssert entry.width == (if i < 2: 20 else: 12)
    doAssert entry.height == entry.width
  doAssert not builder.atlas.entries.hasKey("home-backdrop")

echo "Shared home asset tests passed"
