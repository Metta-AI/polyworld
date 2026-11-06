## Actual LvD HUD routing and native FBO pixels; no browser or OS input claim.
import std/[importutils, os]
import windy/internal
import opengl
import polyworld/viewers
import ../presets
include ../ui
privateAccess(Window)

let window = newWindow("LvD global tooltip regression", ivec2(1280,900), visible = false)
window.makeContextCurrent()
loadExtensions()
pollEvents()
let atlas = newHudAtlas(4096)
let badges = loadUnitSymbols()
for kind in UnitKind:
  doAssert atlas.addImage(unitSymbolKey(kind), badges[kind])
let factionList = factionOrder(DefaultSeed.int64)
for player in 0'i32 ..< int32(min(factionList.len, FactionFiles.len)):
  for kind in BuildingKind:
    if kind == GoldMineBuilding and player != LightPlayer: continue
    doAssert atlas.addImage(buildingPortraitKey(player, kind),
      readImage(buildingPortraitPath(factionList[Faction(player)], kind)))
atlas.addDefaultFonts()
let sk = newSilky(window, atlas.atlasImage, atlas.atlas)
sk.applyThemePatches()
var config = defaultConfig(2)
config.maxTicks = TickRate * 600
config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
run = newLocalMatch(config, ["", ""])
options.playerSlot = 1
var producerIndex = -1
for i, building in run.world.buildings:
  if building.owner == 0:
    producerIndex = i
    break
doAssert producerIndex >= 0
var primaryId = run.world.buildings[producerIndex].id
var selectedIds = @[primaryId]
var transport = initPlayer(live = true, durationTicks = config.maxTicks, playing = true)
var viewMode = 1'i32
var follow = false
var director = initActionCam(subjectMode = true)
let colors = @[rgbx(230,100,100,255), rgbx(100,100,230,255)]
var framebuffer, texture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, window.size.x, window.size.y,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
proc frame(at: Vec2, press: set[Button] = {}) =
  sk.uiScale = gameUiScale(window)
  window.state.mousePos = ivec2((at.x * sk.uiScale).int32, (at.y * sk.uiScale).int32)
  window.state.perFrame = PerFrame(buttonPressed: press)
  glClearColor(0,0,0,1)
  glClear(GL_COLOR_BUFFER_BIT)
  sk.beginUi(window, window.size)
  drawUi(sk, window, transport, vec3(0), 45, viewMode, primaryId,
    selectedIds, follow, director, colors)
  sk.endUi()
  window.state.perFrame = PerFrame()
proc pixels(): Image =
  result = newImage(window.size.x, window.size.y)
  glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,result.data[0].addr)
  result.flipVertical()
sk.uiScale = gameUiScale(window)
sk.beginUi(window, window.size)
let build = sk.beginFrame(currentLayout(window).panel(GameUiRegion.BottomRight, PanelBuild)).buildPanels()
sk.endUi()
commandTab = 0
let a = build.slots[0].origin + vec2(20)
let b = build.slots[1].origin + vec2(20)
frame(a)
doAssert not commandHover.visible
sleep(550)
frame(a)
doAssert commandHover.visible
frame(b)
doAssert commandHover.visible and commandHover.target.building == FarmBuilding
let panel = commandHover.panel
let retained = panel.origin + panel.size / 2
let before = pixels()
frame(retained, {MouseLeft})
doAssert commandHover.visible and commandHover.target.building == FarmBuilding
doAssert pendingBuild == -1, "Popup cannot activate an underlying build action"
doAssert window.mouseOverUi(retained), "Popup blocks world input outside HUD panels"
# A clamped card may cover a minimap/control: input must respect that same
# previous-frame panel before special-case minimap routing.
let previousPanel = commandHover.panel
let mini = currentLayout(window).panel(GameUiRegion.TopRight, PanelMinimap).minimapPanels().map
commandHover.panel = mini
sk.mousePos = mini.origin + vec2(20)
window.state.buttonDown = {MouseLeft}
window.state.perFrame = PerFrame(buttonPressed: {MouseLeft})
doAssert not window.hudClicked(sk, mini), "No covered HUD action"
var pan = false
var camera = vec3(0)
updateMinimapCamera(window, sk.mousePos, camera, pan, follow)
doAssert not pan and camera == vec3(0), "No covered minimap pan"
window.state.perFrame = PerFrame()
window.state.buttonDown = {}
commandHover.panel = previousPanel
let after = pixels()
var ink = 0
let scale = gameUiScale(window)
for y in int((panel.origin.y+4)*scale) ..< int((panel.origin.y+panel.size.y-4)*scale):
  for x in int((panel.origin.x+4)*scale) ..< int((panel.origin.x+panel.size.x-4)*scale):
    doAssert before[x,y] == after[x,y], "Retained card pixels must be identical"
    if after[x,y].r > 140: inc ink
doAssert ink > 100, "Real tooltip text/icon pixels must be rendered"
# All catalog paths share warmth (no intervening empty frame).
commandTab = 1
frame(a)
doAssert commandHover.visible and commandHover.target.kind == UnitCommandTooltip
run.world.buildings[producerIndex].kind = BlacksmithBuilding
commandTab = 2
let researchAt = researchPanels(build.contents)[0].origin + vec2(20)
frame(researchAt)
doAssert commandHover.visible and commandHover.target.kind == ResearchCommandTooltip
let researchPopup = commandHover.panel.origin + commandHover.panel.size / 2
frame(researchPopup)
doAssert commandHover.visible and commandHover.target.kind == ResearchCommandTooltip
# Dead/missing producer retires even when the pointer remains on the popup.
run.world.buildings[producerIndex].hp = 0
frame(researchPopup)
doAssert not commandHover.visible, "Dead producer must retire its popup"
commandTab = 0
frame(a)
doAssert not commandHover.visible
sleep(550)
frame(a)
doAssert commandHover.visible
frame(vec2(500,400))
doAssert not commandHover.visible
frame(b)
doAssert not commandHover.visible
# Explicit pause clears warmth without relying on a long skipped-frame timeout.
sleep(550)
frame(b)
doAssert commandHover.visible
transport.playing = false
frame(b)
doAssert not commandHover.visible
transport.playing = true
frame(b)
doAssert not commandHover.visible
# Leaving/replacing the selected producer cannot keep an orphaned research card.
run.world.buildings[producerIndex].hp = 100
primaryId = run.world.buildings[producerIndex].id
commandTab = 2
frame(researchAt)
sleep(550)
frame(researchAt)
doAssert commandHover.visible
primaryId = NoEntity
frame(commandHover.panel.origin + commandHover.panel.size / 2)
doAssert not commandHover.visible
primaryId = run.world.buildings[producerIndex].id
frame(researchAt)
sleep(550)
frame(researchAt)
doAssert commandHover.visible
let missingPopup = commandHover.panel.origin + commandHover.panel.size / 2
run.world.buildings.delete(producerIndex)
frame(missingPopup)
doAssert not commandHover.visible
# Lifecycle clearing is immediate even while still over the same target.
commandTab = 0
frame(a)
sleep(550)
frame(a)
doAssert commandHover.visible
resetHudTooltips()
frame(a)
doAssert not commandHover.visible
let output = getEnv("LVD_TOOLTIP_FIXTURE", getTempDir()) / "lvd-tooltip-retained.png"
after.writeFile(output)
glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
echo "PASS native HUD: A delayed -> B instant -> popup retained -> empty clear -> C delayed; build/train/research, death, pause, FBO pixels: ", output
