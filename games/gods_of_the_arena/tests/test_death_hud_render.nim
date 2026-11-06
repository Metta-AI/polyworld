## Actual production death HUD in a native offscreen framebuffer; no game art.
import std/os
import opengl
import polyworld/viewers
include ../ui

let window = newWindow("GotA death HUD", ivec2(1600, 1000), visible = false)
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
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1600, 1000,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
let hero = Hero(id: 109, team: BlueTeam, slot: 4, state: Dying,
  deaths: 12, deathTicks: 25 * TickRate)
run = Game(world: World(phase: Playing, heroes: @[
  Hero(id: 104, team: RedTeam, slot: 3, state: Marching), hero]))
options.playerSlot = 2
let hud = placeChrome(initGameUiLayout(vec2(1600, 1000)))
let panel = deathHudPanel(hud)
doAssert panel.origin.y >= hud.heroes.origin.y + hud.heroes.size.y + 8
doAssert panel.size.x <= 300 and panel.size.y <= 64
doAssert panel.origin.x == (1600 - panel.size.x) / 2
# Top-center plate stays far from minimap, bottom chat/details and clock.
doAssert panel.origin.y + panel.size.y < 300
doAssert panel.origin.x > hud.minimap.origin.x + hud.minimap.size.x
proc render(): Image =
  sk.beginUi(window, window.size)
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)
  sk.mousePos = panel.origin + vec2(20)
  sk.drawDeathHud(hud)
  doAssert not sk.mouseConsumed, "Informational banner must not capture input"
  sk.endUi()
  result = newImage(1600, 1000)
  glReadPixels(0, 0, 1600, 1000, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()
proc ink(image: Image): int =
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let pixel = image[x, y]
      if pixel.a > 0:
        doAssert x >= panel.origin.x.int and x < (panel.origin.x + panel.size.x).int
        doAssert y >= panel.origin.y.int and y < (panel.origin.y + panel.size.y).int
        if pixel.r > 180: inc result
let dead = render()
doAssert dead.ink > 200, "Prominent DEAD title/timer must produce readable text pixels"
doAssert render().data == dead.data, "Paused/unapplied network ticks must not drift"
hero.state = Marching
doAssert render().ink == 0
hero.state = Dying
options.playerSlot = 1
doAssert render().ink == 0, "Other dead hero is not the local hero"
options.playerSlot = 0
doAssert render().ink == 0
options.playerSlot = 2
networkSpectator = true
doAssert render().ink == 0
networkSpectator = false
run.replayMode = true
doAssert render().ink == 0
run.replayMode = false
run.world.phase = Drafting
doAssert render().ink == 0
let source = readFile(currentSourcePath().parentDir / "../ui.nim")
doAssert "sk.draw9Patch(\"window.9patch\", sk.theme.windowPatch" in source,
  "Death banner must use the Silky window theme rather than bespoke rectangles"
doAssert "sk.drawDeathHud(chrome)" in source, "Ordinary HUD must call production banner"
dead.writeFile(getEnv("GOTA_DEATH_FIXTURE", getTempDir() / "gota-death-hud.png"))
echo "PASS death HUD FBO: text ink=", dead.ink, "; bounded, passive, local hero, paused, alive/draft/watch hidden"
glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
