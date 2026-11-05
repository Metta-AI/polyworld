## Deterministic per-unit orders, separate from transient human intents.
import ../[content, maps, sim, replays, controls], polyworld/[bodies, tapes]

let map = generateMap(DefaultSeed)
const Duration = TickRate * 120
proc arena(x, y: int32): Tile2 = tile2(map.side div 2 + x, map.side div 2 + y)
proc step(w: World) = w.tickWorld(nil)
proc move(w: World, unit: Unit, dest: Tile2, append = false): bool =
  w.applyMove(unit.owner, unit.id, int32(dest.x), int32(dest.y), append = append)

block visitsWaypointsAroundObstacle:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  w.place(unit, arena(-5, 0))
  # Wall between start and destination; waypoints choose its northern end.
  for y in -2'i32 .. 2'i32:
    w.blocker[map.tileIndex(arena(0, y))] = TreeBlocker
  let waypoints = [arena(-3, -4), arena(3, -4), arena(5, 0)]
  doAssert w.move(unit, waypoints[0])
  doAssert w.move(unit, waypoints[1], true)
  doAssert w.move(unit, waypoints[2], true)
  doAssert unit.goal == waypoints[0], "Append must preserve the active waypoint"
  var visited = 0
  for tick in 0 ..< TickRate * 35:
    w.step()
    doAssert w.tileOpen(unit.tile)
    if visited < waypoints.len and unit.tile == waypoints[visited]: inc visited
    if visited == waypoints.len and unit.state == UnitIdle: break
  doAssert visited == waypoints.len, "Every waypoint must be reached in order"
  doAssert unit.state == UnitIdle

block attackMoveFightsThenVisitsNextWaypoint:
  let w = newWorld(map, Duration)
  w.diplomacy.pairs[w.diplomacy.pairIndex(0, 1)].state = AtWar
  let id = w.spawnUnit(0, SoldierUnit, arena(-5, 0))
  let unit = w.units[w.unitIndex(id)]
  let enemyId = w.spawnUnit(1, PeonUnit, arena(-2, 0))
  w.units[w.unitIndex(enemyId)].hp = 1
  w.rebuildVision()
  let first = arena(2, 0)
  let last = arena(5, -4)
  doAssert w.applyAttackMove(0, id, int32(first.x), int32(first.y))
  doAssert w.applyAttackMove(0, id, int32(last.x), int32(last.y), append = true)
  doAssert unit.attackMoveGoal == first, "Appending A-move must preserve its current destination"
  var visitedFirst = false
  for tick in 0 ..< TickRate * 40:
    w.step()
    if unit.tile == first: visitedFirst = true
    if unit.tile == last and unit.state == UnitIdle: break
  doAssert not w.entityAlive(enemyId)
  doAssert visitedFirst
  doAssert unit.tile == last
  doAssert unit.orderQueue.len == 0

block contextualAttackThenMove:
  let w = newWorld(map, Duration)
  w.diplomacy.pairs[w.diplomacy.pairIndex(0, 1)].state = AtWar
  let id = w.spawnUnit(0, SoldierUnit, arena(-5, 0))
  let unit = w.units[w.unitIndex(id)]
  let enemy = w.spawnUnit(1, PeonUnit, arena(-2, 0))
  w.units[w.unitIndex(enemy)].hp = 1
  w.rebuildVision()
  doAssert w.move(unit, arena(-4, 0))
  doAssert w.applyAttack(0, id, enemy, append = true)
  doAssert unit.state == UnitMoving, "Contextual queued attack must wait"
  doAssert w.move(unit, arena(5, -4), true)
  for tick in 0 ..< TickRate * 40: w.step()
  doAssert not w.entityAlive(enemy)
  doAssert unit.tile == arena(5, -4)

block harvestYieldsToSuccessorAfterDeposit:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  let mine = w.buildings[0]
  doAssert mine.kind == GoldMineBuilding
  let first = unit.tile
  doAssert w.move(unit, first)
  doAssert w.applyHarvest(0, unit.id, mine.id, 0, append = true)
  doAssert unit.state == UnitMoving, "Harvest must wait behind current move"
  doAssert w.move(unit, arena(-4, -4), true)
  let before = w.players[0].goldGathered
  for tick in 0 ..< TickRate * 100:
    w.step()
    if unit.state == UnitIdle and unit.tile == arena(-4, -4): break
  doAssert w.players[0].goldGathered > before
  doAssert unit.tile == arena(-4, -4)
  doAssert unit.carryGold == 0

block capacityReplacementDeathAndInvalidTargets:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  w.place(unit, arena(-5, 0))
  doAssert w.move(unit, arena(-3, 0))
  for i in 0 ..< MaxUnitOrders:
    doAssert w.move(unit, arena(3, 0), true)
  doAssert not w.move(unit, arena(4, 0), true)
  doAssert unit.orderQueue.len == MaxUnitOrders
  doAssert not w.applyMove(0, unit.id, -1, -1)
  doAssert unit.orderQueue.len == MaxUnitOrders
  doAssert w.move(unit, arena(5, 0))
  doAssert unit.orderQueue.len == 0
  doAssert w.move(unit, arena(3, 0), true)
  doAssert w.applyCancel(0, unit.id)
  doAssert unit.orderQueue.len == 0, "Cancel must clear pending orders"
  doAssert w.move(unit, arena(3, 0))
  doAssert w.move(unit, arena(4, 0), true)
  w.damageEntity(unit.id, unit.hp)
  doAssert unit.orderQueue.len == 0, "Death must clear pending orders"
  doAssert not w.move(unit, arena(4, 0), true)

block deadQueuedAttackIsSkipped:
  let w = newWorld(map, Duration)
  w.diplomacy.pairs[w.diplomacy.pairIndex(0, 1)].state = AtWar
  let unit = w.units[0]
  w.place(unit, arena(-5, 0))
  let enemy = w.spawnUnit(1, PeonUnit, arena(-2, 0))
  w.rebuildVision()
  doAssert w.move(unit, arena(-4, -3))
  doAssert w.applyAttack(0, unit.id, enemy, append = true)
  doAssert w.move(unit, arena(4, -3), true)
  w.damageEntity(enemy, 100000)
  for tick in 0 ..< TickRate * 30: w.step()
  doAssert unit.tile == arena(4, -3)
  doAssert unit.orderQueue.len == 0

block hashAndSnapshotIncludeQueue:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  doAssert w.move(unit, arena(-4, -3))
  let baseline = Game(world: w).stateHash()
  doAssert w.move(unit, arena(4, -3), true)
  doAssert Game(world: w).stateHash() != baseline, "Pending order changes state hash"
  let saved = w.clone()
  doAssert Game(world: saved).stateHash() == Game(world: w).stateHash()
  doAssert w.move(unit, arena(3, -3))
  doAssert saved.units[0].orderQueue.len == 1
  w.restore(saved)
  doAssert w.units[0].orderQueue.len == 1
  for tick in 0 ..< TickRate * 5:
    w.step()
    saved.step()
    doAssert Game(world: saved).stateHash() == Game(world: w).stateHash()

block controlsRecordAppendAndReplayExactly:
  let game = newGame(map, Duration)
  var setup = Setup(mapSeed: map.seed, tickRate: uint16(TickRate),
    gridTiles: uint16(map.side), decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(Duration), mapHash: 1, contentHash: contentHash())
  for i, origin in map.hallOrigin:
    setup.players.add ReplayPlayerSetup(id: int32(i),
      startX: int32(origin.x), startY: int32(origin.y))
  game.recorder = initReplayRecorder(setup)
  let unit = game.world.units[0]
  let first = arena(-4, -3)
  let last = arena(4, -3)
  clearPlayerCommands()
  queueMove(0, unit.id, int32(first.x), int32(first.y))
  queueAttackMove(0, unit.id, int32(last.x), int32(last.y), append = true)
  doAssert unit.state == UnitIdle, "Paused intents do not mutate the simulation"
  proc decide(w: World) = game.flushPlayerCommands()
  for tick in 0 ..< TickRate * 35:
    game.world.tickWorld(decide)
    game.recorder.recordHash(game.stateHash())
    if game.world.tick == DecisionTicks:
      doAssert unit.goal == first, "Control queue must preserve append"
      doAssert unit.orderQueue.len == 1
  doAssert unit.tile == last
  let data = decodeReplay(encodeReplay(game.recorder.data))
  doAssert data.actions.len == 2
  doAssert not data.actions[0].append
  doAssert data.actions[1].append
  let playback = newGame(map, Duration)
  let cursor = initReplayPlayer(data)
  proc replay(w: World) =
    var action: ReplayAction
    while cursor.takeActionAt(uint32(w.tick), action):
      doAssert w.applyReplayAction(action)
  for tick in 0 ..< data.hashes.len:
    playback.world.tickWorld(replay)
    doAssert playback.stateHash() == data.hashes[tick]

block subTileWaypointsReachTheirExactOffsets:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  let dest = arena(-3, 0)
  w.place(unit, dest)
  let offset = FixedVec2(x: 0.4'fx, y: 0.3'fx)
  doAssert length(offset) > 0.4'fx
  doAssert w.applyMove(0, unit.id, int32(dest.x), int32(dest.y), offset)
  doAssert w.applyAttackMove(0, unit.id, int32(dest.x), int32(dest.y),
    -offset, append = true)
  var visited = false
  let center = fixedVec2(fixed(int32(dest.x)) + 0.5'fx,
    fixed(int32(dest.y)) + 0.5'fx)
  for tick in 0 ..< TickRate * 8:
    w.step()
    if length(unit.body.pos - center - offset) <= 0.001'fx: visited = true
    if unit.state == UnitIdle and unit.orderQueue.len == 0: break
  doAssert visited, "First sub-tile waypoint must not complete on cell equality"
  doAssert length(unit.body.pos - center + offset) <= 0.001'fx

block appendWhileInsideMineWaitsForDeposit:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  doAssert w.applyHarvest(0, unit.id, w.buildings[0].id, 0)
  for tick in 0 ..< TickRate * 60:
    w.step()
    if unit.state == UnitInMine: break
  doAssert unit.state == UnitInMine
  doAssert w.move(unit, arena(-4, -3), true)
  doAssert unit.state == UnitInMine
  doAssert not w.move(unit, arena(-3, -3))
  doAssert unit.orderQueue.len == 1
  for tick in 0 ..< TickRate * 50:
    w.step()
    if unit.state == UnitIdle and unit.orderQueue.len == 0: break
  doAssert w.players[0].goldGathered > 0
  doAssert unit.tile == arena(-4, -3)
  doAssert w.buildings[0].minersInside == 0

block depletedQueuedHarvestAndBlockedWaypointAreSkipped:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  w.place(unit, arena(-5, 0))
  let tree = map.tileIndex(arena(-2, 1))
  w.treeWood[tree] = 10
  w.blocker[tree] = TreeBlocker
  doAssert w.move(unit, arena(-4, 0))
  doAssert w.applyHarvest(0, unit.id, tree, 1, append = true)
  doAssert w.move(unit, arena(2, 0), true)
  doAssert w.move(unit, arena(4, -3), true)
  w.treeWood[tree] = 0
  w.blocker[map.tileIndex(arena(2, 0))] = TreeBlocker
  for tick in 0 ..< TickRate * 30: w.step()
  doAssert unit.tile == arena(4, -3)
  doAssert unit.orderQueue.len == 0

block ordinaryBuildClearsPendingMoves:
  let w = newWorld(map, Duration)
  let unit = w.units[0]
  w.players[0].gold = 5000
  w.players[0].wood = 5000
  doAssert w.move(unit, arena(-4, -3))
  doAssert w.move(unit, arena(4, -3), true)
  let site = arena(-3, 3)
  doAssert w.applyBuild(0, unit.id, int32(FarmBuilding.ord), int32(site.x), int32(site.y))
  doAssert unit.orderQueue.len == 0

echo "LvD unit order queue tests passed"
