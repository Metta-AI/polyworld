## Reproduces combat-unit traffic deadlocks without combat, bots or rendering.
import trafficfixture, ../localgrid

for scenario in ["opposing", "crossing"]:
  let f = trafficFixture(2, scenario)
  let peer = f.world.clone()
  for tick in 0 ..< 900:
    f.world.tickWorld(nil)
    peer.tickWorld(nil)
    doAssert Game(world:f.world).stateHash() == Game(world:peer).stateHash()
  for i, unit in f.world.units:
    doAssert length(unit.body.pos - f.goals[i]) <= 0.4'fx,
      scenario & ": both soldiers must finish, not push indefinitely"
echo "Local avoidance tests passed"

block boundedDenseBucket:
  var grid: LocalGrid
  grid.reset(80, 1000)
  for i in countdown(999, 0): grid.insert(int32(i), fixedVec2(40.5'fx, 40.5'fx))
  var visited = 0
  for index in grid.neighbors(fixedVec2(40.5'fx, 40.5'fx)):
    doAssert index == visited.int32
    inc visited
  doAssert visited == LocalBucketLimit
  grid.reset(80, 0)
  for index in grid.neighbors(fixedVec2(40.5'fx, 40.5'fx)):
    doAssert false, "Rebuild must discard prior-world scratch"

block conservativeOverflow:
  var grid: LocalGrid
  grid.reset(80, 17)
  for i in countdown(16, 0): grid.insert(int32(i), fixedVec2(40.5'fx,40.5'fx))
  doAssert grid.crowded(fixedVec2(39.9'fx,40.5'fx), 0.22'fx),
    "Omitted bodies must conservatively block the full dense cell"
  doAssert not grid.crowded(fixedVec2(39.5'fx,40.5'fx), 0.22'fx)
  grid.reset(80,0)
  doAssert not grid.crowded(fixedVec2(40.5'fx,40.5'fx), 0.22'fx)

block denseEnemyEnvelope:
  let f = trafficFixture(20, "opposing")
  let w = f.world
  for i in 1 ..< w.units.len:
    w.units[i].owner = 1
    w.units[i].hasGoal = false
    w.units[i].state = UnitMoving
    w.units[i].body.pos = fixedVec2(40.5'fx,40.5'fx)
    w.units[i].tile = tile2(40,40)
  w.units[0].body.pos = fixedVec2(39.5'fx,40.5'fx)
  w.units[0].tile = tile2(39,40)
  doAssert w.applyMove(0,w.units[0].id,43,40)
  for tick in 0 ..< 120:
    # Keep this a body-only fixture: no idle combat acquisition can disperse
    # the fabricated overlapping enemy stack during the collision assertion.
    for i in 1 ..< w.units.len:
      w.units[i].state = UnitMoving
      w.units[i].hasGoal = false
      w.units[i].body.pos = fixedVec2(40.5'fx,40.5'fx)
      w.units[i].tile = tile2(40,40)
    w.tickWorld(nil)
    doAssert w.units[0].body.pos.x < 40'fx,
      "A prefix-limited query must not let a mover enter omitted enemy bodies"

block opposingEnemyBodies:
  let f = trafficFixture(2, "opposing")
  f.world.units[1].owner = 1
  # Different owners retain body collision and never reserve friendly yields,
  # even while ordinary movement suppresses attack acquisition.
  for tick in 0 ..< 120:
    f.world.tickWorld(nil)
    for unit in f.world.units: doAssert unit.passingTicks == 0
    doAssert f.world.units[0].body.pos.x < f.world.units[1].body.pos.x

block attackMoveCrossing:
  let f = trafficFixture(2, "crossing")
  for i, id in f.ids:
    doAssert f.world.applyAttackMove(0, id, whole(f.goals[i].x), whole(f.goals[i].y))
  for tick in 0 ..< 900: f.world.tickWorld(nil)
  for i, unit in f.world.units:
    doAssert length(unit.body.pos - f.goals[i]) <= 0.4'fx
