## Moving workers must pass, not repeatedly undo each other's steer.
import ../[content, maps, sim], fixxy

let map = generateMap(DefaultSeed)
const Duration = TickRate * 120
proc arena(x, y: int32): Tile2 = tile2(map.side div 2 + x, map.side div 2 + y)

proc fixture(): World =
  result = newWorld(map, Duration)
  for y in -7'i32 .. 7'i32:
    for x in -7'i32 .. 7'i32:
      let at = arena(x, y)
      doAssert result.terrainOpen(int32(at.x), int32(at.y))
      result.blocker[map.tileIndex(at)] = 0
      result.treeWood[map.tileIndex(at)] = 0
  result.place(result.units[0], arena(-2, 0))
  result.place(result.units[1], arena(2, 0))

proc miningTrace(queued = false): seq[uint64] =
  let w = fixture()
  var mine, hall: int32 = -1
  for i, b in w.buildings:
    if b.kind == GoldMineBuilding and mine < 0: mine = int32(i)
    if b.kind == TownHallBuilding and b.owner == 0: hall = int32(i)
  doAssert mine >= 0 and hall >= 0
  # Small isolated mine/depot fixture, retaining real arrival/mining/deposit code.
  for i in [mine, hall]:
    for tile in 0 ..< w.blocker.len:
      if w.blocker[tile] == w.buildings[i].id: w.blocker[tile] = 0
    w.buildings[i].footprint = (1'i32, 1'i32)
    w.buildings[i].origin = if i == mine: arena(6, 0) else: arena(-6, 0)
    w.blocker[map.tileIndex(w.buildings[i].origin)] = w.buildings[i].id
  w.units[1].carryGold = GoldPerTrip
  for i in 0 .. 1:
    doAssert w.applyHarvest(0, w.units[i].id, w.buildings[mine].id, 0)
    # Exact opposing approach centres expose symmetry without incidental diagonal drift.
    w.units[i].goal = if i == 0: arena(5, 0) else: arena(-5, 0)
    for request in w.pathQueue.mitems:
      if request.unitId == w.units[i].id: request.goal = w.units[i].goal
    if queued:
      let destination = arena(-3, int32(i) * 4 - 2)
      doAssert w.applyMove(0, w.units[i].id, int32(destination.x),
        int32(destination.y), fixedVec2(0.2'fx, -0.1'fx), append = true)
  var deposits: array[2, int]
  var passed = false
  var checkpoint: World
  var checkpointChecked = false
  for tick in 0 ..< TickRate * 90:
    let carried = [w.units[0].carryGold, w.units[1].carryGold]
    let before = [w.units[0].body.pos, w.units[1].body.pos]
    let states = [w.units[0].state, w.units[1].state]
    w.tickWorld(nil)
    if checkpoint != nil:
      checkpoint.tickWorld(nil)
      doAssert Game(world: checkpoint).stateHash() == Game(world: w).stateHash()
      checkpoint = nil
      checkpointChecked = true
    elif not checkpointChecked and w.units[1].passingTicks > 0:
      checkpoint = w.clone()
    # Friendly rubber circles can overlap during a pass. Progress, bounded
    # displacement, terrain legality and repeated deposits are the contract.
    for i in 0 .. 1:
      if states[i] != UnitInMine:
        doAssert length(w.units[i].body.pos - before[i]) < 0.2'fx
      if w.units[i].state != UnitInMine:
        doAssert w.tileOpen(w.units[i].tile)
    result.add Game(world: w).stateHash()
    if w.units[0].body.pos.x > w.units[1].body.pos.x: passed = true
    for i in 0 .. 1:
      if carried[i] > 0 and w.units[i].carryGold == 0: inc deposits[i]
      doAssert not w.units[i].orderFailed
      if queued and deposits[i] == 0:
        doAssert w.units[i].orderQueue.len == 1
      if w.units[i].passingTicks > 0:
        doAssert w.units[i].sourceId == w.buildings[mine].id
        doAssert w.units[i].state in {UnitToMine, UnitToDropGold}
  doAssert checkpointChecked, "Snapshot during the yield must resume deterministically"
  echo "head-on mining deposits: ", deposits, "; passed: ", passed
  doAssert passed, "Opposing workers must actually pass after body separation"
  for i, count in deposits:
    if queued:
      doAssert count == 1, "Queued successors start only after deposit"
      let destination = arena(-3, int32(i) * 4 - 2)
      let point = fixedVec2(fixed(int32(destination.x)) + 0.7'fx,
        fixed(int32(destination.y)) + 0.4'fx)
      doAssert length(w.units[i].body.pos - point) <= 0.001'fx
      doAssert w.units[i].state == UnitIdle
      doAssert w.units[i].orderQueue.len == 0
    else:
      doAssert count >= 2, "Both workers must continue mining and depositing"
  doAssert w.players[0].goldGathered == int64(deposits[0] + deposits[1]) * GoldPerTrip

doAssert miningTrace() == miningTrace(), "Passing must have identical per-tick hashes"
discard miningTrace(queued = true)

proc pathTrace(walls: int): seq[uint64] =
  let w = fixture()
  # 0: open; 1: wide corridor; 2: preferred side blocked; 3: no side space.
  for x in -7'i32 .. 7'i32:
    if walls == 1:
      for y in [-2'i32, 2'i32]: w.blocker[map.tileIndex(arena(x, y))] = TreeBlocker
    if walls >= 2: w.blocker[map.tileIndex(arena(x, -1))] = TreeBlocker
    if walls == 3: w.blocker[map.tileIndex(arena(x, 1))] = TreeBlocker
  var lateral = false
  for round in 0 ..< 3:
    let destinations = if round mod 2 == 0: [arena(4, 0), arena(-4, 0)]
      else: [arena(-4, 0), arena(4, 0)]
    for i in 0 .. 1:
      doAssert w.applyMove(0, w.units[i].id, int32(destinations[i].x),
        int32(destinations[i].y), fixedVec2(0.1'fx, 0'fx))
    var lockedPoint = FixedVec2Zero
    for tick in 0 ..< TickRate * 12:
      let before = [w.units[0].body.pos, w.units[1].body.pos]
      w.tickWorld(nil)
      result.add Game(world: w).stateHash()
      for i in 0 .. 1:
        let unit = w.units[i]
        doAssert w.tileOpen(unit.tile)
        doAssert length(unit.body.pos - before[i]) < 0.2'fx,
          "Passing must walk at ordinary speed, not teleport"
        doAssert unit.goal == destinations[i]
        doAssert not unit.orderFailed
        if unit.passingTicks > 0:
          doAssert i == 1, "Only the higher ID yields"
          if lockedPoint != FixedVec2Zero:
            doAssert unit.passingPoint == lockedPoint, "Never flip sides during a pass"
          lockedPoint = unit.passingPoint
          doAssert unit.state == UnitMoving
          lateral = true
        elif i == 1:
          lockedPoint = FixedVec2Zero
        # Corners of the worker footprint remain on open terrain.
        for dx in [-unit.body.radius, unit.body.radius]:
          for dy in [-unit.body.radius, unit.body.radius]:
            let point = unit.body.pos + fixedVec2(dx, dy)
            doAssert w.tileOpen(whole(point.x), whole(point.y))
      # Contact is intentionally soft; it is not resolved in a single tick.
    if walls == 3:
      doAssert not lateral
      # Compressible friendly circles can pass within the one-tile corridor;
      # the hard footprint/corner assertions above still apply every tick.
    for i in 0 .. 1:
      let point = fixedVec2(fixed(int32(destinations[i].x)) + 0.6'fx,
        fixed(int32(destinations[i].y)) + 0.5'fx)
      doAssert length(w.units[i].body.pos - point) <= 0.001'fx
      doAssert w.units[i].state == UnitIdle
  if walls != 3: doAssert lateral

block passingStateIsHashed:
  let w = fixture()
  let unit = w.units[1]
  let initial = Game(world: w).stateHash()
  unit.passingPeer = w.units[0].id
  doAssert Game(world: w).stateHash() != initial
  let peerHash = Game(world: w).stateHash()
  unit.passingTicks = 10
  doAssert Game(world: w).stateHash() != peerHash
  let timerHash = Game(world: w).stateHash()
  unit.passingPoint = fixedVec2(1'fx, 2'fx)
  doAssert Game(world: w).stateHash() != timerHash
  let pointHash = Game(world: w).stateHash()
  unit.passingForward = fixedVec2(-1'fx, 0'fx)
  doAssert Game(world: w).stateHash() != pointHash

for walls in 0 .. 3:
  doAssert pathTrace(walls) == pathTrace(walls), "Repeated passing hashes diverged"
echo "Worker passing tests passed"
