## Exercise actual graphics routines using Windy's real multi-click detector.
import std/[unittest, macros, importutils]
import windy/internal
include ../games/light_vs_dark/graphics
privateAccess(Window)

macro graphicsRoutine(name: static[string]): untyped =
  let source = parseStmt(staticRead("../games/light_vs_dark/graphics.nim"))
  for node in source:
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkProcDef and child[0].repr == name:
          return child
  error("Missing production routine: " & name)

# These are the same templates used by Windy's native and browser backends.
proc handleButtonPress(window: Window, button: Button) =
  handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) =
  handleButtonReleaseTemplate()

suite "LvD double-left-click selection":
  test "second press selects all owned living same-kind units across the map":
    window = newWindow("LvD double click", ivec2(1600, 1000), visible = false)
    defer:
      window.close()
      window = nil
      run = nil
      clearPlayerCommands()
    sk = Silky(uiScale: 1)
    options.playerSlot = 1
    viewMode = 0 # A player's ownership scope must not rely on the fog setting.
    run = Game(world: newWorld(generateMap(DefaultSeed), TickRate * 60))
    let world = run.world
    let clicked = world.spawnUnit(0, SoldierUnit, tile2(30, 30))
    let remote = world.spawnUnit(0, SoldierUnit, tile2(5, 5))
    let enemy = world.spawnUnit(1, SoldierUnit, tile2(50, 50))
    let other = world.spawnUnit(0, ArcherUnit, tile2(6, 6))
    let dying = world.spawnUnit(0, SoldierUnit, tile2(7, 7))
    let dead = world.spawnUnit(0, SoldierUnit, tile2(8, 8))
    let mined = world.spawnUnit(0, SoldierUnit, tile2(9, 9))
    world.units[world.unitIndex(dying)].state = UnitDying
    world.units[world.unitIndex(dead)].hp = 0
    world.units[world.unitIndex(mined)].state = UnitInMine
    var
      matchMenu = HiddenMatchMenu
      actionCam = initActionCam(subjectMode = true)
      buildingArt: BuildingArt
    actionCam.takeManual()
    graphicsRoutine("playerMode")
    graphicsRoutine("selectionTarget")
    graphicsRoutine("selectedCount")
    graphicsRoutine("selectEntity")
    graphicsRoutine("clearSelection")
    graphicsRoutine("selectAllUnits")
    graphicsRoutine("pruneSelection")
    graphicsRoutine("selectedCenter")
    graphicsRoutine("selectedRadius")
    graphicsRoutine("screenPosition")
    graphicsRoutine("pickEntity")
    graphicsRoutine("insideBox")
    graphicsRoutine("boxedUnits")
    graphicsRoutine("selectBox")
    graphicsRoutine("updateCamera")
    graphicsRoutine("updateWorldSelection")
    graphicsRoutine("cameraView")
    pendingBuild = -1
    attackMoveArmed = false
    transport = initPlayer(live = true, durationTicks = TickRate * 60, playing = true)
    cameraTarget = renderPoint(world.units[world.unitIndex(clicked)])
    cameraDistance = 17
    let projection = perspective(45'f32, 1.6'f32, 0.1'f32, 1000'f32) * cameraView()
    let point = screenPosition(cameraTarget + vec3(0, UnitHeights[SoldierUnit] * 0.5'f32, 0), projection)
    window.state.mousePos = ivec2(point.x.int32, point.y.int32)
    sk.mousePos = window.mousePos.vec2
    require not mouseOverUi(window, sk.mousePos)
    require pickEntity(projection) == clicked
    selectedIds = @[other]
    primaryId = other
    platformDoubleClickInterval = 60 # Deterministic even on a busy test host.
    window.state.doubleClickTime = 0
    window.handleButtonPress(MouseLeft)
    updateCamera(0)
    updateWorldSelection(projection)
    window.state.perFrame = PerFrame()
    window.handleButtonRelease(MouseLeft)
    updateWorldSelection(projection)
    require selectedIds == @[clicked]
    window.state.perFrame = PerFrame()
    window.handleButtonPress(MouseLeft)
    require window.buttonPressed[DoubleClick]
    updateCamera(0)
    updateWorldSelection(projection)
    check selectedIds == @[clicked, remote]
    check primaryId == clicked
    for excluded in [enemy, other, dying, dead, mined]:
      check excluded notin selectedIds
    window.state.perFrame = PerFrame()
    window.handleButtonRelease(MouseLeft)
    updateCamera(0)
    updateWorldSelection(projection)
    check selectedIds == @[clicked, remote]
    check primaryId == clicked

    # Shift is a union, not the single-click toggle; clicked stays primary.
    selectedIds = @[other, remote]
    primaryId = other
    window.state.buttonDown = {KeyLeftShift, MouseLeft}
    window.state.perFrame = PerFrame(buttonPressed: {MouseLeft, DoubleClick})
    updateCamera(0)
    updateWorldSelection(projection)
    check selectedIds == @[other, remote, clicked]
    check primaryId == clicked
    window.state.perFrame = PerFrame()
    window.handleButtonRelease(MouseLeft)
    updateCamera(0)
    updateWorldSelection(projection)
    check selectedIds == @[other, remote, clicked]
    check primaryId == clicked

    # A double click over UI or in a modal/command state must not select.
    for blocked in 0 .. 5:
      selectedIds = @[other]
      primaryId = other
      selectionStarted = false
      pendingBuild = if blocked == 3: FarmBuilding.ord else: -1
      attackMoveArmed = blocked == 4
      matchMenu = if blocked == 1: PauseMenu
        elif blocked == 2: MatchSettings else: HiddenMatchMenu
      transport.playing = blocked != 5
      sk.mousePos = if blocked == 0: attackMinimapArea(currentLayout(window)).origin + vec2(4)
        else: window.mousePos.vec2
      window.state.buttonDown = {MouseLeft}
      window.state.perFrame = PerFrame(buttonPressed: {MouseLeft, DoubleClick})
      updateCamera(0)
      updateWorldSelection(projection)
      checkpoint "blocked input case " & $blocked
      check selectedIds == @[other]
      check primaryId == other
      # Including a later release after the blocker goes away.
      pendingBuild = -1
      attackMoveArmed = false
      matchMenu = HiddenMatchMenu
      transport.playing = true
      sk.mousePos = window.mousePos.vec2
      window.state.perFrame = PerFrame()
      window.handleButtonRelease(MouseLeft)
      updateCamera(0)
      updateWorldSelection(projection)
      check selectedIds == @[other]
      check primaryId == other

    # Spectators match box selection: viewed owner, or all owners in omniscient.
    options.playerSlot = 0
    for mode in [1'i32, 0'i32]:
      viewMode = mode
      world.rebuildVision()
      selectedIds = @[other]
      primaryId = other
      window.state.buttonDown = {MouseLeft}
      # A press and release may both arrive before the next graphics frame.
      window.state.perFrame = PerFrame(buttonPressed: {MouseLeft, DoubleClick},
        buttonReleased: {MouseLeft, DoubleClick})
      updateCamera(0)
      updateWorldSelection(projection)
      check selectedIds == (if mode == 0: @[clicked, remote, enemy] else: @[clicked, remote])
      check primaryId == clicked
      check followSelection
      check not playerMode()
      check not selectionStarted

  test "invalid clicked units cannot seed a type selection":
    let world = newWorld(generateMap(DefaultSeed), TickRate * 60)
    let own = world.spawnUnit(0, SoldierUnit, tile2(30, 30))
    let enemy = world.spawnUnit(1, SoldierUnit, tile2(31, 30))
    for id in [NoEntity, LastUnitId, world.buildings[0].id, enemy]:
      check world.matchingUnitIds(id, 0).len == 0
    check World(nil).matchingUnitIds(own, 0).len == 0
    world.units[world.unitIndex(own)].hp = 0
    check world.matchingUnitIds(own, 0).len == 0
    world.units[world.unitIndex(own)].hp = 100
    for state in [UnitDying, UnitInMine]:
      world.units[world.unitIndex(own)].state = state
      check world.matchingUnitIds(own, 0).len == 0
