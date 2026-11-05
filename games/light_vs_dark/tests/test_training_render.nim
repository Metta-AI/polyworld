## Real native framebuffer assertions for faction backgrounds and queue badges.
import std/[os, unittest]
import chroma, pixie, silky, vmath, windy, opengl
import polyworld/[gameuis, viewers]
import ../[content, factions, hudpresentation, symbols]

let window = newWindow("LvD training badges", ivec2(760, 270), visible = false)
window.makeContextCurrent()
loadExtensions()
pollEvents()
let builder = newHudAtlas(2048)
builder.addDefaultFonts()
let badges = loadUnitSymbols()
doAssert builder.addImage(unitSymbolKey(PeonUnit), badges[PeonUnit])
let sk = newSilky(window, builder.atlasImage, builder.atlas)
sk.applyThemePatches()
sk.uiScale = 1
var framebuffer, texture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, window.size.x, window.size.y,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
sk.beginUi(window, window.size)
sk.drawRect(vec2(0), window.size.vec2, rgbx(20,24,32,255))
for faction in Faction:
  for row in 0 .. 2:
    let slot = GameUiPanel(origin: vec2(12 + faction.ord.float32 * 92,
      10 + row.float32 * 86), size: vec2(72))
    sk.drawTrainPortrait(slot, unitSymbolKey(PeonUnit), FactionColors[faction],
      row != 1, if row == 2: 0 else: 8)
sk.endUi()
let image = newImage(window.size.x, window.size.y)
glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
image.flipVertical()
# Overlay hovered costs on the first row without ever painting over its badge.
sk.beginUi(window, window.size)
for faction in Faction:
  let slot = GameUiPanel(origin: vec2(12 + faction.ord.float32 * 92, 10),
    size: vec2(72))
  sk.drawTrainCosts(slot, 400, 50)
sk.endUi()
let withCosts = newImage(window.size.x, window.size.y)
glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,withCosts.data[0].addr)
withCosts.flipVertical()
image.writeFile(getEnv("LVD_TRAIN_FIXTURE", getTempDir() / "lvd-training-badges.png"))

suite "LvD native training button pixels":
  test "background uses the passed actual faction, not a slot palette":
    for faction in Faction:
      let x = 12 + faction.ord * 92
      check image[x+3,13] == FactionColors[faction]
      let disabled = image[x+3,99]
      check disabled.r < FactionColors[faction].r
      check disabled.g < FactionColors[faction].g
      check disabled.b < FactionColors[faction].b
  test "badge stays inside bottom right, gold text readable enabled or disabled":
    for faction in Faction:
      for row in 0 .. 1:
        let x = 12 + faction.ord * 92
        let y = 10 + row * 86
        var goldPixels = 0
        for dy in 52 ..< 70:
          for dx in 50 ..< 70:
            let pixel = image[x+dx,y+dy]
            if pixel.r > 200 and pixel.g > 160 and pixel.b < 160:
              inc goldPixels
        check goldPixels > 8
        # Opaque dark backing isolates the count from every faction tint.
        let backing = image[x+51,y+53]
        check backing.r < 40 and backing.g < 40 and backing.b < 40
        check image[x+72,y+60] == rgbx(20,24,32,255)
  test "hover costs do not cover the badge or escape the button":
    for faction in Faction:
      let x = 12 + faction.ord * 92
      for dy in 52 ..< 70:
        for dx in 50 ..< 70:
          check withCosts[x+dx,10+dy] == image[x+dx,10+dy]
      check withCosts[x+72,40] == image[x+72,40]
  test "zero queue count hides the badge entirely":
    for faction in Faction:
      let x = 12 + faction.ord * 92
      check image[x+51,182+53] != image[x+51,10+53]

glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
