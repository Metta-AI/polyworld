import
  std/tables,
  silky/atlas, vmath,
  polyworld/[configs, worldtexts]

var font = FontAtlas(lineHeight: 10, ascent: 8)
for rune in ["A", "B", ".", "?", "雪"]:
  font.entries[rune] = @[LetterEntry(
    x: 16,
    y: 32,
    boundsX: 0,
    boundsY: -8,
    boundsWidth: 6,
    boundsHeight: 8,
    advance: 8
  )]
font.rebuildGlyphLookups()

echo "Testing centered world text and top-down atlas coordinates"
block:
  let text = layoutText(font, 128, "AB", height = 1, maximumWidth = 4)
  doAssert abs(text.size.x - 1.6'f) < 0.0001
  doAssert text.glyphs.len == 2
  doAssert abs(text.glyphs[0].offset.x + 0.8'f) < 0.0001
  doAssert abs(text.glyphs[0].offset.y - 0.2'f) < 0.0001
  doAssert text.glyphs[0].uv == vec2(0.125, 0.25)
  doAssert text.glyphs[0].size == vec2(0.6, 0.8)

echo "Testing long names are bounded and UTF-8 glyphs remain intact"
block:
  let
    long = layoutText(font, 128, "AAAAAAAAAAAA", height = 1, maximumWidth = 4)
    unicodeName = layoutText(font, 128, "雪A", height = 1)
  doAssert long.size.x <= 4
  doAssert long.glyphs.len == 5
  doAssert unicodeName.glyphs.len == 2
  doAssert unicodeName.size.x == 1.6'f

echo "Testing empty labels produce no quads"
block:
  doAssert layoutText(font, 128, "").glyphs.len == 0
  doAssert layoutText(font, 128, "A", maximumWidth = 0).glyphs.len == 0
  let players = [PlayerConfig(name: "A.bas"), PlayerConfig(name: "AB.bas")]
  let labels = layoutNames(font, 128, players)
  doAssert labels.len == 2
  doAssert labels[0] == layoutText(font, 128, "A")
  doAssert labels[1] == layoutText(font, 128, "AB")
  doAssert layoutText(font, 128, "A").size.y == 0.225'f

echo "World text tests passed"
