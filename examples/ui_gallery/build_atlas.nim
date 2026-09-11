## Build the gallery from Silky's example assets, without game art packs.
import std/os, pixie, silky/atlas

let silkyRoot = if paramCount() > 0: paramStr(1) else: "../silky"
let data = silkyRoot / "examples/basicwindow/data"
createDir("tmp/ui-gallery")
let builder = newAtlasBuilder(2048, 4)
builder.addDir(data & "/", data & "/")
doAssert builder.addImage("button.disabled.9patch",
  readImage(silkyRoot / "examples/the7gui/data/button.disabled.9patch.png"))
builder.addFont(data / "IBMPlexSans-Regular.ttf", "Default", 18)
builder.addFont(data / "IBMPlexSans-Regular.ttf", "H1", 30)
builder.write("tmp/ui-gallery/atlas.png")
