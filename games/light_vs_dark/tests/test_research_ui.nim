## Native actual HUD clicks -> Controls -> authoritative research. No browser.
import std/[importutils, os]
import windy/internal
import ../[presets, researchpresentation]
include ../graphics
privateAccess(Window)

window = newWindow("LvD research HUD", ivec2(1280, 900), visible = false)
window.makeContextCurrent()
loadExtensions()
pollEvents()
let atlas = buildUiAtlas(factionOrder(DefaultSeed.int64))
sk = newSilky(window, atlas.atlasImage, atlas.atlas)
sk.applyThemePatches()
var config = defaultConfig(2)
config.maxTicks = TickRate * 600
config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
run = newLocalMatch(config, ["", ""])
options.playerSlot = 1
resetHumanCommunication()
clearPlayerCommands()
run.world.players[0].gold = 20000
run.world.players[0].wood = 20000
for b in run.world.buildings.mitems:
  if b.owner == 0:
    primaryId = b.id
    b.kind = BlacksmithBuilding
    break
# A completed prerequisite, registered via normal build path.
block prerequisite:
  var built = false
  for y in 1'i32 ..< run.world.map.side - 4:
    for x in 1'i32 ..< run.world.map.side - 4:
      if run.world.canPlace(BarracksBuilding, x, y):
        doAssert run.world.applyBuild(0, run.world.units[0].id,
          BarracksBuilding.ord.int32, x, y)
        run.world.buildings[^1].state = BuildingComplete
        run.world.buildings[^1].hp = run.world.buildings[^1].maxHp
        discard run.world.applyCancel(0, run.world.units[0].id)
        built = true
        break
    if built: break
  doAssert built
selectedIds = @[primaryId]
var director = initActionCam(subjectMode = true)
let colors = @[rgbx(230,100,100,255), rgbx(100,100,230,255)]
proc drawHud(at: Vec2, pressed: set[Button] = {}) =
  sk.uiScale = gameUiScale(window)
  window.state.mousePos = ivec2((at.x * sk.uiScale).int32, (at.y * sk.uiScale).int32)
  window.state.perFrame = PerFrame(buttonPressed: pressed)
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  sk.beginUi(window, window.size)
  drawUi(sk, window, transport, cameraTarget, cameraDistance, viewMode,
    primaryId, selectedIds, followSelection, director, colors)
  sk.endUi()
  window.state.perFrame = PerFrame()

# beginFrame returns the same inner geometry without consuming input.
sk.beginUi(window, window.size)
let build = sk.beginFrame(currentLayout(window).panel(GameUiRegion.BottomRight, PanelBuild)).buildPanels()
sk.endUi()
drawHud(build.tabs[2].origin + vec2(10), {MouseLeft})
doAssert commandTab == 2
let click = build.contents.origin + vec2(30,30)
let before = run.stateHash()
drawHud(click, {MouseLeft})
doAssert run.stateHash() == before, "HUD must enqueue, not mutate simulation"
run.networked = true
run.flushPlayerCommands()
doAssert run.submissions.len == 1, "Actual research card click must submit one normal command"
let action = run.submissions[0]
doAssert action.kind == ActionResearch and action.first == TemperedEdges.ord.int32
doAssert action.entityId == primaryId and action.playerId == 0
doAssert run.stateHash() == before, "Network submission must wait for authority"
doAssert run.world.applyReplayAction(action)
doAssert run.world.researchInProgress(0, TemperedEdges)
# Every unavailable route is a no-op through the actual HUD.
let producerId = primaryId
template producer: untyped = run.world.buildings[run.world.buildingIndex(producerId)]
proc noCommand(at = click) =
  let count = run.submissions.len
  drawHud(at, {MouseLeft})
  run.flushPlayerCommands()
  doAssert run.submissions.len == count
noCommand() # researching
noCommand(build.contents.origin + vec2(138,30)) # other category, busy producer
# Cancel uses the authoritative path, then verify replay/watch/chat guards.
doAssert run.world.applyCancel(0, primaryId)
run.replayMode = true
noCommand()
run.replayMode = false
options.playerSlot = 0
noCommand()
options.playerSlot = 1
doAssert humanCommunicationKey(KeyEnter)
humanCommunicationRelease(KeyEnter)
noCommand()
resetHumanCommunication()
producer.state = BuildingUnderConstruction
noCommand()
producer.state = BuildingComplete
run.world.players[0].gold = 0
noCommand()
run.world.players[0].gold = 20000
producer.owner = 1
noCommand()
producer.owner = 0
primaryId = NoEntity
noCommand()
primaryId = run.world.units[0].id
noCommand()
primaryId = producerId
# Each producer offers only its catalog; each tier clicks through Controls.
for kind in ResearchKind:
  producer.kind = researchBuilding(kind)
  doAssert kind in run.world.researchKinds(0, primaryId)
  let slotIndex = if kind == RunedPlating: 1 else: 0
  let at = build.contents.origin + vec2(30 + slotIndex.float32 * 108,30)
  for tier in 1'i32 .. MaxResearchLevel:
    let count = run.submissions.len
    let baseline = run.stateHash()
    drawHud(at, {MouseLeft})
    run.flushPlayerCommands()
    doAssert run.submissions.len == count + 1
    doAssert run.stateHash() == baseline
    let submitted = decodeSubmission(encodeSubmission(run.submissions[^1]))
    doAssert submitted.kind == ActionResearch and submitted.first == kind.ord.int32
    let gold = run.world.players[0].gold
    doAssert run.world.applyReplayAction(submitted)
    doAssert run.world.players[0].gold == gold - researchStats(kind,tier).gold
    let card = run.world.researchCard(0, primaryId, kind)
    doAssert card.active and card.ticksRemaining == researchStats(kind,tier).ticks
    for tick in 0 ..< card.ticks: run.world.tickWorld(nil)
    doAssert run.world.researchLevel(0, kind) == tier
  doAssert run.world.researchCard(0, primaryId, kind).researchStatus == "MAX LEVEL"
  noCommand(at)
# Full production HUD and tooltip in a real offscreen framebuffer.
var framebuffer, texture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, window.size.x, window.size.y,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
proc snapshot(name: string) =
  let image = newImage(window.size.x, window.size.y)
  glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
  image.flipVertical()
  image.writeFile(getEnv("LVD_RESEARCH_UI_FIXTURE", getTempDir()) / name)
  var nonblack = 0
  for pixel in image.data:
    if pixel.r > 80: inc nonblack
  doAssert nonblack > 1000, "Actual HUD atlas pixels must render"
  let cardEdge = (build.contents.origin + vec2(0, 1)) * gameUiScale(window)
  if name == "lvd-research-ui.png":
    doAssert image[cardEdge.x.int, cardEdge.y.int].a > 0
producer.kind = BlacksmithBuilding
run.world.players[0].researchLevels[TemperedEdges] = 0
run.world.players[0].researchLevels[RunedPlating] = 0
run.world.players[0].gold = 20000
run.world.players[0].wood = 20000
doAssert run.world.applyResearch(0, primaryId, TemperedEdges.ord.int32)
for _ in 0 ..< researchStats(TemperedEdges,1).ticks div 2: run.world.tickWorld(nil)
drawHud(click)
sleep(550)
drawHud(click)
snapshot("lvd-research-ui.png")
# Selected worker retains cargo and displays armor; newly selected Knight uses
# current player stats rather than a spawn-time cached value.
primaryId = run.world.units[0].id
selectedIds = @[primaryId]
run.world.players[0].researchLevels[RunedPlating] = 3
doAssert run.world.selectedResearchStats(0, PeonUnit)[2] == "Armor: 6"
doAssert run.world.units[0].owner == 0
drawHud(vec2(500,400))
snapshot("lvd-research-worker.png")
run.world.units[0].kind = KnightUnit
drawHud(vec2(500,400))
snapshot("lvd-research-knight.png")
glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
echo "PASS native actual card clicks: all four upgrades, all tiers, authority, locks, replay/watch/chat; full HUD FBO"
window.close()
