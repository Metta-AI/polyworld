## Actual atlas + native GL pixels, not RGB constants or mocked draw calls.
import std/[os, unittest]
import chroma, pixie, silky, vmath, windy, opengl
import polyworld/[chrome, gameuis, viewers]
import ../[assets, content, factions, hudpresentation, layouts, sim, symbols]


let window = newWindow("LvD HUD regression", ivec2(1140, 470), visible = false)
window.makeContextCurrent()
loadExtensions()
pollEvents()
let builder = newHudAtlas(2048)
builder.addDefaultFonts()
let badges = loadUnitSymbols()
doAssert builder.addImage(unitSymbolKey(PeonUnit), badges[PeonUnit])
for kind in TownHallBuilding .. BuildableHigh:
  let image = readImage(buildingPortraitPath(Faction(0), kind))
  var count, luminance: int
  for pixel in image.data:
    if pixel.a > 240:
      inc count
      luminance += (pixel.r.int + pixel.g.int + pixel.b.int) div 3
  echo "Atlas ", kind, " opaque mean RGB ", luminance div max(count, 1)
  doAssert builder.addImage($kind, image)
let sk = newSilky(window, builder.atlasImage, builder.atlas)
sk.applyThemePatches()
sk.uiScale = 1
# Offscreen framebuffer avoids hidden Cocoa drawable allocation/timing.
var framebuffer, colorTexture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, colorTexture.addr)
glBindTexture(GL_TEXTURE_2D, colorTexture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, window.size.x, window.size.y,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTexture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
sk.beginUi(window, window.size)
sk.drawRect(vec2(0), window.size.vec2, rgbx(20,24,32,255))
sk.drawLabel("AFFORDABLE + UNLOCKED", vec2(20, 8), vec2(700, 24), rgbx(255,255,255,255), "Hud")
sk.drawLabel("UNAVAILABLE (same portraits)", vec2(20, 122), vec2(700, 24), rgbx(190,190,190,255), "Hud")
for kind in TownHallBuilding .. BuildableHigh:
  let x = 20 + kind.ord * 90
  sk.drawBuildPortrait(GameUiPanel(origin: vec2(x.float32,40), size: vec2(72)), $kind, true)
  sk.drawBuildPortrait(GameUiPanel(origin: vec2(x.float32,154), size: vec2(72)), $kind, false)
for i in 0 .. 2:
  let panel = GameUiPanel(origin: vec2(8 + i.float32 * 378, 239), size: PanelSelection)
  sk.drawPanel(panel)
  let selection = panel.selectionPanels(true)
  sk.drawWellImage(selection.portrait, unitSymbolKey(PeonUnit), iconSize = 128)
  let worker = Unit(kind: PeonUnit, carryWood: (if i == 0: 100 else: 0),
    carryGold: (if i == 1: 100 else: 0))
  sk.drawWorkerCargo(selection.cargo, worker)
  sk.drawLabel("Selected peon", selection.name.origin, selection.name.size,
    rgbx(230,230,230,255), "Small")
  for slot in selection.units:
    sk.drawWellImage(slot, unitSymbolKey(PeonUnit), iconSize = 32)
sk.endUi()
let image = newImage(window.size.x, window.size.y)
glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
image.flipVertical()
let output = getEnv("LVD_HUD_FIXTURE", getCurrentDir() / "lvd-hud-availability.png")
image.writeFile(output)
echo "Native fixture: ", output
proc brightness(x,y: int): float =
  for dy in 8 ..< 64:
    for dx in 8 ..< 64:
      let pixel = image[x+dx,y+dy]
      result += (pixel.r.float + pixel.g.float + pixel.b.float) / 3
suite "LvD native build availability contrast":
  test "every actual building portrait is at least three times brighter when ready":
    for kind in TownHallBuilding .. BuildableHigh:
      let x = 20 + kind.ord * 90
      let ratio = brightness(x,40) / max(1.0,brightness(x,154))
      echo kind, " ready/unavailable luminance ratio: ", ratio
      check ratio >= 3.0
      let border = image[x+1,41]
      check border.r >= 220
      check border.g >= 180
  test "cargo and multiselect grid never overlap or overflow the selection panel":
    let panel = GameUiPanel(origin: vec2(0), size: PanelSelection)
    let selection = panel.selectionPanels(true)
    for slot in selection.units:
      check slot.origin.y >= selection.cargo.origin.y + selection.cargo.size.y
      check slot.origin.y + slot.size.y <= panel.size.y
      check slot.origin.x + slot.size.x <= panel.size.x
glDeleteTextures(1, colorTexture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
