import
  polyworld/[bodies, fixed, pathing],
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

proc fixture(towerIndex: int): Game =
  ## Isolates movement around one real tower on the default map.
  result = newGame(generateMap(2026), 100_000, 10, false, ReplayData())
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.manualSpells = true
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for i, tower in result.world.towers.mpairs:
    if i != towerIndex:
      tower.hp = 0
  let hero = result.world.heroes[0]
  hero.hp = 100_000
  hero.maxHp = hero.hp
  hero.state = Marching
  hero.class = VanguardKnight
  hero.team = result.world.towers[towerIndex].team
  var start = result.world.towers[towerIndex].position
  start.x -= 2 * WorldScale
  hero.place(start)

proc finishWalk(game: Game) =
  ## Gives a walk command twenty seconds to complete.
  for tick in 0 ..< TickRate * 20:
    game.tickWorld(nil)
    if not game.world.heroes[0].hasMoveTarget:
      break

echo "Testing a hero walk command into a living tower finishes beside it"
for towerIndex in 0 ..< 18:
  let
    game = fixture(towerIndex)
    hero = game.world.heroes[0]
    tower = game.world.towers[towerIndex]
  doAssert game.world.applyWalkTo(hero.id,
    mapCoordinate(tower.position.x), mapCoordinate(tower.position.z))
  game.finishWalk()
  doAssert not hero.hasMoveTarget,
    "hero stuck walking into tower " & $towerIndex

echo "Testing hero walks across towers from nearby, off-center positions"
for towerIndex in 0 ..< 18:
  let
    game = fixture(towerIndex)
    hero = game.world.heroes[0]
    tower = game.world.towers[towerIndex]
  var start = tower.position
  start.x -= WorldScale
  hero.place(start)
  var finish = tower.position
  finish.x += 2 * WorldScale
  doAssert game.world.applyWalkTo(hero.id,
    mapCoordinate(finish.x), mapCoordinate(finish.z))
  let goal = hero.movePath[^1]
  game.finishWalk()
  doAssert not hero.hasMoveTarget and within(hero.position, goal, 21_000),
    "hero failed to pass tower " & $towerIndex

echo "Testing heroes can still close to siege range of every tower tier"
for towerIndex in 0 .. 2:
  let
    game = fixture(towerIndex)
    hero = game.world.heroes[0]
    tower = game.world.towers[towerIndex]
  hero.team = BlueTeam
  doAssert game.world.applyAttackTarget(hero.id, tower.id)
  for tick in 0 ..< TickRate * 20:
    game.tickWorld(nil)
    if game.world.towers[towerIndex].hp < tower.hp:
      break
  doAssert game.world.towers[towerIndex].hp < tower.hp,
    "hero stuck approaching enemy tower " & $towerIndex

echo "Testing hero combat chases pass friendly towers"
for towerIndex in 0 ..< 18:
  let
    game = fixture(towerIndex)
    hero = game.world.heroes[0]
    target = game.world.heroes[5]
    tower = game.world.towers[towerIndex]
  target.team = if tower.team == RedTeam: BlueTeam else: RedTeam
  target.hp = 100_000
  target.maxHp = target.hp
  target.state = Marching
  var finish = tower.position
  finish.x += 2 * WorldScale
  target.place(finish)
  doAssert game.world.applyAttackTarget(hero.id, target.id)
  for tick in 0 ..< TickRate * 20:
    target.place(finish)
    game.tickWorld(nil)
    if hero.attacksLanded > 0:
      break
  doAssert hero.attacksLanded > 0,
    "hero stuck chasing an enemy across tower " & $towerIndex

echo "Testing creeps chase enemies across friendly towers in both teams"
for towerIndex in 0 ..< 18:
  let
    game = fixture(towerIndex)
    target = game.world.heroes[5]
    tower = game.world.towers[towerIndex]
  game.world.heroes[0].hp = 0
  game.world.heroes[0].state = Dying
  target.team = if tower.team == RedTeam: BlueTeam else: RedTeam
  target.hp = 100_000
  target.maxHp = target.hp
  target.state = Marching
  var finish = tower.position
  finish.x += WorldScale
  target.place(finish)
  var start = tower.position
  start.x -= WorldScale
  var creep = Footman(id: 1000, team: tower.team, lane: tower.lane,
    hp: 100_000, state: Marching, swingTicks: -1)
  creep.body.radius = 0.22'fx
  creep.place(start)
  game.world.footmen.add creep
  for tick in 0 ..< TickRate * 20:
    target.place(finish)
    game.tickWorld(nil)
    if within(game.world.footmen[0].position, finish, FootmanMeleeRange):
      break
  doAssert within(game.world.footmen[0].position, finish, FootmanMeleeRange),
    "creep stuck chasing through friendly tower " & $towerIndex

echo "Testing creeps rejoin a lane from the opposite side of a tower"
var rejoinCases = 0
for towerIndex in 0 ..< 18:
  let
    game = fixture(towerIndex)
    tower = game.world.towers[towerIndex]
    route = lanePathPoints[tower.lane]
  game.world.heroes[0].hp = 0
  game.world.heroes[0].state = Dying
  var
    closest = int64.high
    goalIndex = -1
    start: WorldPoint
  for i, waypoint in route:
    let
      point = WorldPoint(x: waypoint.x * (WorldScale div PathUnitsPerTile),
        y: waypoint.y * (WorldScale div PathUnitsPerTile),
        z: waypoint.z * (WorldScale div PathUnitsPerTile))
      mirrored = WorldPoint(x: tower.position.x * 2 - point.x,
        y: tower.position.y, z: tower.position.z * 2 - point.z)
      x = int(mapCoordinate(mirrored.x))
      z = int(mapCoordinate(mirrored.z))
      dx = int64(point.x) - tower.position.x
      dz = int64(point.z) - tower.position.z
      distance = dx * dx + dz * dz
    for layerIndex, layer in layers:
      if not layer.water and distance < closest and
          isWalkable(layerIndex, x, z):
        closest = distance
        goalIndex = i
        start = mirrored
        start.y = pathPoint(layerIndex, x, z).y *
          (WorldScale div PathUnitsPerTile)
  # Some gate towers sit beyond the lane endpoint against the map rim;
  # their reflected lane is outside the arena, so no such rejoin exists.
  if goalIndex < 0:
    continue
  inc rejoinCases
  let waypointIndex = if tower.team == RedTeam: goalIndex
    else: route.high - goalIndex
  var creep = Footman(id: 1000, team: tower.team, lane: tower.lane,
    hp: 100_000, state: Marching, swingTicks: -1,
    waypointIndex: waypointIndex)
  creep.body.radius = 0.22'fx
  creep.place(start)
  game.world.footmen.add creep
  for tick in 0 ..< TickRate * 20:
    game.tickWorld(nil)
    if game.world.footmen[0].waypointIndex > waypointIndex:
      break
  doAssert game.world.footmen[0].waypointIndex > waypointIndex,
    "creep failed to rejoin its lane around tower " & $towerIndex
doAssert rejoinCases >= 6

echo "Testing destroyed towers release their tiles and rewind restores them"
block:
  let
    game = fixture(2)
    hero = game.world.heroes[0]
    tower = game.world.towers[2]
    snapshot = game.world.clone()
  game.world.towers[2].hp = 1
  hero.team = BlueTeam
  doAssert game.world.applyAttackTarget(hero.id, tower.id)
  for tick in 0 ..< TickRate * 20:
    game.tickWorld(nil)
    if game.world.towers[2].hp <= 0:
      break
  doAssert game.world.towers[2].hp <= 0
  doAssert isWalkable(GroundLayer, int(mapCoordinate(tower.position.x)),
    int(mapCoordinate(tower.position.z)))
  doAssert game.world.applyWalkTo(hero.id,
    mapCoordinate(tower.position.x), mapCoordinate(tower.position.z))
  let goal = hero.movePath[^1]
  doAssert isWalkable(GroundLayer, int(mapCoordinate(tower.position.x)),
    int(mapCoordinate(tower.position.z)))
  doAssert mapCoordinate(goal.x) == mapCoordinate(tower.position.x)
  doAssert mapCoordinate(goal.z) == mapCoordinate(tower.position.z)
  game.finishWalk()
  doAssert not hero.hasMoveTarget and within(hero.position, goal, 21_000)
  game.world.restore(snapshot)
  doAssert not isWalkable(GroundLayer, int(mapCoordinate(tower.position.x)),
    int(mapCoordinate(tower.position.z)))
  doAssert generateMap(2026).hash == game.map.hash,
    "tower destruction changed the cached map terrain"
