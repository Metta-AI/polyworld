## Runs the production mouse order handler and picker against real commands.
import std/[unittest, macros, importutils]
import windy/internal
include ../games/light_vs_dark/graphics
privateAccess(Window)

macro graphicsRoutine(name: static[string]): untyped =
  let source = parseStmt(staticRead("../games/light_vs_dark/graphics.nim"))
  for node in source:
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkProcDef and child[0].repr == name: return child
  error("Missing production routine: " & name)

suite "LvD production combat clicks":
  test "armed enemy click targets all eligible selected units; Shift and right click agree":
    window = newWindow("LvD combat clicks", ivec2(1600, 1000), visible = false)
    defer:
      window.close()
      window = nil
      run = nil
      clearPlayerCommands()
    sk = Silky(uiScale: 1)
    options.playerSlot = 1
    viewMode = 0
    inputBindings = LvdControlProfile.defaults
    run = Game(world: newWorld(generateMap(DefaultSeed), TickRate * 60))
    let world = run.world
    world.diplomacy.pairs[world.diplomacy.pairIndex(0, 1)].state = AtWar
    let soldier = world.spawnUnit(0, SoldierUnit, tile2(41, 45))
    let worker = world.spawnUnit(0, PeonUnit, tile2(41, 46))
    let enemy = world.spawnUnit(1, SoldierUnit, tile2(44, 45))
    let dying = world.spawnUnit(0, SoldierUnit, tile2(41, 47))
    world.units[world.unitIndex(dying)].state = UnitDying
    world.rebuildVision()
    var buildingArt: BuildingArt
    var clickMarks, attackClickMarks: ClickMarkSystem
    var grove: Grove
    let scenery = grovePlacements(world.treeWood, DefaultSeed, world.map.forestRocks)[0 ..< 0]
    var actionCam = initActionCam(subjectMode = true)
    graphicsRoutine("playerMode")
    graphicsRoutine("screenPosition")
    graphicsRoutine("pickEntity")
    graphicsRoutine("structureAtTile")
    graphicsRoutine("buildGhostOrigin")
    graphicsRoutine("queuePendingBuild")
    graphicsRoutine("clickTilePoint")
    graphicsRoutine("issueSelectedMove")
    graphicsRoutine("updatePlayerOrder")
    graphicsRoutine("cameraView")
    cameraTarget = renderPoint(world.units[world.unitIndex(enemy)])
    cameraDistance = 17
    let projection = perspective(45'f32, 1.6'f32, 0.1'f32, 1000'f32) * cameraView()
    let point = screenPosition(cameraTarget + vec3(0, UnitHeights[SoldierUnit] * 0.5'f32, 0), projection)
    window.state.mousePos = ivec2(point.x.int32, point.y.int32)
    sk.mousePos = window.mousePos.vec2
    require not mouseOverUi(window, sk.mousePos)
    require pickEntity(projection) == enemy
    selectedIds = @[soldier, worker, enemy, dying, NoEntity]
    let selection = selectedIds
    for rightClick in [false, true]:
      for append in [false, true]:
        for id in [soldier, worker]:
          require world.applyMove(0, id, 39, 45)
          require world.applyMove(0, id, 38, 45, append = true)
        attackMoveArmed = not rightClick
        rightOrderStarted = rightClick
        window.state.buttonDown = if append: {KeyLeftShift} else: {}
        window.state.perFrame = if rightClick:
          PerFrame(buttonReleased: {MouseRight}) else: PerFrame(buttonPressed: {MouseLeft})
        updatePlayerOrder(projection)
        check not attackMoveArmed
        check selectedIds == selection
        run.flushPlayerCommands()
        for id in [soldier, worker]:
          let unit = world.units[world.unitIndex(id)]
          if append:
            require unit.orderQueue.len == 2
            check unit.orderQueue[1].kind == ActionAttack
            check unit.orderQueue[1].first == enemy
          else:
            check unit.orderQueue.len == 0
            check unit.state == UnitChasing
            check unit.targetId == enemy
            check not unit.attackMove
        check world.units[world.unitIndex(enemy)].targetId == NoEntity
        check world.units[world.unitIndex(dying)].state == UnitDying

    # With no A mode, left click belongs to selection and issues no orders.
    attackMoveArmed = false
    window.state.buttonDown = {}
    window.state.perFrame = PerFrame(buttonPressed: {MouseLeft})
    for id in [soldier, worker]: require world.applyCancel(0, id)
    updatePlayerOrder(projection)
    run.flushPlayerCommands()
    for id in [soldier, worker]: check world.units[world.unitIndex(id)].state == UnitIdle

    # Friendly or peaceful entities are not interpreted as attack-move ground.
    attackMoveArmed = true
    world.diplomacy.pairs[world.diplomacy.pairIndex(0, 1)].state = Neutral
    updatePlayerOrder(projection)
    check attackMoveArmed
    run.flushPlayerCommands()
    for id in [soldier, worker]: check world.units[world.unitIndex(id)].state == UnitIdle
    world.diplomacy.pairs[world.diplomacy.pairIndex(0, 1)].state = AtWar
    let ownPoint = screenPosition(renderPoint(world.units[world.unitIndex(soldier)]) +
      vec3(0, UnitHeights[SoldierUnit] * 0.5'f32, 0), projection)
    window.state.mousePos = ivec2(ownPoint.x.int32, ownPoint.y.int32)
    sk.mousePos = window.mousePos.vec2
    require pickEntity(projection) == soldier
    updatePlayerOrder(projection)
    check attackMoveArmed
    run.flushPlayerCommands()
    for id in [soldier, worker]: check world.units[world.unitIndex(id)].state == UnitIdle

    # Empty world ground still attack-moves the whole selected force.
    # No building models are loaded in this art-free native input fixture.
    for structure in world.buildings.mitems: structure.state = BuildingDying
    let groundPoint = screenPosition(clickTilePoint(47, 43), projection)
    window.state.mousePos = ivec2(groundPoint.x.int32, groundPoint.y.int32)
    sk.mousePos = window.mousePos.vec2
    require pickEntity(projection) == NoEntity
    updatePlayerOrder(projection)
    check not attackMoveArmed
    run.flushPlayerCommands()
    for id in [soldier, worker]: check world.units[world.unitIndex(id)].attackMove
