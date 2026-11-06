## Execute real order-input and render code; assert commands AND GPU pixels.
import std/[unittest, macros, importutils]
import windy/internal
include ../graphics
privateAccess(Window)

macro feedbackRoutine(name: static[string]): untyped =
  for node in parseStmt(staticRead("../graphics.nim")):
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkAsgn and child[1].kind == nnkLambda and
            ((name == "buttonHandler" and child[0].repr == "window.onButtonPress") or
             (name == "releaseHandler" and child[0].repr == "window.onButtonRelease")):
          return child
        if child.kind == nnkProcDef and child[0].repr == name: return child
  error("Missing production routine: " & name)

macro drawProductionPreview(): untyped =
  proc search(node: NimNode): NimNode =
    if node.kind == nnkIfStmt and node.len > 0 and
        node[0][0].repr == "lineGesture.active and lineGesture.dragging":
      return node
    for child in node:
      let found = search(child)
      if found != nil: return found
  result = search(parseStmt(staticRead("../graphics.nim")))
  if result == nil: error("Missing production preview renderer")

macro feedbackSystems(): untyped =
  result = newStmtList()
  for node in parseStmt(staticRead("../graphics.nim")):
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkVarSection:
          for definition in child:
            if definition[0].repr in ["clickMarks", "attackClickMarks"]:
              result.add newTree(nnkVarSection, definition)

window = newWindow("LvD order feedback regression", ivec2(1600, 1000), visible = false)
window.makeContextCurrent()
loadExtensions()
# Explicit focus input below avoids OS-global activation on unattended hosts.
sk = Silky(uiScale: 1)
options.playerSlot = 1
viewMode = 0
var framebuffer, texture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, window.size.x, window.size.y,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
glViewport(0, 0, window.size.x, window.size.y)

proc checkOrder(attack, minimap: bool, drag = false, enemy = false,
    shift = false, fogged = false) =
  run = Game(world: newWorld(generateMap(DefaultSeed), TickRate * 60))
  run.world.buildings.setLen(0) # No building art needed for ground input.
  viewMode = if fogged: 1 else: 0
  if fogged:
    for stamp in run.world.visibleStamp[0].mitems:
      stamp = 0
  clearPlayerCommands()
  lineGesture.cancelLine()
  rightOrderStarted = false
  cameraTarget = vec3(0)
  let half = run.world.map.side div 2
  let id = run.world.spawnUnit(0, SoldierUnit, tile2(half-4, half))
  selectedIds = @[id]
  if drag:
    selectedIds.add run.world.spawnUnit(0, SoldierUnit, tile2(half-4, half+2))
  primaryId = id
  var buildingArt: BuildingArt
  var grove: Grove
  let scenery: seq[GrovePlacement] = @[]
  feedbackSystems()
  defer:
    clickMarks.closeClickMarks()
    attackClickMarks.closeClickMarks()
  feedbackRoutine("playerMode")
  feedbackRoutine("screenPosition")
  feedbackRoutine("pickEntity")
  feedbackRoutine("structureAtTile")
  feedbackRoutine("buildGhostOrigin")
  feedbackRoutine("queuePendingBuild")
  feedbackRoutine("clickTilePoint")
  feedbackRoutine("issueSelectedMove")
  feedbackRoutine("updatePlayerOrder")
  let vp = perspective(45'f32, 1.6, 0.1, 1000) *
    lookAt(vec3(0, 22, 18), vec3(0), vec3(0, 1, 0))
  let target = tile2(half+4, half)
  var enemyId = NoEntity
  if enemy:
    enemyId = run.world.spawnUnit(1, SoldierUnit, target)
    # Visibility is authoritative even when the fixture's view shows all.
    for cell in run.world.visibleStamp[0].mitems: cell = run.world.visionGeneration[0]
  if minimap:
    let area = attackMinimapArea(currentLayout(window))
    sk.mousePos = area.origin + area.size * vec2(
      (target.x.float32+0.5)/run.world.map.side.float32,
      (target.y.float32+0.5)/run.world.map.side.float32)
  else:
    sk.mousePos = screenPosition(clickTilePoint(target.x.int32, target.y.int32), vp) / gameUiScale(window)
    if enemy:
      sk.mousePos = screenPosition(renderPoint(run.world.units[run.world.unitIndex(enemyId)]) +
        vec3(0, UnitHeights[SoldierUnit] * 0.5'f32, 0), vp) / gameUiScale(window)
  sk.uiScale = gameUiScale(window)
  window.state.mousePos = ivec2((sk.mousePos.x * sk.uiScale).int32,
    (sk.mousePos.y * sk.uiScale).int32)
  var preview: seq[LineDestination]
  var
    matchMenu = HiddenMatchMenu
    preferences: Preferences
    network: NetworkMatch
    scene: CharacterScene
    actionCam = initActionCam(subjectMode = true)
  feedbackRoutine("buttonHandler")
  feedbackRoutine("releaseHandler")
  shortcutState.resetShortcut()
  resetHumanCommunication()
  inputBindings = LvdControlProfile.defaults
  pendingBuild = -1
  attackMoveArmed = false
  window.state.buttonDown = {}
  if attack:
    # Real key routing: opening Units must not steal A from combat selection.
    window.onButtonPress(KeyT)
    window.onButtonRelease(KeyT)
    window.onButtonPress(KeyA)
    window.onButtonRelease(KeyA)
    require attackMoveArmed
  if attack and not drag:
    window.state.buttonDown = {MouseLeft}
    if shift: window.state.buttonDown.incl KeyLeftShift
    window.state.perFrame = PerFrame(buttonPressed: {MouseLeft})
    updatePlayerOrder(vp, focused = true)
  else:
    window.state.buttonDown = {MouseRight}
    window.state.perFrame = PerFrame(buttonPressed: {MouseRight})
    updatePlayerOrder(vp, focused = true)
    if drag:
      sk.mousePos = screenPosition(clickTilePoint(target.x.int32, target.y.int32+4), vp) / sk.uiScale
      window.state.mousePos = ivec2((sk.mousePos.x*sk.uiScale).int32, (sk.mousePos.y*sk.uiScale).int32)
      window.state.perFrame = PerFrame()
      updatePlayerOrder(vp, focused = true)
      require lineGesture.dragging
      require lineGesture.targets.len == selectedIds.len
      preview = lineGesture.targets
      var worldShapes = initShapeRenderer()
      let viewProjection = vp
      glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
      glClearColor(0,0,0,1)
      glClear(GL_COLOR_BUFFER_BIT)
      drawProductionPreview()
      let previewImage = newImage(window.size.x, window.size.y)
      glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,previewImage.data[0].addr)
      var matching = 0
      for pixel in previewImage.data:
        if attack and pixel.r > 30 and pixel.r.int > pixel.g.int*14 div 10: inc matching
        if not attack and pixel.g > 30 and pixel.g.int > pixel.r.int*14 div 10: inc matching
      check matching > 100
      echo "preview attack=", attack, " matching pixels=", matching
      previewImage.flipVertical()
      previewImage.writeFile(getTempDir() / ("lvd-feedback-preview-" & $attack & ".png"))
      worldShapes.closeShapeRenderer()
    window.state.buttonDown = {}
    if shift: window.state.buttonDown.incl KeyLeftShift
    window.state.perFrame = PerFrame(buttonReleased: {MouseRight})
    updatePlayerOrder(vp, focused = true)
  run.networked = true
  run.recorder = initReplayRecorder(Setup(gridTiles: run.world.map.side.uint16,
    maximumTicks: (TickRate*60).uint32, decisionTicks: DecisionTicks.uint16,
    players: @[ReplayPlayerSetup(id: 0), ReplayPlayerSetup(id: 1)]))
  run.flushPlayerCommands()
  require run.submissions.len == selectedIds.len
  for action in run.submissions:
    check action.kind == (if enemy: ActionAttack elif attack: ActionAttackMove else: ActionMove)
    check action.append == shift
    if enemy: check action.first == enemyId
    elif drag:
      for destination in preview:
        if destination.unitId == action.entityId:
          check action.first == destination.tile.x.int32
          check action.second == destination.tile.y.int32
    else:
      check action.first == target.x.int32
      check action.second == target.y.int32
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glClearColor(0,0,0,1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  clickMarks.advanceClickMarks(0.12)
  attackClickMarks.advanceClickMarks(0.12)
  clickMarks.drawClickMarks(vp)
  attackClickMarks.drawClickMarks(vp)
  let image = newImage(window.size.x, window.size.y)
  glReadPixels(0,0,window.size.x,window.size.y,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
  var green, red, lit: int
  for pixel in image.data:
    if max(pixel.r, max(pixel.g, pixel.b)) > 30: inc lit
    if pixel.g > 30 and pixel.g.int > pixel.r.int * 14 div 10: inc green
    if pixel.r > 30 and pixel.r.int > pixel.g.int * 14 div 10: inc red
  echo "feedback attack=", attack, " minimap=", minimap, " green=", green, " red=", red, " lit=", lit
  image.flipVertical()
  image.writeFile(getTempDir() / ("lvd-feedback-" & $attack & "-" & $minimap & "-" & $drag & "-" & $enemy & ".png"))
  check lit > 20
  if attack or enemy:
    check red > 20
    check green == 0
  else:
    check green > 20
    check red == 0

suite "LvD rendered order feedback":
  test "ordinary minimap right-click queues Move and renders green":
    checkOrder(false, true)
  test "ordinary ground right-click queues Move and renders green":
    checkOrder(false, false)
  test "armed minimap left-click queues AttackMove and renders red":
    checkOrder(true, true)
  test "armed ground left-click queues AttackMove and renders red":
    checkOrder(true, false)
  test "armed Shift ground left-click appends AttackMove and renders red":
    checkOrder(true, false, shift = true)
  test "right-drag previews green and commits green Move markers with Shift":
    checkOrder(false, false, drag = true, shift = true)
  test "armed right-drag previews red and commits red AttackMove markers with Shift":
    checkOrder(true, false, drag = true, shift = true)
  test "armed enemy left-click queues targeted Attack and renders red":
    checkOrder(true, false, enemy = true)
  test "contextual enemy right-click queues targeted Attack and renders red":
    checkOrder(false, false, enemy = true)

block foggedOrders:
  checkOrder(false, false, fogged = true)
  checkOrder(true, false, fogged = true)
  checkOrder(false, false, drag = true, fogged = true)
  checkOrder(true, false, drag = true, fogged = true)

glDeleteTextures(1, texture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
window = nil
run = nil
