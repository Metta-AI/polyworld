## Direct moves retain player intent after combat, arrival and path failure.
import trafficfixture

block moveHoldsAfterArrival:
  let
    world = trafficFixture(0, "open").world
    soldierId = world.spawnUnit(0, SoldierUnit, tile2(38, 30))
    enemyId = world.spawnUnit(1, PeonUnit, tile2(43, 30))
    soldier = world.units[world.unitIndex(soldierId)]
    enemy = world.units[world.unitIndex(enemyId)]
  world.rebuildVision()
  doAssert world.applyAttack(0, soldierId, enemyId)
  doAssert world.applyMove(0, soldierId, 40, 30)
  let hp = enemy.hp
  for tick in 0 ..< TickRate * 12:
    world.tickWorld(nil)
    doAssert soldier.state in {UnitMoving, UnitIdle}
    doAssert soldier.targetId == NoEntity
    doAssert soldier.holdPosition
    doAssert enemy.hp == hp
  doAssert soldier.state == UnitIdle
  doAssert length(soldier.body.pos - fixedVec2(40.5'fx, 30.5'fx)) <= 0.4'fx
  let peer = world.clone()
  doAssert Game(world: world).stateHash() == Game(world: peer).stateHash()
  soldier.holdPosition = false
  doAssert Game(world: world).stateHash() != Game(world: peer).stateHash()
  world.restore(peer)
  doAssert world.applyAttackMove(0, soldierId, 49, 30)
  doAssert not world.units[world.unitIndex(soldierId)].holdPosition
  for tick in 0 ..< TickRate * 8:
    world.tickWorld(nil)
  doAssert not world.hasUnit(enemyId) or
    world.units[world.unitIndex(enemyId)].hp < hp

block unreachableMoveDoesNotResumeChasing:
  let
    world = trafficFixture(0, "open").world
    id = world.spawnUnit(0, SoldierUnit, tile2(40, 30))
    unit = world.units[world.unitIndex(id)]
  for y in 29'i32 .. 31'i32:
    for x in 39'i32 .. 41'i32:
      world.blocker[world.map.tileIndex(x, y)] = TreeBlocker
  doAssert world.applyMove(0, id, 50, 30)
  for tick in 0 ..< TickRate:
    world.tickWorld(nil)
  doAssert unit.orderFailed
  doAssert unit.state == UnitIdle and unit.holdPosition
  doAssert world.applyAttackMove(0, id, 50, 30)
  doAssert not unit.holdPosition

echo "Direct move priority, retained destination and explicit attack override passed"
