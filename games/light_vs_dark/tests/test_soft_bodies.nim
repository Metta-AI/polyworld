## Friendly circles compress and push; idle occupancy must not become terrain.
import trafficfixture

block movingPeonPushesIdleFriend:
  let f = trafficFixture(2, "opposing")
  let w = f.world
  let mover = w.units[0]
  let idle = w.units[1]
  mover.kind = PeonUnit
  idle.kind = PeonUnit
  doAssert w.applyCancel(0, idle.id)
  idle.body.pos = fixedVec2(40.5'fx, 40.5'fx)
  idle.tile = tile2(40,40)
  idle.carryGold = 37
  idle.carryWood = 11
  let start = idle.body.pos
  var closest = 10'fx
  var maxIdleStep = FixedZero
  for tick in 0 ..< 300:
    let before = idle.body.pos
    w.tickWorld(nil)
    closest = min(closest, length(mover.body.pos-idle.body.pos))
    maxIdleStep = max(maxIdleStep, length(idle.body.pos-before))
  doAssert length(idle.body.pos-start) > 0.2'fx,
    "A moving peon must push its idle friend, not route around a hard occupied tile"
  doAssert closest < 0.4'fx, "Rubber bodies must allow real transient overlap"
  doAssert maxIdleStep <= 0.081'fx, "No tile-sized separation teleport"
  doAssert length(mover.body.pos-f.goals[0]) <= 0.4'fx
  doAssert idle.state == UnitIdle and not idle.hasGoal
  doAssert idle.carryGold == 37 and idle.carryWood == 11

block occupiedMineExit:
  let f = trafficFixture(0, "miners")
  let w = f.world
  let mine = w.buildings[w.buildingIndex(FirstMineId)]
  for y in mine.origin.y.int32-1 .. mine.origin.y.int32+mine.footprint.depth:
    for x in mine.origin.x.int32-1 .. mine.origin.x.int32+mine.footprint.width:
      if w.tileOpen(x,y): discard w.spawnUnit(0, PeonUnit, tile2(x,y))
  let id = w.spawnUnit(0, PeonUnit, tile2(mine.origin.x.int32-1, mine.origin.y.int32-1))
  let miner = w.units[w.unitIndex(id)]
  doAssert w.applyHarvest(0,id,FirstMineId,0)
  w.tickWorld(nil)
  doAssert miner.state == UnitInMine
  var deposits = 0
  for tick in 0 ..< 2400:
    let cargo = miner.carryGold
    w.tickWorld(nil)
    if cargo > 0 and miner.carryGold == 0: inc deposits
    doAssert w.buildings[w.buildingIndex(FirstMineId)].minersInside <= MinersPerMine
  doAssert deposits >= 2, "An occupied friendly exit ring must not imprison miners"
  echo "Occupied mine exit deposits: ", deposits

block approachAndAdmitThroughOccupiedMineRing:
  let w = trafficFixture(0,"miners").world
  let mine = w.buildings[w.buildingIndex(FirstMineId)]
  var ringIds: seq[int32]
  for y in mine.origin.y.int32-1 .. mine.origin.y.int32+mine.footprint.depth:
    for x in mine.origin.x.int32-1 .. mine.origin.x.int32+mine.footprint.width:
      if w.tileOpen(x,y):
        let id = w.spawnUnit(0,PeonUnit,tile2(x,y))
        ringIds.add id
  let id = w.spawnUnit(0,PeonUnit,tile2(52,40))
  let miner = w.units[w.unitIndex(id)]
  let start = miner.body.pos
  doAssert w.applyHarvest(0,id,FirstMineId,0)
  var entered = false
  for tick in 0 ..< 900:
    w.tickWorld(nil)
    if miner.state == UnitInMine:
      entered = true
      break
  doAssert entered, "A real approaching miner must enter through idle soft bodies"
  doAssert length(miner.body.pos-start) > 3'fx
  for friend in ringIds:
    let u = w.units[w.unitIndex(friend)]
    doAssert u.state == UnitIdle and not u.hasGoal
  # Admission uses the adjacent cell, before necessarily contacting its idle
  # centre. The separate movingPeonPushesIdleFriend test proves actual pushing.

block coincidentCrowdRecovers:
  let f = trafficFixture(40, "opposing")
  let w = f.world
  let center = fixedVec2(40.5'fx,40.5'fx)
  for unit in w.units:
    doAssert w.applyCancel(0, unit.id)
    unit.kind = PeonUnit
    unit.body.pos = center
    unit.tile = tile2(40,40)
  let peer = w.clone()
  for tick in 0 ..< 300:
    var before: seq[FixedVec2]
    for unit in w.units: before.add unit.body.pos
    w.tickWorld(nil)
    peer.tickWorld(nil)
    doAssert Game(world:w).stateHash() == Game(world:peer).stateHash()
    for i,unit in w.units:
      doAssert length(unit.body.pos-before[i]) <= 0.081'fx
  var moved = 0
  for unit in w.units:
    if length(unit.body.pos-center) > 0.2'fx: inc moved
  doAssert moved == w.units.len, "Overflow must not freeze omitted friendly actors"

block fullMineQueueAndRepeatedDeposits:
  let f = trafficFixture(0, "miners")
  let w = f.world
  var ids: seq[int32]
  for i in 0 ..< MinersPerMine+3:
    let id = w.spawnUnit(0, PeonUnit, tile2(56,39+i mod 3))
    ids.add id
    doAssert w.applyHarvest(0,id,FirstMineId,0)
  let queued = w.units[w.unitIndex(ids[^1])]
  doAssert w.applyMove(0,queued.id,50,35,append=true)
  let peer = w.clone()
  var deposits = newSeq[int](ids.len)
  var sawFullWait, sawInside, sawExit: bool
  for tick in 0 ..< 3600:
    var carried: seq[int32]
    for id in ids: carried.add w.units[w.unitIndex(id)].carryGold
    w.tickWorld(nil)
    peer.tickWorld(nil)
    doAssert Game(world:w).stateHash() == Game(world:peer).stateHash()
    var inside = 0
    for i,id in ids:
      let u = w.units[w.unitIndex(id)]
      if u.state == UnitInMine: inc inside; sawInside = true
      if carried[i] == 0 and u.carryGold > 0: sawExit = true
      if carried[i] > 0 and u.carryGold == 0: inc deposits[i]
      if w.buildings[w.buildingIndex(FirstMineId)].minersInside == MinersPerMine and u.state == UnitToMine:
        sawFullWait = true
      doAssert not u.orderFailed
    doAssert inside == w.buildings[w.buildingIndex(FirstMineId)].minersInside and inside <= MinersPerMine
    if deposits[^1] == 0: doAssert queued.orderQueue.len == 1
  doAssert sawFullWait and sawInside and sawExit
  for i in 0 ..< deposits.len-1: doAssert deposits[i] >= 2
  doAssert deposits[^1] == 1 and queued.orderQueue.len == 0
  doAssert queued.state == UnitIdle and queued.tile == tile2(50,35)
  echo "Full mine deposits: ", deposits

block wallPinnedIdleCannotPhase:
  let f = trafficFixture(2, "opposing")
  let w = f.world
  for unit in w.units:
    doAssert w.applyCancel(0,unit.id)
    unit.kind = PeonUnit
  w.place(w.units[0],tile2(39,40))
  w.place(w.units[1],tile2(40,40))
  for y in 35'i32 .. 45'i32: w.blocker[w.map.tileIndex(41,y)] = TreeBlocker
  doAssert w.applyMove(0,w.units[0].id,42,40)
  for tick in 0 ..< 200:
    w.tickWorld(nil)
    for unit in w.units:
      for dx in [-unit.body.radius,unit.body.radius]:
        for dy in [-unit.body.radius,unit.body.radius]:
          let p = unit.body.pos+fixedVec2(dx,dy)
          doAssert w.tileOpen(whole(p.x),whole(p.y))

block workingConstructorIsAnchored:
  let f = trafficFixture(0, "opposing")
  let w = f.world
  w.players[0].gold = 10000
  w.players[0].wood = 10000
  let builderId = w.spawnUnit(0,PeonUnit,tile2(39,40))
  let builder = w.units[w.unitIndex(builderId)]
  doAssert w.applyBuild(0,builderId,FarmBuilding.ord.int32,40,40)
  for tick in 0 ..< 30:
    w.tickWorld(nil)
    if builder.state == UnitBuilding: break
  doAssert builder.state == UnitBuilding
  let start = builder.body.pos
  let site = w.buildingIndex(builder.targetId)
  let initialWork = w.buildings[site].buildTicks
  let mover = w.spawnUnit(0,PeonUnit,tile2(38,40))
  doAssert w.applyMove(0,mover,39,40)
  for tick in 0 ..< 60:
    w.tickWorld(nil)
    doAssert builder.body.pos == start
    doAssert builder.state == UnitBuilding
  doAssert w.buildings[site].buildTicks < initialWork

block softChokeThroughput:
  let f = trafficFixture(20, "choke")
  for tick in 0 ..< 900: f.world.tickWorld(nil)
  var completed = 0
  for i,u in f.world.units:
    if length(u.body.pos-f.goals[i]) <= 0.4'fx: inc completed
  doAssert completed >= 18, "Soft contact must not become a yield/wait choke deadlock"

echo "Soft body tests passed"
