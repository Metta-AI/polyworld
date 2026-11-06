## Native production input -> queued network intent -> real mesh silhouette pixels.
## Explicit focus tests the input routine without activating the user's desktop.
import std/[unittest, macros, importutils]
import windy/internal
include ../graphics
privateAccess(Window)

macro targetRoutine(name: static[string]): untyped =
  for node in parseStmt(staticRead("../graphics.nim")):
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkAsgn and child[1].kind == nnkLambda and
            ((name == "buttonHandler" and child[0].repr == "window.onButtonPress") or
             (name == "releaseHandler" and child[0].repr == "window.onButtonRelease")):
          return child
        if child.kind == nnkProcDef and child[0].repr == name: return child
  error("Missing production routine: " & name)

window = newWindow("LvD target silhouette regression", ivec2(1200, 900), visible = false)
window.makeContextCurrent()
loadExtensions()
sk = Silky(uiScale: 1)
options.playerSlot = 1
viewMode = 1
initTerrain(treeStyle = NoTrees, rockStyle = NoRocks,
  terrainStyle = GeneratedTerrain, settings = TerrainAssets(size: 256))
initSunShadows()
sunShadowsEnabled = false
let grove = generateGrove(DefaultSeed, {LightTree, LightRock})
let buildingArt = loadBuildingArt(grove, factions = [Emerald, Emerald])
let scene = newCharacterScene(window)
scene.useToonShading()
setEnvironmentPalette(scene.toon)
let roster = readCharacterRoster([Emerald])
let manifest = readManifest(ChargenLibrary)
var unitModels = newSeq[array[UnitKind, CharacterModel]](2)
var unitClips = newSeq[array[UnitKind, array[AnimationSlot, int]]](2)
for kind in [PeonUnit, SoldierUnit]:
  let model = loadUnitModel(manifest, roster.players[0][kind.ord], kind)
  for player in 0..1:
    unitModels[player][kind] = model
    for slot in AnimationSlot:
      unitClips[player][kind][slot] = model.clipIndex(kind.unitClip(slot))
var selectionOutline = initSelectionOutline()
var framebuffer, texture, depth: GLuint
glGenFramebuffers(1, framebuffer.addr)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1200, 900, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
glGenRenderbuffers(1, depth.addr)
glBindRenderbuffer(GL_RENDERBUFFER, depth)
glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, 1200, 900)
glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE

# Shared production shader/GL composite, redirect only its window framebuffer
# to a readable color/depth FBO (hidden macOS windows have blank backbuffers).
privateAccess(SelectionOutline)
macro offscreenComposite(): untyped =
  for node in parseStmt(staticRead("../../../src/polyworld/selectionoutlines.nim")):
    if node.kind == nnkProcDef and node[0].repr == "drawOutline*":
      result = node
      result[0] = ident("drawOutline")
      result[^1][1] = parseStmt("glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)")[0]
      return
  error("Missing outline composite")
offscreenComposite()

proc checkTarget(kind: string, armed = false, invalid = "") =
  run = Game(world: newWorld(generateMap(DefaultSeed), TickRate * 60))
  viewMode = 1
  let sampleMine = run.world.buildings[0]
  run.world.buildings.setLen(0)
  run.world.units.setLen(0)
  clearPlayerCommands()
  lineGesture.cancelLine()
  cameraTarget = vec3(0)
  cameraEye = vec3(0, 16, 16)
  let half = run.world.map.side div 2
  let id = run.world.spawnUnit(0, PeonUnit, tile2(half-4, half))
  selectedIds = @[id]
  primaryId = id
  let tile = (half * run.world.map.side + half+3).int32
  run.world.treeWood[tile] = 100
  for cell in run.world.visibleStamp[0].mitems: cell = run.world.visionGeneration[0]
  let scenery = @[GrovePlacement(kind: LightTree, tile: tile, variant: 0,
    position: vec3(3.5, 0, 0.5), scale: 1, rotation: 0.7)]
  var target = tile
  if kind == "unit":
    target = run.world.spawnUnit(1, SoldierUnit, tile2(half+3, half))
  elif kind in ["mine", "building"]:
    var structure = Building(id: sampleMine.id, owner: (if kind == "mine": -1'i32 else: 1'i32),
      kind: (if kind == "mine": GoldMineBuilding else: FarmBuilding),
      origin: tile2(half+2, half-1), hp: 500, goldLeft: 1000, state: BuildingComplete)
    structure.footprint = BuildingTable[structure.kind].footprint
    run.world.buildings.add structure
    target = structure.id
  var clickMarks = initClickMarks(orderMarkSettings(false))
  var attackClickMarks = initClickMarks(orderMarkSettings(true))
  var targetFlash: TargetFeedback
  defer:
    clickMarks.closeClickMarks()
    attackClickMarks.closeClickMarks()
  targetRoutine("playerMode")
  targetRoutine("screenPosition")
  targetRoutine("pickEntity")
  targetRoutine("structureAtTile")
  targetRoutine("buildGhostOrigin")
  targetRoutine("queuePendingBuild")
  targetRoutine("clickTilePoint")
  targetRoutine("issueSelectedMove")
  targetRoutine("updatePlayerOrder")
  targetRoutine("drawBuildingOutline")
  targetRoutine("drawSelectedOutline")
  targetRoutine("drawTargetOutline")
  let view = lookAt(cameraEye, vec3(0), vec3(0,1,0))
  let projection = perspective(45'f32, 1200'f32/900, 0.1, 1000)
  let vp = projection * view
  sk.uiScale = gameUiScale(window)
  let point =
    if kind == "tree": screenPosition(scenery[0].position + vec3(0, 1, 0), vp)
    elif kind == "unit": screenPosition(renderPoint(run.world.units[run.world.unitIndex(target)]) +
      vec3(0, UnitHeights[SoldierUnit]*0.5'f32, 0), vp)
    else: screenPosition(buildingCentre(run.world.buildings[0]) + vec3(0,1.4,0), vp)
  sk.mousePos = point / sk.uiScale
  window.state.mousePos = ivec2(point.x.int32, point.y.int32)
  inputBindings = LvdControlProfile.defaults
  resetHumanCommunication()
  if invalid == "dead": run.world.units[run.world.unitIndex(id)].hp = 0
  if invalid == "inside": run.world.units[run.world.unitIndex(id)].state = UnitInMine
  if invalid == "depleted": run.world.buildings[0].goldLeft = 0
  if invalid == "full":
    run.world.units[run.world.unitIndex(id)].orderQueue.setLen(MaxUnitOrders)
  if invalid == "unseen":
    viewMode = 0 # Even all-view picking must never disclose targets to a human.
    for cell in run.world.visibleStamp[0].mitems: cell = run.world.visionGeneration[0] + 1
  var
    matchMenu = HiddenMatchMenu
    preferences: Preferences
    network: NetworkMatch
    actionCam = initActionCam(subjectMode = true)
  targetRoutine("buttonHandler")
  targetRoutine("releaseHandler")
  shortcutState.resetShortcut()
  if armed:
    window.onButtonPress(KeyA)
    window.onButtonRelease(KeyA)
    require attackMoveArmed
    window.state.buttonDown = {MouseLeft}
    window.state.perFrame = PerFrame(buttonPressed: {MouseLeft})
  else:
    window.state.buttonDown = {MouseRight}
    window.state.perFrame = PerFrame(buttonPressed: {MouseRight})
    updatePlayerOrder(vp, focused = invalid != "focus")
    window.state.buttonDown = {}
    window.state.perFrame = PerFrame(buttonReleased: {MouseRight})
  if invalid == "full": window.state.buttonDown.incl KeyLeftShift
  let before = run.stateHash()
  updatePlayerOrder(vp, focused = invalid != "focus")
  run.networked = true
  run.recorder = initReplayRecorder(Setup(gridTiles: run.world.map.side.uint16,
    maximumTicks: (TickRate*60).uint32, decisionTicks: DecisionTicks.uint16,
    players: @[ReplayPlayerSetup(id: 0), ReplayPlayerSetup(id: 1)]))
  run.flushPlayerCommands()
  if invalid.len > 0 and not (invalid == "unseen" and kind in ["tree", "mine"]):
    check run.submissions.len == 0
    check targetFlash.kind == NoTargetFlash
    return
  require run.submissions.len == 1
  let attack = kind in ["unit", "building"]
  check run.submissions[0].kind == (if attack: ActionAttack else: ActionHarvest)
  check run.submissions[0].first == target
  if not attack: check run.submissions[0].second == (if kind == "tree": 1 else: 0)
  check run.stateHash() == before
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glViewport(0,0,1200,900)
  glClearColor(0,0,0,1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  drawSelectedOutline(view, projection, vp)
  drawTargetOutline(view, projection, vp)
  glFinish()
  let image = newImage(1200,900)
  glReadPixels(0,0,1200,900,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
  var green, red, yellow: int
  for pixel in image.data:
    if pixel.g > 100 and pixel.g.int > pixel.r.int*14 div 10: inc green
    if pixel.r > 100 and pixel.r.int > pixel.g.int*2: inc red
    if pixel.r > 150 and pixel.g > 100 and pixel.b < 80: inc yellow
  echo kind," armed=",armed," silhouette green=",green," red=",red," selection yellow=",yellow
  if attack:
    check red > 100
    check green == 0
  else:
    check green > 100
    check red == 0
  check yellow > 100
  check targetFlash.target == target
  check targetFlash.remaining == ClickMarkDuration
  let retained = targetFlash
  proc checkHidden(resourceVisible = false) =
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
    glClearColor(0,0,0,1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    drawSelectedOutline(view, projection, vp)
    drawTargetOutline(view, projection, vp)
    glReadPixels(0,0,1200,900,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
    var tinted, selected: int
    for pixel in image.data:
      if (pixel.g > 100 and pixel.g.int > pixel.r.int*14 div 10) or
          (pixel.r > 100 and pixel.r.int > pixel.g.int*2): inc tinted
      if pixel.r > 150 and pixel.g > 100 and pixel.b < 80: inc selected
    if resourceVisible:
      check tinted > 100
    else:
      check tinted == 0
    if shownUnit(run.world.units[run.world.unitIndex(id)]):
      check selected > 100
    else:
      check selected == 0 # strict current sight also hides owned selection
    check selectedIds == @[id]
  targetFlash.advanceTargetFeedback(ClickMarkDuration)
  checkHidden()
  targetFlash = retained
  for cell in run.world.visibleStamp[0].mitems: cell = run.world.visionGeneration[0] + 1
  checkHidden(resourceVisible = kind in ["tree", "mine"])
  for cell in run.world.visibleStamp[0].mitems: cell = run.world.visionGeneration[0]
  if kind == "tree": run.world.treeWood[tile] = 0
  elif kind == "mine": run.world.buildings[0].goldLeft = 0
  elif kind == "unit": run.world.units[run.world.unitIndex(target)].state = UnitDying
  else: run.world.buildings[0].state = BuildingDying
  checkHidden()

suite "LvD target flash":
  test "contextual harvest flashes actual tree green, retaining selection":
    checkTarget("tree")
  test "contextual mine flashes actual assembled mine green":
    checkTarget("mine")
  test "contextual enemy unit flashes animated mesh red":
    checkTarget("unit")
  test "contextual enemy building flashes actual building red":
    checkTarget("building")
  test "armed A enemy unit click flashes red":
    checkTarget("unit", true)
  test "armed A enemy building click flashes red":
    checkTarget("building", true)
  test "dead workers cannot flash or queue harvest":
    checkTarget("tree", invalid = "dead")
  test "in-mine workers cannot replace harvest":
    checkTarget("mine", invalid = "inside")
  test "depleted mines cannot flash or queue harvest":
    checkTarget("mine", invalid = "depleted")
  test "focus blocks target input":
    checkTarget("mine", invalid = "focus")
  test "full Shift queue cannot flash harvest":
    checkTarget("mine", invalid = "full")
  test "full Shift queue cannot flash attack":
    checkTarget("unit", invalid = "full")
  test "tree orders remain visible through fog":
    checkTarget("tree", invalid = "unseen")
  test "mine orders remain visible through fog":
    checkTarget("mine", invalid = "unseen")
  test "unseen enemy cannot queue or flash even in all-view":
    checkTarget("unit", invalid = "unseen")
selectionOutline.closeSelectionOutline()
glDeleteRenderbuffers(1, depth.addr)
glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
window = nil
run = nil
