## Art-free line-formation geometry, gesture, and real command pipeline tests.
import std/[unittest, sets, monotimes, times]
import fixxy
import ../games/light_vs_dark/[content, controls, maps, replays, sim, multiplayer]
import ../games/light_vs_dark/linemoves

suite "LvD curved line formations":
  test "arc-length sampling follows corners rather than the endpoint chord":
    let points = sampleLine(@[linePoint(0, 0), linePoint(4, 0),
      linePoint(4, 4)], 5)
    check points == @[linePoint(0, 0), linePoint(2, 0), linePoint(4, 0),
      linePoint(4, 2), linePoint(4, 4)]

  test "duplicates empty strokes zero length and one unit are well defined":
    check sampleLine([], 3).len == 0
    check sampleLine([linePoint(1, 2)], 0).len == 0
    check sampleLine([linePoint(1, 2), linePoint(1, 2)], 3) ==
      @[linePoint(1, 2), linePoint(1, 2), linePoint(1, 2)]
    check sampleLine([linePoint(0, 0), linePoint(4, 0), linePoint(4, 4)], 1) ==
      @[linePoint(4, 0)]

let battleMap = generateMap(DefaultSeed)
proc fixture(): Game = Game(world: newWorld(battleMap, TickRate * 60))
proc arenaTile(x: int32, y = 0'i32): Tile2 =
  tile2(battleMap.side div 2 + x, battleMap.side div 2 + y)
proc point(x: int32, y = 0'i32): LinePoint =
  let t = arenaTile(x, y)
  linePoint(t.x.float64 + 0.5, t.y.float64 + 0.5)

proc openWorld(side: int32): World =
  ## Art-free empty terrain isolates planner work from map generation.
  result = World(players: newSeq[Player](2),
    map: MapData(side: side, passable: newSeq[uint8](side*side)),
    blocker: newSeq[int32](side*side), occupancy: newSeq[int32](side*side),
    nextUnitId: FirstUnitId)
  for cell in 0 ..< result.map.passable.len: result.map.passable[cell] = 1

suite "LvD line planner work budget":
  test "512 square 64-unit preview examines nearby slots not 64 whole maps":
    let world = openWorld(512)
    var ids: seq[int32]
    for y in 0'i32 ..< 64:
      ids.add world.spawnUnit(0, SoldierUnit, tile2(100, 200+y))
    let stroke = [linePoint(300.5,200.5), linePoint(300.5,263.5)]
    let start = getMonoTime()
    let plan = world.planLineMove(0, ids, stroke)
    let elapsed = (getMonoTime()-start).inNanoseconds.float64 / 1_000_000
    echo "line benchmark cold 512x512/64: ", elapsed, " ms; ", lastLinePlanWork
    require plan.len == 64
    check lastLinePlanWork.slotCells <= 64*9
    check lastLinePlanWork.connectivityCells <= 4*512*512
    check lastLinePlanWork.assignmentPairs <= 64*64
    for i, target in plan:
      check target.tile == tile2(300, 200+i.int32)

    var gesture: LineGesture
    gesture.beginLine(world, 0, ids, stroke[0], linePoint(0,0))
    gesture.updateLine(world, ids, stroke[1], linePoint(0,100))
    let warmStart = getMonoTime()
    for step in 1 .. 20:
      gesture.updateLine(world, ids, linePoint(300.5+step.float64/100,263.5),
        linePoint(step,100))
      check lastLinePlanWork.slotCells <= 64*9
      check lastLinePlanWork.connectivityBuilds == 0
      check lastLinePlanWork.connectivityCells == 0
      check lastLinePlanWork.validationCells <= 512*512
    echo "line benchmark warm 512x512/64 mean of 20: ",
      (getMonoTime()-warmStart).inNanoseconds.float64 / 20_000_000, " ms"

suite "LvD legal formation plans":
  test "formation slots are distinct reachable and assigned without crossings":
    let game = fixture()
    let a = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4, -2))
    let b = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4, 2))
    let plan = game.world.planLineMove(LightPlayer, [b, a], [point(4, -2), point(4, 2)])
    require plan.len == 2
    check plan[0].unitId == a
    check plan[0].tile == arenaTile(4, -2)
    check plan[1].unitId == b
    check plan[1].tile == arenaTile(4, 2)
    check plan == game.world.planLineMove(LightPlayer, [a, b], [point(4, -2), point(4, 2)])

  test "short and blocked strokes spread into separate legal cells":
    let game = fixture()
    var ids: seq[int32]
    for y in -3'i32 .. 3'i32:
      ids.add game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-5,y))
    let occupied = game.world.spawnUnit(DarkPlayer, SoldierUnit, arenaTile(4))
    game.world.blocker[game.world.map.tileIndex(arenaTile(4,1).x.int32,
      arenaTile(4,1).y.int32)] = TreeBlocker
    let plan = game.world.planLineMove(LightPlayer, ids, [point(4),point(4)])
    require plan.len == ids.len
    var cells = initHashSet[int]()
    for target in plan:
      check game.world.tileOpen(target.tile)
      check target.tile != game.world.units[game.world.unitIndex(occupied)].tile
      let cell = game.world.map.tileIndex(target.tile.x.int32,target.tile.y.int32).int
      check cell notin cells
      cells.incl cell

  test "unreachable open ground across a wall is never assigned":
    let game = fixture()
    let unit = game.world.spawnUnit(0,SoldierUnit,arenaTile(-4))
    let wallX = arenaTile(0).x.int32
    for y in 0'i32 ..< game.world.map.side:
      game.world.blocker[game.world.map.tileIndex(wallX,y)] = TreeBlocker
    let plan = game.world.planLineMove(0,[unit],[point(4)])
    require plan.len == 1
    check plan[0].tile.x.int32 < wallX

  test "fractional stroke preview is the exact integer-control destination":
    let game = fixture()
    let unit = game.world.spawnUnit(0,SoldierUnit,arenaTile(-4))
    let p = point(4)
    let plan = game.world.planLineMove(0,[unit],[linePoint(p.x+0.17,p.y+0.23)])
    require plan.len == 1
    check plan[0].offset == FixedVec2Zero
    check plan[0].destinationPoint() == point(4)

  test "eligibility excludes enemies dead hidden buildings invalid and duplicate IDs":
    let game = fixture()
    let a = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    let enemy = game.world.spawnUnit(DarkPlayer, SoldierUnit, arenaTile(0))
    let hidden = game.world.spawnUnit(LightPlayer, PeonUnit, arenaTile(-3))
    game.world.units[game.world.unitIndex(hidden)].state = UnitInMine
    let dead = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-2))
    game.world.units[game.world.unitIndex(dead)].hp = 0
    check game.world.eligibleLineUnits(LightPlayer,
      [a, enemy, hidden, dead, a, NoEntity, game.world.buildings[0].id]) == @[a]
    check World(nil).eligibleLineUnits(0, [a]).len == 0
    check game.world.planLineMove(-1, [a], [point(4)]).len == 0

suite "LvD bounded nearest-slot correctness":
  test "expanding rings match exhaustive distance and row-major ties":
    let world = openWorld(16)
    var ids: seq[int32]
    for y in 1'i32 .. 8:
      ids.add world.spawnUnit(0, SoldierUnit, tile2(1,y))
    # A wall and one gap exercise unreachable-looking samples and long searches.
    for y in 0 ..< 16:
      if y != 2: world.blocker[y*16+8] = TreeBlocker
    for x in [ -50.0, -0.4, 0.0, 0.5, 1.0, 7.99, 8.1, 15.5, 16.0, 50.0 ]:
      for y in [ -10.0, 0.5, 2.0, 7.1, 8.5, 15.9, 40.0 ]:
        let sample = linePoint(x,y)
        let plan = world.planLineMove(0, ids, [sample])
        require plan.len == ids.len
        check lastLinePlanWork.slotCells <= ids.len*16*16
        var reserved = initHashSet[int]()
        for i, target in plan:
          var best = -1
          var bestCost = Inf
          for cell in 0 ..< 16*16:
            if cell in reserved or world.blocker[cell] != 0: continue
            let dx = (cell mod 16).float64 + 0.5 - x
            let dy = (cell div 16).float64 + 0.5 - y
            let cost = dx*dx + dy*dy
            if cost < bestCost:
              best = cell
              bestCost = cost
          check target.unitId == ids[i]
          check target.tile == tile2((best mod 16).int32,(best div 16).int32)
          reserved.incl best

  test "map bound terminates when a component runs out of distinct slots":
    let world = openWorld(16)
    let a = world.spawnUnit(0, SoldierUnit, tile2(0,0))
    let b = world.spawnUnit(0, SoldierUnit, tile2(0,0))
    world.blocker[1] = TreeBlocker
    world.blocker[16] = TreeBlocker
    let plan = world.planLineMove(0, [a,b], [linePoint(1000000,1000000)])
    require plan.len == 1
    check plan[0].tile == tile2(0,0)
    check lastLinePlanWork.slotCells <= 2*16*16

suite "LvD connectivity cache invalidation":
  setup: clearPlayerCommands()
  teardown: clearPlayerCommands()

  test "stationary preview notices construction tree removal and terrain edits":
    let world = openWorld(16)
    let id = world.spawnUnit(0, SoldierUnit, tile2(2,8))
    var gesture: LineGesture
    let target = linePoint(12.5,8.5)
    gesture.beginLine(world, 0, [id], target, linePoint(0,0))
    gesture.updateLine(world, [id], target, linePoint(100,0))
    require gesture.targets.len == 1
    check gesture.targets[0].tile == tile2(12,8)
    # No tick or pointer change: construction partitions the component.
    for y in 0 ..< 16: world.blocker[y*16+8] = FirstBuildingId
    gesture.updateLine(world, [id], target, linePoint(100,0))
    require gesture.targets.len == 1
    check gesture.targets[0].tile == tile2(7,8)
    # Opening a tree gap restores the other side, without changing map identity.
    world.blocker[8*16+8] = TreeBlocker
    gesture.updateLine(world, [id], target, linePoint(100,0))
    world.blocker[8*16+8] = 0
    gesture.updateLine(world, [id], target, linePoint(100,0))
    check gesture.targets[0].tile == tile2(12,8)
    world.map.passable[8*16+8] = 0
    gesture.updateLine(world, [id], target, linePoint(100,0))
    check gesture.targets[0].tile == tile2(7,8)

  test "moving nonselected occupants invalidate a cached narrow passage":
    let world = openWorld(16)
    let id = world.spawnUnit(0, SoldierUnit, tile2(2,8))
    let other = world.spawnUnit(1, SoldierUnit, tile2(15,15))
    for y in 0 ..< 16:
      if y != 8: world.blocker[y*16+8] = TreeBlocker
    var gesture: LineGesture
    let target = linePoint(12.5,8.5)
    gesture.beginLine(world, 0, [id], target, linePoint(0,0))
    gesture.updateLine(world, [id], target, linePoint(100,0))
    check gesture.targets[0].tile == tile2(12,8)
    world.units[world.unitIndex(other)].tile = tile2(8,8)
    gesture.updateLine(world, [id], target, linePoint(100,0))
    check gesture.targets[0].tile == tile2(7,8)

  test "world switches cancel and a new gesture cannot reuse old connectivity":
    let first = openWorld(16)
    let second = openWorld(16)
    let id = first.spawnUnit(0, SoldierUnit, tile2(2,8))
    check second.spawnUnit(0, SoldierUnit, tile2(2,8)) == id
    for y in 0 ..< 16: second.blocker[y*16+8] = TreeBlocker
    var gesture: LineGesture
    let target = linePoint(12.5,8.5)
    gesture.beginLine(first, 0, [id], target, linePoint(0,0))
    gesture.updateLine(first, [id], target, linePoint(100,0))
    check gesture.targets[0].tile == tile2(12,8)
    gesture.updateLine(second, [id], target, linePoint(100,0))
    check not gesture.active
    gesture.beginLine(second, 0, [id], target, linePoint(0,0))
    gesture.updateLine(second, [id], target, linePoint(100,0))
    check gesture.targets[0].tile == tile2(7,8)

  test "unrelated terrain changes still commit the exact displayed snapshot":
    let world = openWorld(16)
    let id = world.spawnUnit(0, SoldierUnit, tile2(2,8))
    var gesture: LineGesture
    let target = linePoint(12.5,8.5)
    gesture.beginLine(world, 0, [id], target, linePoint(0,0))
    gesture.updateLine(world, [id], target, linePoint(100,0))
    let preview = gesture.targets
    world.blocker[0] = TreeBlocker
    check gesture.releaseLine(world, [id]) == LineCommitted
    let game = Game(world: world)
    game.flushPlayerCommands()
    check world.units[world.unitIndex(id)].goal == preview[0].tile

  test "release cancels an invalidated preview rather than silently replacing it":
    let world = openWorld(16)
    let id = world.spawnUnit(0, SoldierUnit, tile2(2,8))
    var gesture: LineGesture
    let target = linePoint(12.5,8.5)
    gesture.beginLine(world, 0, [id], target, linePoint(0,0))
    gesture.updateLine(world, [id], target, linePoint(100,0))
    for y in 0 ..< 16: world.blocker[y*16+8] = TreeBlocker
    check gesture.releaseLine(world, [id]) == LineCancelled
    let game = Game(world: world)
    game.flushPlayerCommands()
    check world.units[world.unitIndex(id)].state == UnitIdle

suite "LvD formation release lifecycle":
  setup: clearPlayerCommands()
  teardown: clearPlayerCommands()

  test "drag previews but only release queues the same per-unit destinations":
    let game = fixture()
    let a = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4, -2))
    let b = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4, 2))
    var gesture: LineGesture
    gesture.beginLine(game.world, LightPlayer, [a,b], point(4,-2), linePoint(100,100))
    gesture.updateLine(game.world, [a,b], point(4,2), linePoint(100,180))
    check gesture.dragging
    let preview = gesture.targets
    require preview.len == 2
    game.flushPlayerCommands()
    check game.world.units[game.world.unitIndex(a)].state == UnitIdle
    check gesture.releaseLine(game.world, [a,b]) == LineCommitted
    game.flushPlayerCommands()
    for target in preview:
      let unit = game.world.units[game.world.unitIndex(target.unitId)]
      check unit.goal == target.tile
      check unit.goalOffset == target.offset
    for tick in 0 ..< TickRate*20:
      game.world.tickWorld(proc(w: World) = discard)
    for target in preview:
      let unit = game.world.units[game.world.unitIndex(target.unitId)]
      check unit.tile == target.tile
      check unit.state == UnitIdle
      check not unit.orderFailed

  test "curved formation has separate arrivals along its bend not a shared path":
    let game = fixture()
    var ids: seq[int32]
    for y in [-3'i32,0'i32,3'i32]:
      ids.add game.world.spawnUnit(0,SoldierUnit,arenaTile(-5,y))
    var gesture: LineGesture
    gesture.beginLine(game.world,0,ids,point(0,-3),linePoint(0,0))
    gesture.updateLine(game.world,ids,point(4,-3),linePoint(50,0))
    gesture.updateLine(game.world,ids,point(4,1),linePoint(50,50))
    let preview = gesture.targets
    require preview.len == 3
    var targets = initHashSet[Tile2]()
    for target in preview: targets.incl target.tile
    check arenaTile(0,-3) in targets
    check arenaTile(4,-3) in targets
    check arenaTile(4,1) in targets
    check gesture.releaseLine(game.world,ids) == LineCommitted
    game.flushPlayerCommands()
    for tick in 0 ..< TickRate*30:
      game.world.tickWorld(proc(w: World) = discard)
    for target in preview:
      let unit = game.world.units[game.world.unitIndex(target.unitId)]
      check unit.tile == target.tile
      check unit.state == UnitIdle
      check not unit.orderFailed

  test "threshold retains contextual clicks and cancelling never queues":
    let game = fixture()
    let a = game.world.spawnUnit(LightPlayer, SoldierUnit, arenaTile(-4))
    var gesture: LineGesture
    gesture.beginLine(game.world, 0, [a], point(4), linePoint(100,100))
    gesture.updateLine(game.world, [a], point(4), linePoint(103,102))
    check gesture.releaseLine(game.world, [a]) == LineClick
    for cancelKind in 0 .. 3:
      gesture.beginLine(game.world, 0, [a], point(3), linePoint(100,100))
      gesture.updateLine(game.world, [a], point(4), linePoint(140,100))
      case cancelKind
      of 0: gesture.cancelLine() # Escape/menu/focus loss
      of 1: gesture.updateLine(game.world, [], point(4), linePoint(140,100))
      of 2: discard # Off-window release
      else: game.world.units[game.world.unitIndex(a)].hp = 0
      check gesture.releaseLine(game.world, [a], inside = cancelKind != 2) == LineCancelled
    game.flushPlayerCommands()
    check game.world.units[game.world.unitIndex(a)].state == UnitIdle

  test "empty selection and one-unit zero-world-length drag are safe":
    let game = fixture()
    var gesture: LineGesture
    gesture.beginLine(game.world,0,[],point(4),linePoint(0,0))
    gesture.updateLine(game.world,[],point(4),linePoint(20,0))
    check gesture.releaseLine(game.world,[]) == LineCancelled
    let a = game.world.spawnUnit(0,SoldierUnit,arenaTile(-4))
    gesture.beginLine(game.world,0,[a],point(4),linePoint(0,0))
    gesture.updateLine(game.world,[a],point(4),linePoint(20,0))
    require gesture.targets.len == 1
    check gesture.releaseLine(game.world,[a]) == LineCommitted

  test "Shift formation preserves active order and arrives at queued destinations":
    let game = fixture()
    let a = game.world.spawnUnit(0,SoldierUnit,arenaTile(-4,-2))
    let b = game.world.spawnUnit(0,SoldierUnit,arenaTile(-4,2))
    let first = game.world.planLineMove(0,[a,b],[point(0,-2),point(0,2)])
    let second = game.world.planLineMove(0,[a,b],[point(4,-2),point(4,2)])
    discard game.world.queueLineTargets(0,first)
    game.flushPlayerCommands()
    discard game.world.queueLineTargets(0,second,append=true)
    game.flushPlayerCommands()
    for i,id in [a,b]:
      let unit = game.world.units[game.world.unitIndex(id)]
      check unit.goal == first[i].tile
      check unit.orderQueue.len == 1
    for tick in 0 ..< TickRate*30:
      game.world.tickWorld(proc(w: World) = discard)
    for target in second:
      let unit = game.world.units[game.world.unitIndex(target.unitId)]
      check unit.tile == target.tile
      check unit.state == UnitIdle
      check unit.orderQueue.len == 0

  test "attack formation and Shift append travel through network submissions":
    let game = fixture()
    game.networked = true
    game.recorder = initReplayRecorder(Setup(gridTiles: battleMap.side.uint16,
      maximumTicks: (TickRate*60).uint32, decisionTicks: DecisionTicks.uint16,
      players: @[ReplayPlayerSetup(id: 0), ReplayPlayerSetup(id: 1)]))
    let a = game.world.spawnUnit(0,SoldierUnit,arenaTile(-4,-2))
    let b = game.world.spawnUnit(0,PeonUnit,arenaTile(-4,2))
    var gesture: LineGesture
    gesture.beginLine(game.world,0,[a,b],point(4,-2),linePoint(0,0),attackMove=true)
    gesture.updateLine(game.world,[a,b],point(4,2),linePoint(0,100))
    let preview = gesture.targets
    check gesture.releaseLine(game.world,[a,b],append=true) == LineCommitted
    game.flushPlayerCommands()
    require game.submissions.len == 2
    for i, action in game.submissions:
      check action.entityId == preview[i].unitId
      check action.first == preview[i].tile.x.int32
      check action.second == preview[i].tile.y.int32
      check action.append
      check action.kind == (if action.entityId == a: ActionAttackMove else: ActionMove)
      check game.world.units[game.world.unitIndex(action.entityId)].state == UnitIdle
      let wire = decodeSubmission(action.encodeSubmission())
      check wire.append
      check wire.entityId == action.entityId
      check wire.first == action.first
      check wire.second == action.second
      check game.world.applyReplayAction(wire)
    for target in preview:
      let unit = game.world.units[game.world.unitIndex(target.unitId)]
      check unit.goal == target.tile
      check unit.attackMove == (target.unitId == a)
