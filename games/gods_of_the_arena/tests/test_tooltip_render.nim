## Native offscreen proof: a visible card survives mouse motion.
import std/os
import pixie, silky, vmath, windy, opengl
import polyworld/[gameuis, viewers]
import ../[content, tooltips]

let window = newWindow("GotA tooltip persistence", ivec2(800, 700), visible = false)
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
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 800, 700,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
var session: TooltipSession
let target = TooltipTarget(id: "ability:1:0", card: abilityDetails(FirebrandSword, 4),
  anchor: GameUiPanel(origin: vec2(360, 610), size: vec2(64)), key: "Q")
let other = TooltipTarget(id: "item:1:0", card: itemDetails(RangerBoots),
  anchor: GameUiPanel(origin: vec2(40, 610), size: vec2(64)), key: "1")
proc render(now: float64, mouse: Vec2): Image =
  session.updateTooltip([target, other], mouse, vec2(800, 700), now)
  sk.beginUi(window, window.size)
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)
  sk.mousePos = mouse
  sk.mouseIdleTime = 0
  sk.drawTooltip(session, vec2(800, 700))
  sk.endUi()
  result = newImage(800, 700)
  glReadPixels(0, 0, 800, 700, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()
proc ink(image: Image): int =
  for y in 100 ..< 600:
    for x in 200 ..< 600:
      if image[x, y].r > 140: inc result

doAssert render(1.0, vec2(361, 611)).ink == 0
doAssert render(1.49, vec2(420, 670)).ink == 0
let image = render(1.5, vec2(400, 650))
doAssert image.ink > 200, "Visible tooltip disappeared on mouse motion"
doAssert render(2.0, vec2(421, 671)).ink == image.ink
doAssert render(2.1, vec2(700, 650)).ink == image.ink
doAssert render(2.4, vec2(700, 650)).ink == image.ink
doAssert render(2.41, session.panel.origin + vec2(20)).ink == image.ink
doAssert sk.mouseConsumed, "Tooltip panel must consume Silky pointer input"
doAssert render(4.0, session.panel.origin + vec2(30)).ink == image.ink
doAssert render(4.1, vec2(700, 650)).ink == image.ink
doAssert render(4.46, vec2(700, 650)).ink == 0
doAssert not session.tooltipContains(vec2(300, 300)), "Expired card must not block input"
doAssert render(5.0, target.anchor.origin + vec2(20)).ink == 0
doAssert render(5.5, target.anchor.origin + vec2(20)).ink == image.ink
let switched = render(5.51, other.anchor.origin + vec2(20))
doAssert switched.ink > 100, "Warmed item card must draw on the switching frame"
doAssert session.current.id == other.id
var differentPixels = 0
for i in 0 ..< switched.data.len:
  if switched.data[i] != image.data[i]: inc differentPixels
doAssert differentPixels > 200, "Switch must draw the new content and geometry"
doAssert render(50.0, session.panel.origin + vec2(20)).ink == switched.ink
image.writeFile(getEnv("GOTA_TOOLTIP_FIXTURE", getTempDir() / "gota-tooltip.png"))
echo "PASS native framebuffer: delay, motion, panel, expiry, instant warm item switch; ink=", image.ink,
  "; switched ink=", switched.ink, "; changed pixels=", differentPixels
glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
