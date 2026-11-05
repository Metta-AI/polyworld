## Worker-driven construction regressions. Run natively with -d:headless.
## No bot decisions: queued human commands are flushed on real decision ticks.
import std/unittest
import ../games/light_vs_dark/[content, maps, sim, controls]

let arenaMap = generateMap(DefaultSeed)
const Duration = TickRate * 180
proc arena(x, y: int32): Tile2 =
  tile2(arenaMap.side div 2 + x, arenaMap.side div 2 + y)
proc fixture(): Game =
  clearPlayerCommands()
  result = newGame(arenaMap, Duration)
  result.world.players[LightPlayer].gold = 10000
  result.world.players[LightPlayer].wood = 10000
  result.world.place(result.world.units[0], arena(-10, 0))
  result.world.place(result.world.units[1], arena(-10, 4))
proc step(game: Game, ticks = 1'i32) =
  for _ in 0 ..< ticks:
    game.world.tickWorld(proc(w: World) = game.flushPlayerCommands())
proc enqueueFarm(game: Game, worker: Unit, origin: Tile2) =
  queueBuild(worker.owner, worker.id, FarmBuilding.ord.int32,
    origin.x.int32, origin.y.int32)
proc farmAt(game: Game, origin: Tile2): int =
  for i, building in game.world.buildings:
    if building.kind == FarmBuilding and building.origin == origin:
      return i
  -1
proc adjacent(worker: Unit, site: Building): bool =
  adjacentToFootprint(site.origin, site.footprint,
    worker.tile.x.int32, worker.tile.y.int32)
proc startFarm(game: Game, worker: Unit, origin: Tile2): int =
  game.enqueueFarm(worker, origin)
  game.step(DecisionTicks)
  result = game.farmAt(origin)
  doAssert result >= 0, "queued farm placement was rejected"
  for _ in 0 ..< TickRate * 30:
    if worker.state == UnitBuilding: break
    game.step()
  doAssert worker.state == UnitBuilding, "worker did not reach farm"
  doAssert worker.targetId == game.world.buildings[result].id
  doAssert worker.adjacent(game.world.buildings[result])

suite "worker-driven farm construction":
  test "queued far farm waits for its selected owned worker then completes":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let other = w.units[1]
    let start = worker.tile
    let otherStart = other.tile
    let origin = arena(6, 0)
    let countBefore = w.buildings.len
    game.enqueueFarm(worker, origin)
    check w.buildings.len == countBefore
    game.step(DecisionTicks)
    let site = game.farmAt(origin)
    require site >= 0
    check worker.state == UnitToBuild
    check worker.targetId == w.buildings[site].id
    check w.buildings[site].buildTicks == w.buildings[site].buildTotal
    var progressed = false
    var validProgress = true
    for _ in 0 ..< TickRate * 60:
      let before = w.buildings[site].buildTicks
      game.step()
      if w.buildings[site].buildTicks < before:
        progressed = true
        if not worker.adjacent(w.buildings[site]) or worker.hp <= 0:
          validProgress = false
        if w.buildings[site].state == BuildingUnderConstruction and
            (worker.state != UnitBuilding or
             worker.targetId != w.buildings[site].id):
          validProgress = false
      if w.buildings[site].state == BuildingComplete: break
    check progressed
    check validProgress
    check worker.tile != start
    check other.tile == otherStart
    check w.buildings[site].state == BuildingComplete

  test "cancel during travel leaves a paused shell":
    let game = fixture()
    let worker = game.world.units[0]
    let origin = arena(6, 0)
    game.enqueueFarm(worker, origin)
    game.step(DecisionTicks)
    let site = game.farmAt(origin)
    require site >= 0
    require worker.state == UnitToBuild
    queueCancel(worker.owner, worker.id)
    game.step(DecisionTicks)
    let before = game.world.buildings[site].buildTicks
    game.step(TickRate * 3)
    check worker.state == UnitIdle
    check game.world.buildings[site].buildTicks == before
    check before == game.world.buildings[site].buildTotal

  test "retargeting to a second farm cannot remotely build the first":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let first = game.startFarm(worker, arena(-4, 0))
    game.step(TickRate)
    let before = w.buildings[first].buildTicks
    let second = game.startFarm(worker, arena(6, 0))
    require not worker.adjacent(w.buildings[first])
    require worker.targetId == w.buildings[second].id
    game.step(TickRate)
    check w.buildings[first].buildTicks == before
    check w.buildings[second].buildTicks < w.buildings[second].buildTotal

  test "cancelled work can be adopted by a replacement without paying twice":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let replacement = w.units[1]
    let origin = arena(-4, 0)
    let site = game.startFarm(worker, origin)
    queueCancel(worker.owner, worker.id)
    game.step(DecisionTicks)
    let before = w.buildings[site].buildTicks
    game.step(TickRate)
    check w.buildings[site].buildTicks == before
    let gold = w.players[LightPlayer].gold
    let wood = w.players[LightPlayer].wood
    game.enqueueFarm(replacement, origin)
    game.step(DecisionTicks)
    check replacement.state in {UnitToBuild, UnitBuilding}
    check replacement.targetId == w.buildings[site].id
    game.step(TickRate * 30)
    check w.buildings[site].state == BuildingComplete
    check w.players[LightPlayer].gold == gold
    check w.players[LightPlayer].wood == wood

  test "a displaced working builder cannot progress construction remotely":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let site = game.startFarm(worker, arena(-4, 0))
    let before = w.buildings[site].buildTicks
    # Model displacement without a replacement order; state alone is not proof
    # of adjacency (tickWorld also separates colliding bodies before buildings).
    w.place(worker, arena(-10, -5))
    require not worker.adjacent(w.buildings[site])
    game.step()
    check w.buildings[site].buildTicks == before

  test "dead builder pauses immediately and replacement can adopt before corpse removal":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let replacement = w.units[1]
    let origin = arena(-4, 0)
    let site = game.startFarm(worker, origin)
    let before = w.buildings[site].buildTicks
    w.damageEntity(worker.id, worker.hp)
    game.step(TickRate)
    check w.buildings[site].buildTicks == before
    game.enqueueFarm(replacement, origin)
    game.step(DecisionTicks)
    check replacement.targetId == w.buildings[site].id
    game.step(TickRate * 30)
    check w.buildings[site].state == BuildingComplete

  test "move interrupts active work without further progress":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let site = game.startFarm(worker, arena(-4, 0))
    let before = w.buildings[site].buildTicks
    let goal = arena(-10, -5)
    queueMove(worker.owner, worker.id, goal.x.int32, goal.y.int32)
    game.step(TickRate * 5)
    check w.buildings[site].buildTicks == before
    check not worker.adjacent(w.buildings[site])

  test "cancelling an abandoned site must not interrupt its former builder's new site":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let first = game.startFarm(worker, arena(-4, 0))
    let second = game.startFarm(worker, arena(6, 0))
    let secondId = w.buildings[second].id
    queueCancel(worker.owner, w.buildings[first].id)
    game.step(DecisionTicks)
    check worker.state == UnitBuilding
    check worker.targetId == secondId
    game.step(TickRate * 20)
    check w.buildings[w.buildingIndex(secondId)].state == BuildingComplete

  test "destroying an abandoned site cannot cancel work on another site":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let first = game.startFarm(worker, arena(-4, 0))
    let second = game.startFarm(worker, arena(6, 0))
    let secondId = w.buildings[second].id
    # A stale assignment can survive until the building tick cleans it.
    w.buildings[first].builderId = worker.id
    w.damageEntity(w.buildings[first].id, w.buildings[first].hp)
    check worker.state == UnitBuilding
    check worker.targetId == secondId
    game.step(TickRate * 20)
    check w.buildings[w.buildingIndex(secondId)].state == BuildingComplete

  test "replacement resumes after dead builder corpse has been removed":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let replacement = w.units[1]
    let origin = arena(-4, 0)
    let site = game.startFarm(worker, origin)
    w.damageEntity(worker.id, worker.hp)
    game.step(DeathTicks + 2)
    require w.unitIndex(worker.id) < 0
    game.enqueueFarm(replacement, origin)
    game.step(TickRate * 30)
    check w.buildings[site].state == BuildingComplete

  test "build replaces a prior queued harvest path on the same decision tick":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    var mineId = NoEntity
    for structure in w.buildings:
      if structure.kind == GoldMineBuilding:
        mineId = structure.id
        break
    require mineId != NoEntity
    queueHarvest(worker.owner, worker.id, mineId, 0)
    let origin = arena(6, 0)
    game.enqueueFarm(worker, origin)
    game.step(DecisionTicks)
    let site = game.farmAt(origin)
    require site >= 0
    check worker.state == UnitToBuild
    check worker.targetId == w.buildings[site].id
    game.step(TickRate * 40)
    check w.buildings[site].state == BuildingComplete

  test "worker routes around an obstruction to a reachable farm":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    for y in -3'i32 .. 3'i32:
      w.blocker[arenaMap.tileIndex(arena(0, y))] = TreeBlocker
    let site = game.startFarm(worker, arena(6, 0))
    check worker.adjacent(w.buildings[site])
    check not worker.orderFailed
    game.step(TickRate * 20)
    check w.buildings[site].state == BuildingComplete

  test "foreign worker cannot receive a queued farm placement":
    let game = fixture()
    let w = game.world
    var foreign: Unit
    for unit in w.units:
      if unit.owner != LightPlayer:
        foreign = unit
        break
    require foreign != nil
    let countBefore = w.buildings.len
    let origin = arena(6, 0)
    queueBuild(LightPlayer, foreign.id, FarmBuilding.ord.int32,
      origin.x.int32, origin.y.int32)
    game.step(DecisionTicks)
    check w.buildings.len == countBefore
    check foreign.state == UnitIdle

  test "fully obstructed approach leaves a paused recoverable shell":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let origin = arena(6, 0)
    let size = BuildingTable[FarmBuilding].footprint
    for y in origin.y.int32 - 1 .. origin.y.int32 + size.depth:
      for x in origin.x.int32 - 1 .. origin.x.int32 + size.width:
        if adjacentToFootprint(origin, size, x, y):
          w.blocker[arenaMap.tileIndex(x, y)] = TreeBlocker
    require w.canPlace(FarmBuilding, origin.x.int32, origin.y.int32)
    game.enqueueFarm(worker, origin)
    game.step(DecisionTicks)
    let site = game.farmAt(origin)
    require site >= 0
    game.step(TickRate * 3)
    check worker.orderFailed
    check worker.state == UnitIdle
    check w.buildings[site].buildTicks == w.buildings[site].buildTotal
    # Opening the ring permits the same paid-for shell to be adopted.
    for y in origin.y.int32 - 1 .. origin.y.int32 + size.depth:
      for x in origin.x.int32 - 1 .. origin.x.int32 + size.width:
        if adjacentToFootprint(origin, size, x, y):
          w.blocker[arenaMap.tileIndex(x, y)] = 0
    let gold = w.players[LightPlayer].gold
    game.enqueueFarm(worker, origin)
    game.step(TickRate * 40)
    check w.buildings[site].state == BuildingComplete
    check w.players[LightPlayer].gold == gold
