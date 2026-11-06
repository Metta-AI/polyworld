## Native FBO proof: explicitly TEMPORARY existing glyphs, contrast and progress.
## Production chooses generated icon keys when present; generation is auth-blocked.
import std/[os, unittest]
import chroma, pixie, silky, vmath, windy, opengl
import polyworld/[gameuis, viewers]
import ../researchpresentation

let window = newWindow("LvD research cards", ivec2(340, 344), visible = false)
window.makeContextCurrent()
loadExtensions()
pollEvents()
let builder = newHudAtlas(2048)
builder.addDefaultFonts()
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
for row in 0 .. 1:
  let slots = researchPanels(GameUiPanel(origin: vec2(11, (8 + row * 168).float32), size: vec2(318,160)))
  for i in 0 .. 2:
    let card = ResearchCard(name: ["Runed Plating", "Tempered Edges", "Keenflight Arrows"][i],
      icon: ["armor", "attack", "bow"][i], level: i.int32,
      allowed: row == 0, active: row == 1 and i == 0,
      queued: row == 1 and i == 1,
      reason: if row == 1: "Need resources" else: "",
      gold: 600, wood: 200, ticks: 600, ticksRemaining: 300)
    sk.drawResearchCard(slots[i], card, 30)
sk.endUi()
let image = newImage(window.size.x, window.size.y)
glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
image.flipVertical()
image.writeFile(getEnv("LVD_RESEARCH_FIXTURE", getTempDir() / "lvd-research-cards.png"))

suite "Native research card rendering":
  test "ready border brighter than unavailable border":
    check image[11,9].r > image[11,177].r
  test "all three actual glyphs render within icon wells":
    for i in 0 .. 2:
      var bright = 0
      for y in 18 ..< 54:
        for x in (36 + i*108) ..< (76 + i*108):
          if image[x,y].r > 150: inc bright
      check bright > 30
  test "active progress fills half the card with gold":
    check image[30,333].r > 180
    check image[90,333].r < 100
  test "cards never draw outside the command contents":
    check image[10,50] == rgbx(20,24,32,255)
    check image[329,50] == rgbx(20,24,32,255)
glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
