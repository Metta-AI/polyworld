## Native GL fixture of the production endgame overlay with real match history.
import std/[os, unittest]
import chroma, pixie, silky, vmath, windy, opengl
import polyworld/[chrome, gameuis, stats, metrics, viewers]
import ../[game, sim, ui, presets, symbols, content]

let window = newWindow("LvD finished match", ivec2(1600,1000), visible=false)
window.makeContextCurrent()
loadExtensions()
pollEvents()
let builder = newHudAtlas(2048)
builder.addDefaultFonts()
let badges = loadUnitSymbols()
doAssert builder.addImage(unitSymbolKey(PeonUnit), badges[PeonUnit])
let sk = newSilky(window, builder.atlasImage, builder.atlas)
sk.applyThemePatches()
sk.uiScale = gameUiScale(window)
var config = defaultConfig()
config.players[0].name = "Treeform"
config.players[1].name = "Commander"
config.maxTicks = 1800
initializeLocalMatch(config, [readFile("games/light_vs_dark/players/base.bas"), ""])
options.playerSlot = 1
for i in 0 ..< config.maxTicks:
  if run.world.over: break
  advanceGame()
let table = currentStats()
echo "Real match: ", matchResultHeadline(), "; tick=", table.tick,
  "; history frames=", run.history.frames.len,
  "; gold=", table.rows[0].metrics.values[GoldMetric]
var framebuffer, colorTexture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, colorTexture.addr)
glBindTexture(GL_TEXTURE_2D, colorTexture)
glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8.GLint,window.size.x,window.size.y,
  0,GL_RGBA,GL_UNSIGNED_BYTE,nil)
glBindFramebuffer(GL_FRAMEBUFFER,framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,colorTexture,0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
sk.beginUi(window,window.size)
sk.drawRect(vec2(0),window.size.vec2/sk.uiScale,rgbx(28,38,34,255))
sk.endUi()
# Call the actual LvD overlay without first drawing HUD or holding Tab.
ui.drawStatsOverlay(sk,window,[])
let image = newImage(window.size.x,window.size.y)
glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
image.flipVertical()
let output = getEnv("LVD_RESULTS_FIXTURE", getCurrentDir()/"lvd-match-results.png")
image.writeFile(output)
echo "Native fixture: ", output
suite "LvD automatic native results":
  test "actual completed game renders a stats card without Tab":
    check run.world.over
    check not window.buttonDown[KeyTab]
    check table.rows.len == 2
    check table.rows[0].metrics.values[GoldMetric] > 0
    check run.history.frames.len > 1
    let presentation = resultsLayout(statsViewport(currentLayout(window),sk.uiScale),table)
    let panel = statsLayout(presentation.viewport,table).panel
    check not overlaps(presentation.headline,panel)
    let scale = statsScale(sk.uiScale)
    let sample = (panel.origin+vec2(4))*scale
    check image[int(sample.x),int(sample.y)] != rgbx(28,38,34,255)
glDeleteTextures(1,colorTexture.addr)
glDeleteFramebuffers(1,framebuffer.addr)
window.close()
