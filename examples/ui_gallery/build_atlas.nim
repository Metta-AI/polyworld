## Build the gallery from the pinned Silky example assets, without game art packs.
import std/[os], silky/atlas

let data = if paramCount() > 0: paramStr(1) else: "../silky/examples/basicwindow/data"
createDir("tmp/ui-gallery")
let builder = newAtlasBuilder(2048, 4)
builder.addDir(data & "/", data & "/")
builder.addFont(data / "IBMPlexSans-Regular.ttf", "Default", 18)
builder.addFont(data / "IBMPlexSans-Regular.ttf", "H1", 30)
builder.write("tmp/ui-gallery/atlas.png")
