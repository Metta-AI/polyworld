## Native GL fixture of the production endgame overlay with real match history.
import std/[os, unittest, strutils]
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
    let panel = presentation.panel
    check presentation.headline.origin.y >= panel.origin.y
    check presentation.headline.origin.y + presentation.headline.size.y <= panel.origin.y + panel.size.y
    let scale = statsScale(sk.uiScale)
    let sample = (panel.origin+vec2(4))*scale
    check image[int(sample.x),int(sample.y)] != rgbx(28,38,34,255)
proc captureCase(name: string, size: IVec2): Image =
  window.size = size
  pollEvents()
  sk.uiScale = gameUiScale(window)
  glBindTexture(GL_TEXTURE_2D, colorTexture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y,
    0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glViewport(0, 0, size.x, size.y)
  glClearColor(28.0/255, 38.0/255, 34.0/255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  ui.drawStatsOverlay(sk, window, [rgbx(76,154,239,255), rgbx(192,124,234,255)])
  result = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()
  let scale = statsScale(sk.uiScale)
  let slots = statsLayout(statsViewport(currentLayout(window), sk.uiScale),
    currentStats(), currentStatsOptions())
  when declared(fittedStatsHeadline):
    if run.world.over and run.world.winner >= 0:
      doAssert sk.fittedStatsHeadline(currentStatsOptions(), slots.headline.size.x).endsWith(" wins"),
        "Long names must not truncate the victory declaration"
  else:
    doAssert false, "Need suffix-preserving headline fitting"
  var ink = 0
  for y in 0 ..< size.y:
    for x in 0 ..< size.x:
      let point = vec2(x.float32, y.float32) / scale
      let pixel = result[x,y]
      if slots.headline.contains(point) and pixel.r > 170 and pixel.g > 130 and pixel.b < 150:
        inc ink
      if not GameUiPanel(origin: slots.panel.origin - vec2(3),
          size: slots.panel.size + vec2(6)).contains(point):
        doAssert pixel == rgbx(28,38,34,255), "Stats escaped the panel: " & name
  doAssert ink > 40, "Headline must be visible within its reserved panel: " & name
  let path = output.parentDir / ("lvd-score-" & name & ".png")
  result.writeFile(path)
  echo "FBO ", name, ": ", size, "; headline ink=", ink, "; ", path

# Render the actual production overlay at compact and full readable scales.
run.recorder.data.config.players[0].name = "A very long departed commander name with spaces and punctuation :)"
run.world.players[1].goldGathered = 900000
run.world.winner = 0 # Winner label is independent of the highest Score.
discard captureCase("compact-winner-not-first", ivec2(640,480))
run.world.winner = -1
discard captureCase("draw", ivec2(1000,700))
run.world.over = false
discard captureCase("time-limit", ivec2(1920,1080))
# Release GL resources.
glDeleteTextures(1,colorTexture.addr)
glDeleteFramebuffers(1,framebuffer.addr)
window.close()
