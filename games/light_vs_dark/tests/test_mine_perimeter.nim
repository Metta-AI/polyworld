## Mines use the same complete row-major footprint ring as trained units.
import trafficfixture

proc insideMiner(w: World): Unit =
  let id = w.spawnUnit(0,PeonUnit,tile2(56,40))
  result = w.units[w.unitIndex(id)]
  doAssert w.applyHarvest(0,id,FirstMineId,0)
  w.tickWorld(nil)
  doAssert result.state == UnitInMine
  result.stateTicks = 0

proc sealExcept(w: World, origin: Tile2, size: Footprint, opening: Tile2) =
  for y in origin.y.int32-1 .. origin.y.int32+size.depth:
    for x in origin.x.int32-1 .. origin.x.int32+size.width:
      if not covers(origin,size,x,y) and tile2(x,y) != opening:
        w.blocker[w.map.tileIndex(x,y)] = TreeBlocker

block everySideAndCorner:
  # One legal point, individually on N/E/S/W and all four corners.
  for delta in [tile2(1,-1),tile2(3,1),tile2(1,3),tile2(-1,1),
      tile2(-1,-1),tile2(3,-1),tile2(-1,3),tile2(3,3)]:
    let w = trafficFixture(0,"miners").world
    let mine = w.buildings[w.buildingIndex(FirstMineId)]
    let miner = insideMiner(w)
    let opening = tile2(mine.origin.x+delta.x,mine.origin.y+delta.y)
    sealExcept(w,mine.origin,mine.footprint,opening)
    doAssert w.freeTileAround(mine.origin,mine.footprint) == opening
    let gold = mine.goldLeft
    w.tickWorld(nil)
    doAssert miner.state == UnitToDropGold and miner.tile == opening
    doAssert miner.carryGold == GoldPerTrip
    doAssert w.buildings[w.buildingIndex(FirstMineId)].goldLeft == gold-GoldPerTrip
    doAssert w.buildings[w.buildingIndex(FirstMineId)].minersInside == 0
    for dx in [-miner.body.radius,miner.body.radius]:
      for dy in [-miner.body.radius,miner.body.radius]:
        let p = miner.body.pos+fixedVec2(dx,dy)
        doAssert w.tileOpen(whole(p.x),whole(p.y))
    # Exercise the actual trained-unit completion path, not only its helper.
    let spawned = trafficFixture(0,"miners").world
    var hall = -1
    for i,b in spawned.buildings:
      if b.owner == 0 and b.kind == TownHallBuilding: hall=i
    let b = spawned.buildings[hall]
    let at = tile2(b.origin.x+(if delta.x == 3: b.footprint.width else: delta.x.int32),
      b.origin.y+(if delta.y == 3: b.footprint.depth else: delta.y.int32))
    sealExcept(spawned,b.origin,b.footprint,at)
    spawned.players[0].gold = 10000
    spawned.players[0].wood = 10000
    spawned.players[0].foodUsed = 0
    doAssert spawned.applyTrain(0,b.id,PeonUnit.ord.int32)
    spawned.buildings[hall].trainTicks = 1
    spawned.tickWorld(nil)
    doAssert spawned.units.len == 1 and spawned.units[0].tile == at

block sealedWaitsWithoutCargoOrTeleport:
  let w = trafficFixture(0,"miners").world
  let miner = insideMiner(w)
  let mine = w.buildings[w.buildingIndex(FirstMineId)]
  doAssert w.applyMove(0,miner.id,50,35,append=true)
  sealExcept(w,mine.origin,mine.footprint,NoTile)
  let position = miner.body.pos
  for tick in 0 ..< 120:
    w.tickWorld(nil)
    doAssert miner.state == UnitInMine and miner.body.pos == position
    doAssert miner.carryGold == 0 and miner.orderQueue.len == 1
    doAssert w.buildings[w.buildingIndex(FirstMineId)].goldLeft == mine.goldLeft
    doAssert w.buildings[w.buildingIndex(FirstMineId)].minersInside == 1
  # Open a rear point only, then finish the deposit and Shift successor.
  w.blocker[w.map.tileIndex(mine.origin.x+1,mine.origin.y+3)] = 0
  w.tickWorld(nil)
  doAssert miner.state == UnitToDropGold and miner.tile == tile2(58,42)
  doAssert miner.carryGold == GoldPerTrip and miner.orderQueue.len == 1
  # The exit itself is the single-point acceptance gate. Restore ordinary
  # travel space for the independent cargo/deposit/Shift continuation gate.
  for y in mine.origin.y.int32-1 .. mine.origin.y.int32+mine.footprint.depth:
    for x in mine.origin.x.int32-1 .. mine.origin.x.int32+mine.footprint.width:
      if not covers(mine.origin,mine.footprint,x,y): w.blocker[w.map.tileIndex(x,y)] = 0
  for tick in 0 ..< 1800: w.tickWorld(nil)
  doAssert w.players[0].goldGathered == GoldPerTrip
  doAssert miner.state == UnitIdle and miner.tile == tile2(50,35)
  doAssert miner.orderQueue.len == 0 and miner.carryGold == 0

block freeTileMustAlsoBeForeignBodySafe:
  let w = trafficFixture(0,"miners").world
  let miner = insideMiner(w)
  let mine = w.buildings[w.buildingIndex(FirstMineId)]
  let opening = tile2(56,40)
  sealExcept(w,mine.origin,mine.footprint,opening)
  let foreignId = w.spawnUnit(1,PeonUnit,tile2(55,40))
  let foreign = w.units[w.unitIndex(foreignId)]
  foreign.body.pos = fixedVec2(55.99'fx,40.5'fx)
  foreign.body.radius = 0.4'fx
  # The opening occupancy slot is empty, but the foreign circle overlaps it.
  doAssert w.freeTileAround(mine.origin,mine.footprint) == opening
  w.tickWorld(nil)
  doAssert miner.state == UnitInMine and miner.carryGold == 0,
    "Mine exits must reject foreign circle overlap even in an empty tile"

block frontBlockedOtherSidesDeposit:
  let w = trafficFixture(0,"miners").world
  let miner = insideMiner(w)
  let mine = w.buildings[w.buildingIndex(FirstMineId)]
  # Block the entire minimum-y edge (including both corners).
  for x in mine.origin.x.int32-1 .. mine.origin.x.int32+mine.footprint.width:
    w.blocker[w.map.tileIndex(x,mine.origin.y.int32-1)] = TreeBlocker
  w.tickWorld(nil)
  doAssert miner.state == UnitToDropGold and miner.tile.y >= mine.origin.y
  for tick in 0 ..< 2400: w.tickWorld(nil)
  doAssert w.players[0].goldGathered >= GoldPerTrip*2

echo "Full mine perimeter, trained-spawn parity, safety and deposits passed"
