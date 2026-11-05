## Real worker round trips through blocked wood approaches.
import ../[content, maps, sim], fixxy

let map = generateMap(DefaultSeed)
const Duration = TickRate * 120
proc arena(x, y: int32): Tile2 = tile2(map.side div 2 + x, map.side div 2 + y)

proc fixture(): World =
  result = newWorld(map, Duration)
  for y in -7'i32 .. 7'i32:
    for x in -7'i32 .. 7'i32:
      let i = map.tileIndex(arena(x, y))
      doAssert result.terrainOpen(int32(arena(x, y).x), int32(arena(x, y).y))
      result.blocker[i] = 0
      result.treeWood[i] = 0
  result.place(result.units[0], arena(-5, -1))
  result.place(result.units[1], arena(-5, 1))

proc tree(w: World, at: Tile2): int32 =
  result = map.tileIndex(at)
  w.treeWood[result] = 3000
  w.blocker[result] = TreeBlocker

proc occupiedEntranceTrace(): seq[uint64] =
  let w = fixture()
  let target = w.tree(arena(0, 0))
  # The closest three approaches form a pocket. A stationary peon plugs its
  # only entrance; the east side of the same tree is reachable around it.
  for y in -2'i32 .. 2'i32:
    if y != 0: w.blocker[map.tileIndex(arena(-2, y))] = TreeBlocker
  for x in -1'i32 .. 0'i32:
    for y in [-2'i32, 2'i32]:
      w.blocker[map.tileIndex(arena(x, y))] = TreeBlocker
  for y in [-1'i32, 1'i32]:
    w.blocker[map.tileIndex(arena(0, y))] = TreeBlocker
  w.place(w.units[2], arena(-2, 0))
  for i in 0 .. 1:
    doAssert w.applyHarvest(0, w.units[i].id, target, 1)
  var deposits: array[2, int]
  for tick in 0 ..< TickRate * 100:
    let carried = [w.units[0].carryWood, w.units[1].carryWood]
    let before = [w.units[0].body.pos, w.units[1].body.pos]
    w.tickWorld(nil)
    result.add Game(world: w).stateHash()
    for i in 0 .. 1:
      doAssert w.tileOpen(w.units[i].tile)
      doAssert length(w.units[i].body.pos - before[i]) < FixedOne,
        "Recovery must walk, never teleport"
      if carried[i] > 0 and w.units[i].carryWood == 0: inc deposits[i]
  echo "occupied entrance deposits: ", deposits
  for count in deposits:
    doAssert count >= 2, "Both workers must repeatedly deposit, not retry an unreachable approach forever"
  doAssert w.players[0].woodGathered == int32(deposits[0] + deposits[1]) * WoodPerTrip
  doAssert w.units[2].tile == arena(-2, 0)

doAssert occupiedEntranceTrace() == occupiedEntranceTrace(),
  "Crowded harvest recovery must produce identical per-tick hashes"

block sealedTreeRetargetsWithoutErasingQueuedSuccessors:
  let w = fixture()
  let target = w.tree(arena(0, 0))
  let alternate = w.tree(arena(-3, -4))
  # Only one approach remains, permanently occupied by an idle worker.
  for y in -1'i32 .. 1'i32:
    for x in -1'i32 .. 1'i32:
      if (x != 0 or y != 0) and (x != -1 or y != 0):
        w.blocker[map.tileIndex(arena(x, y))] = TreeBlocker
  w.place(w.units[2], arena(-1, 0))
  w.rebuildVision()
  doAssert w.explored(0, int32(arena(-3, -4).x), int32(arena(-3, -4).y))
  let destinations = [arena(-6, -5), arena(-6, 5)]
  for i in 0 .. 1:
    doAssert w.applyHarvest(0, w.units[i].id, target, 1)
    doAssert w.applyMove(0, w.units[i].id, int32(destinations[i].x),
      int32(destinations[i].y), append = true)
  var deposits: array[2, int]
  for tick in 0 ..< TickRate * 100:
    let carried = [w.units[0].carryWood, w.units[1].carryWood]
    w.tickWorld(nil)
    for i in 0 .. 1:
      if carried[i] > 0 and w.units[i].carryWood == 0: inc deposits[i]
      if deposits[i] == 0:
        doAssert w.units[i].orderQueue.len == 1,
          "A congested wood order must not skip its cycle or erase Shift successors"
  echo "retarget with Shift deposits: ", deposits
  for i in 0 .. 1:
    doAssert deposits[i] == 1, "Each worker must deposit before its queued move"
    doAssert w.units[i].tile == destinations[i]
    doAssert w.units[i].state == UnitIdle
    doAssert w.units[i].carryWood == 0
    doAssert w.units[i].orderQueue.len == 0
  doAssert w.treeWood[target] == 3000
  doAssert w.treeWood[alternate] == 3000 - 2 * WoodPerTrip

block completelyBlockedRingUsesKnownReachableTree:
  let w = fixture()
  let target = w.tree(arena(0, 0))
  let alternate = w.tree(arena(-3, -4))
  for y in -1'i32 .. 1'i32:
    for x in -1'i32 .. 1'i32:
      if x != 0 or y != 0:
        w.blocker[map.tileIndex(arena(x, y))] = TreeBlocker
  w.rebuildVision()
  for i in 0 .. 1:
    doAssert w.applyHarvest(0, w.units[i].id, target, 1)
    doAssert not w.units[i].orderFailed,
      "A sealed target must try reachable known wood before failing"
  var deposits: array[2, int]
  for tick in 0 ..< TickRate * 70:
    let carried = [w.units[0].carryWood, w.units[1].carryWood]
    w.tickWorld(nil)
    for i in 0 .. 1:
      if carried[i] > 0 and w.units[i].carryWood == 0: inc deposits[i]
  echo "sealed ring deposits: ", deposits
  for count in deposits: doAssert count >= 1
  doAssert w.treeWood[target] == 3000
  doAssert w.treeWood[alternate] < 3000

block recoveryDoesNotDiscoverUnexploredWood:
  let w = fixture()
  let target = w.tree(arena(0, 0))
  let hidden = w.tree(arena(-3, -4))
  for y in -1'i32 .. 1'i32:
    for x in -1'i32 .. 1'i32:
      if x != 0 or y != 0:
        w.blocker[map.tileIndex(arena(x, y))] = TreeBlocker
  # No alternate resource is known. Recovery must not mine the world arrays
  # for a secret grove or change exploration stamps during its flood.
  for i in 0 ..< w.explored[0].len: w.explored[0][i] = 0
  let exploredBefore = w.exploredCount[0]
  doAssert w.applyHarvest(0, w.units[0].id, target, 1)
  doAssert w.units[0].state == UnitIdle
  doAssert w.units[0].orderFailed
  doAssert w.treeWood[hidden] == 3000
  doAssert w.exploredCount[0] == exploredBefore
  for known in w.explored[0]: doAssert known == 0

block loadedReassignmentAndOwnershipRemainIntact:
  let w = fixture()
  let target = w.tree(arena(0, 0))
  w.units[0].carryWood = WoodPerTrip
  let before = Game(world: w).stateHash()
  doAssert not w.applyHarvest(1, w.units[0].id, target, 1)
  doAssert Game(world: w).stateHash() == before
  doAssert w.applyHarvest(0, w.units[0].id, target, 1)
  doAssert w.units[0].state == UnitToDropWood
  doAssert w.units[0].carryWood == WoodPerTrip
  doAssert w.applyMove(0, w.units[0].id, int32(arena(-6, -5).x),
    int32(arena(-6, -5).y), append = true)
  for tick in 0 ..< TickRate * 70: w.tickWorld(nil)
  doAssert w.players[0].woodGathered == WoodPerTrip
  doAssert w.units[0].carryWood == 0
  doAssert w.units[0].tile == arena(-6, -5)
  doAssert w.treeWood[target] == 3000

echo "Wood congestion tests passed"
