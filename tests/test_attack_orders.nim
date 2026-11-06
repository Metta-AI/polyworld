## Headless coverage of LvD human attack-move intents and real simulation.
import std/unittest
import ../games/light_vs_dark/[attackorders, content, controls, maps, replays, sim]

let battleMap = generateMap(DefaultSeed)

proc fixture(): Game =
  Game(world: newWorld(battleMap, TickRate * 60))

proc arenaTile(x: int32, y = 0'i32): Tile2 =
  tile2(battleMap.side div 2 + x, battleMap.side div 2 + y)

suite "LvD selected combat-capable attack orders":
  setup:
    clearPlayerCommands()
  teardown:
    clearPlayerCommands()

  test "selected soldier queues an attack move without changing selection":
    let game = fixture()
    let soldier = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    let selection = @[soldier]
    let destination = arenaTile(6)
    check game.world.queueSelectedAttackMove(LightPlayer, selection,
      destination.x.int32, destination.y.int32)
    check not game.world.units[game.world.unitIndex(soldier)].attackMove
    game.flushPlayerCommands()
    let unit = game.world.units[game.world.unitIndex(soldier)]
    check unit.attackMove
    check unit.attackMoveGoal == destination
    check unit.state == UnitMoving
    check selection == @[soldier]

  test "mixed selection queues living owned army and workers":
    let game = fixture()
    let world = game.world
    let soldier = world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    let peon = world.units[0].id
    let enemy = world.spawnUnit(DarkPlayer, SoldierUnit, arenaTile(0))
    let dying = world.spawnUnit(LightPlayer, ArcherUnit, arenaTile(-3))
    world.units[world.unitIndex(dying)].state = UnitDying
    let dead = world.spawnUnit(LightPlayer, MageUnit, arenaTile(-2))
    world.units[world.unitIndex(dead)].hp = 0
    let hidden = world.spawnUnit(LightPlayer, KnightUnit, arenaTile(-1))
    world.units[world.unitIndex(hidden)].state = UnitInMine
    let destination = arenaTile(6)
    let selection = @[soldier, peon, enemy, dying, dead, hidden,
      world.buildings[0].id, NoEntity, LastUnitId]
    check world.queueSelectedAttackMove(LightPlayer, selection,
      destination.x.int32, destination.y.int32)
    game.flushPlayerCommands()
    check world.units[world.unitIndex(soldier)].attackMove
    check world.units[world.unitIndex(peon)].attackMove
    for id in [enemy, dying, dead, hidden]:
      check not world.units[world.unitIndex(id)].attackMove
    check not world.queueSelectedAttackMove(LightPlayer, [enemy, dying,
      dead, hidden, world.buildings[0].id, NoEntity, LastUnitId],
      destination.x.int32, destination.y.int32)

  test "invalid destinations do not queue orders":
    let game = fixture()
    let soldier = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    var blocked = NoTile
    for y in 0'i32 ..< battleMap.side:
      for x in 0'i32 ..< battleMap.side:
        if not game.world.terrainOpen(x, y):
          blocked = tile2(x, y)
          break
      if blocked != NoTile: break
    require blocked != NoTile
    for destination in [tile2(-1, 0), tile2(battleMap.side, 0), blocked]:
      check not game.world.queueSelectedAttackMove(LightPlayer, [soldier],
        destination.x.int32, destination.y.int32)
    game.flushPlayerCommands()
    check not game.world.units[game.world.unitIndex(soldier)].attackMove

  test "arming accepts owned workers as well as military":
    let game = fixture()
    let soldier = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    check game.world.hasSelectedMilitary(LightPlayer, [soldier])
    check not game.world.hasSelectedMilitary(DarkPlayer, [soldier])
    check game.world.hasSelectedMilitary(LightPlayer, [game.world.units[0].id])
    check game.world.armSelectedAttackMove(LightPlayer, [game.world.units[0].id])
    check attackMoveArmed
    check not game.world.hasSelectedMilitary(LightPlayer, [])
    check not game.world.hasSelectedMilitary(-1, [soldier])
    check not game.world.hasSelectedMilitary(game.world.players.len.int32, [soldier])
    check not World(nil).hasSelectedMilitary(LightPlayer, [soldier])
    check not World(nil).queueSelectedAttackMove(LightPlayer, [soldier], 0, 0)
    check not game.world.queueSelectedAttackMove(-1, [soldier], 0, 0)

  test "flushed attack move damages an enemy en route and records intent":
    let game = fixture()
    let world = game.world
    world.diplomacy.pairs[world.diplomacy.pairIndex(LightPlayer, DarkPlayer)].state = AtWar
    let soldier = world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    let enemy = world.spawnUnit(DarkPlayer, SoldierUnit, arenaTile(-1))
    let destination = arenaTile(6)
    world.rebuildVision()
    game.recorder = initReplayRecorder(Setup(gridTiles: battleMap.side.uint16,
      maximumTicks: (TickRate * 60).uint32, decisionTicks: DecisionTicks.uint16,
      players: @[ReplayPlayerSetup(id: LightPlayer), ReplayPlayerSetup(id: DarkPlayer)]))
    world.tick = 1
    let hpBefore = world.units[world.unitIndex(enemy)].hp
    require world.queueSelectedAttackMove(LightPlayer, [soldier],
      destination.x.int32, destination.y.int32)
    game.flushPlayerCommands()
    require game.recorder.data.actions.len == 1
    check game.recorder.data.actions[0].kind == ActionAttackMove
    check game.recorder.data.actions[0].entityId == soldier
    for _ in 0 ..< TickRate * 8:
      world.tickWorld(proc(w: World) = discard)
    check not world.hasUnit(enemy) or world.units[world.unitIndex(enemy)].hp < hpBefore

  test "normal queued move still passes enemies without attacking":
    let game = fixture()
    let world = game.world
    world.diplomacy.pairs[world.diplomacy.pairIndex(LightPlayer, DarkPlayer)].state = AtWar
    let soldier = world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    let enemy = world.spawnUnit(DarkPlayer, SoldierUnit, arenaTile(-1))
    let destination = arenaTile(6)
    world.rebuildVision()
    let hpBefore = world.units[world.unitIndex(enemy)].hp
    queueMove(LightPlayer, soldier, destination.x.int32, destination.y.int32)
    game.flushPlayerCommands()
    for _ in 0 ..< TickRate * 2:
      world.tickWorld(proc(w: World) = discard)
    require world.hasUnit(enemy)
    check world.units[world.unitIndex(enemy)].hp == hpBefore
    check world.units[world.unitIndex(soldier)].state == UnitMoving
    check not world.units[world.unitIndex(soldier)].attackMove

  test "ownership is checked again when queued command is applied":
    let game = fixture()
    let soldier = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    let destination = arenaTile(6)
    require game.world.queueSelectedAttackMove(LightPlayer, [soldier],
      destination.x.int32, destination.y.int32)
    game.world.units[game.world.unitIndex(soldier)].owner = DarkPlayer
    game.flushPlayerCommands()
    check not game.world.units[game.world.unitIndex(soldier)].attackMove

  test "explicit target intents reject allies hidden dead and invalid targets":
    let game = fixture()
    let world = game.world
    let soldier = world.spawnUnit(0, SoldierUnit, arenaTile(-4))
    let enemy = world.spawnUnit(1, PeonUnit, arenaTile(-2))
    let hidden = world.spawnUnit(1, PeonUnit, tile2(1, 1))
    world.rebuildVision()
    world.diplomacy.pairs[world.diplomacy.pairIndex(0, 1)].state = Allied
    check not world.queueSelectedAttack(0, [soldier], enemy)
    world.diplomacy.pairs[world.diplomacy.pairIndex(0, 1)].state = AtWar
    for target in [soldier, hidden, NoEntity, LastUnitId, world.buildings[0].id]:
      check not world.queueSelectedAttack(0, [soldier], target)
    check not World(nil).queueSelectedAttack(0, [soldier], enemy)
    check not world.queueSelectedAttack(-1, [soldier], enemy)
    check not world.queueSelectedAttack(0, [enemy], enemy)
    world.units[world.unitIndex(enemy)].hp = 0
    check not world.queueSelectedAttack(0, [soldier], enemy)
    game.flushPlayerCommands()
    check world.units[world.unitIndex(soldier)].state == UnitIdle

  test "arming cancels construction and only accepted clicks disarm":
    let game = fixture()
    let soldier = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    pendingBuild = FarmBuilding.ord.int32
    check game.world.armSelectedAttackMove(LightPlayer, [soldier])
    check attackMoveArmed
    check pendingBuild == -1
    check not game.world.queueArmedAttackMove(LightPlayer, [soldier], -1, -1)
    check attackMoveArmed
    let destination = arenaTile(6)
    check game.world.queueArmedAttackMove(LightPlayer, [soldier],
      destination.x.int32, destination.y.int32)
    check not attackMoveArmed
    check not game.world.queueArmedAttackMove(LightPlayer, [soldier],
      destination.x.int32, destination.y.int32)

when not defined(headless):
  import windy
  import polyworld/inputs
  import ../games/light_vs_dark/[lobbies, graphics]
  import vmath
  import polyworld/gameuis

  suite "LvD attack move input routing":
    test "minimap targeting uses the visible map rectangle":
      let layout = initGameUiLayout(vec2(1600, 1000), 0)
      let area = attackMinimapArea(layout)
      check attackMinimapTile(layout, area.origin + area.size * 0.5'f, 90) == tile2(45, 45)
      check attackMinimapTile(layout, area.origin - vec2(1), 90) == NoTile

  suite "LvD attack move bindings":
    test "default A arms attack move and is not a select alias":
      check LvdControlProfile.defaults[SelectInput] == [MouseLeft, ButtonUnknown]
      check LvdControlProfile.defaults[AttackMoveInput] == [KeyA, ButtonUnknown]
      var visible = false
      for binding in LvdControlProfile.actions:
        if binding.action == AttackMoveInput: visible = true
      check visible

    test "legacy A collision migrates without resetting other custom keys":
      var bindings = LvdControlProfile.defaults
      bindings[SelectInput] = [MouseLeft, KeyA]
      bindings[StopInput] = [KeyH, KeyJ]
      bindings.migrateLvdBindings()
      check bindings[SelectInput] == [MouseLeft, ButtonUnknown]
      check bindings[AttackMoveInput] == [KeyA, ButtonUnknown]
      check bindings[StopInput] == [KeyH, KeyJ]
      let migrated = bindings
      bindings.migrateLvdBindings()
      check bindings == migrated

    test "custom selection and custom attack bindings are preserved":
      var bindings = LvdControlProfile.defaults
      bindings[SelectInput] = [MouseLeft, KeyA]
      bindings[AttackMoveInput] = [KeyF, KeyG]
      let customizedAttack = bindings
      bindings.migrateLvdBindings()
      check bindings == customizedAttack
      bindings[SelectInput] = [MouseLeft, KeyZ]
      bindings[AttackMoveInput] = [KeyA, ButtonUnknown]
      let customizedSelection = bindings
      bindings.migrateLvdBindings()
      check bindings == customizedSelection
