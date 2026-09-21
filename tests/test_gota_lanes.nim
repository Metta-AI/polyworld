import
  std/sequtils,
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

proc quietGame(size = 116, heroes = 0): Game =
  ## Creates a deterministic arena with no recurring waves or bot decisions.
  var preset = defaultConfig()
  preset.mapSize = size
  result = newGame(
    generateMap(2026, preset),
    100_000,
    heroes,
    false,
    ReplayData(),
    drafting = false
  )
  result.world.heroTurnTicks = 100_000
  result.world.spawnTimerTicks = 100_000

proc point(tile: PathTile): WorldPoint =
  ## Converts one navigation tile center into simulation coordinates.
  let p = pathPoint(int(tile.layer), int(tile.x), int(tile.z))
  WorldPoint(x: p.x * (WorldScale div PathUnitsPerTile),
    y: p.y * (WorldScale div PathUnitsPerTile),
    z: p.z * (WorldScale div PathUnitsPerTile))

proc standingTile(creep: Footman): PathTile =
  ## Resolves a creep's current cell on its own navigation layer.
  let floor = layers[creep.navLayer]
  PathTile(layer: creep.navLayer,
    x: mapCoordinate(creep.position.x) + int32(mapOrigin() - floor.originX),
    z: mapCoordinate(creep.position.z) + int32(mapOrigin() - floor.originZ))

echo "Testing living tower and barracks footprints across supported map sizes"
for size in [64, 116, 256]:
  let game = quietGame(size)
  doAssert game.world.buildings.len == 34
  for building in game.world.buildings:
    doAssert building.footprint.len > 0
    for tile in building.footprint:
      doAssert not navigationOpen(int(tile.layer), int(tile.x), int(tile.z))
  game.world.spawnTimerTicks = 1
  game.tickWorld(nil)
  doAssert game.world.footmen.len == 12 * CreepsPerBarracks
  for creep in game.world.footmen:
    let tile = creep.standingTile()
    doAssert navigationOpen(int(tile.layer), int(tile.x), int(tile.z)),
      "blocked spawn on map " & $size
    var midpoint: WorldPoint
    for building in game.world.buildings:
      if building.kind == BarracksBuilding and
          building.team == creep.team and building.lane == creep.lane:
        midpoint.x += building.position.x div 2
        midpoint.z += building.position.z div 2
    let first = creep.creepWaypoints()[0]
    doAssert abs(first.x - midpoint.x) <= WorldScale div 2
    doAssert abs(first.z - midpoint.z) <= WorldScale div 2
    let
      dx = int64(first.x) - creep.position.x
      dz = int64(first.z) - creep.position.z
    if dx * dx + dz * dz <= int64(WaypointRadius) * WaypointRadius:
      doAssert creep.waypointIndex > 0,
        "new creeps within six tiles must clear the barracks exit"

echo "Testing both teams route past their buildings in all three lanes"
for size in [64, 116, 256]:
  for team in Team:
    let game = quietGame(size)
    game.world.spawnTimerTicks = 1
    game.tickWorld(nil)
    game.world.footmen = game.world.footmen.filterIt(it.team == team)
    doAssert game.world.footmen.len == 6 * CreepsPerBarracks
    for building in game.world.buildings.mitems:
      building.team = team
    var reached = newSeq[bool](game.world.footmen.len)
    for tick in 0 ..< TickRate * 240:
      game.tickWorld(nil)
      for i, creep in game.world.footmen:
        let tile = creep.standingTile()
        doAssert navigationOpen(int(tile.layer), int(tile.x), int(tile.z)),
          "creep entered building or blocked terrain"
        if creep.waypointIndex >= creep.creepWaypoints().len div 2 + 1:
          reached[i] = true
      if reached.allIt(it):
        break
    for i, passed in reached:
      let creep = game.world.footmen[i]
      doAssert passed, $team & " map " & $size & " lane " & $creep.lane &
        " stuck at " & $creep.position & " waypoint " & $creep.waypointIndex &
        " path " & $creep.movePathIndex & "/" & $creep.movePath.len &
        " route " & $creep.movePath

echo "Testing building destruction restores only underlying open terrain"
block:
  let game = quietGame()
  let snapshot = game.world.clone()
  for building in game.world.buildings.mitems:
    building.hp = 0
  game.world.syncBuildings()
  for building in game.world.buildings:
    for tile in building.footprint:
      doAssert navigationOpen(int(tile.layer), int(tile.x), int(tile.z)) ==
        isWalkable(int(tile.layer), int(tile.x), int(tile.z))
  game.world.restore(snapshot)
  for building in game.world.buildings:
    doAssert building.hp > 0
    for tile in building.footprint:
      doAssert not navigationOpen(int(tile.layer), int(tile.x), int(tile.z))

echo "Testing barracks protection and three creeps per surviving barracks"
block:
  let game = quietGame()
  let index = 18
  doAssert game.world.buildings[index].kind == BarracksBuilding
  doAssert not game.world.buildingExposed(game.world.buildings[index])
  for building in game.world.buildings.mitems:
    if building.kind == TowerBuilding and
        building.team == game.world.buildings[index].team and
        building.lane == game.world.buildings[index].lane:
      building.hp = 0
  doAssert game.world.buildingExposed(game.world.buildings[index])
  game.world.buildings[index].hp = 0
  game.world.spawnTimerTicks = 1
  game.tickWorld(nil)
  doAssert game.world.footmen.len == 11 * CreepsPerBarracks
  let snapshot = game.world.clone()
  game.world.restore(snapshot)
  game.world.spawnTimerTicks = 1
  game.tickWorld(nil)
  doAssert game.world.footmen.len == 22 * CreepsPerBarracks

echo "Testing waypoint radius and progress during pursuit"
block:
  doAssert WaypointRadius == 6 * WorldScale
  let game = quietGame()
  var creep = Footman(team: RedTeam, lane: 0, hp: FootmanHp, state: Fighting)
  let goals = creep.creepWaypoints()
  doAssert goals.len > 2
  creep.position = goals[1]
  creep.position.x += WaypointRadius + 1
  creep.waypointIndex = 1
  creep.advanceWaypoints()
  doAssert creep.waypointIndex == 1
  dec creep.position.x
  creep.advanceWaypoints()
  doAssert creep.waypointIndex >= 2
  let advanced = creep.waypointIndex
  creep.position = goals[0]
  creep.advanceWaypoints()
  doAssert creep.waypointIndex >= advanced
echo "Testing overlapping building blockers survive a neighbor's destruction"
block:
  let game = quietGame()
  var copy = game.world.buildings[0]
  copy.id = 99
  copy.occupied = false
  game.world.buildings.add copy
  game.world.syncBuildings()
  game.world.buildings[0].hp = 0
  game.world.syncBuildings()
  for tile in copy.footprint:
    doAssert not navigationOpen(int(tile.layer), int(tile.x), int(tile.z))
  game.world.buildings[^1].hp = 0
  game.world.syncBuildings()
  for tile in copy.footprint:
    doAssert navigationOpen(int(tile.layer), int(tile.x), int(tile.z)) ==
      isWalkable(int(tile.layer), int(tile.x), int(tile.z))

echo "Testing the combat tick clears a reached waypoint while chasing"
block:
  let game = quietGame(116, 10)
  for hero in game.world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
    hero.manualSpells = true
  let enemy = game.world.heroes[5]
  enemy.hp = enemy.maxHp
  enemy.state = Marching
  var creep = Footman(id: 1000, team: RedTeam, lane: 0, hp: FootmanHp,
    state: Fighting, targetHeroId: enemy.id, waypointIndex: 2)
  let destination = creep.creepWaypoints()[2]
  creep.place(destination)
  var pursuit = destination
  pursuit.x += WorldScale * 2
  enemy.place(pursuit)
  game.world.footmen = @[creep]
  game.tickWorld(nil)
  doAssert game.world.footmen[0].waypointIndex > 2
  doAssert game.world.footmen[0].targetHeroId == enemy.id

echo "Testing BASIC building visibility and barracks combat from outside tiles"
block:
  let
    game = quietGame(116, 10)
    hero = game.world.heroes[0]
  for other in game.world.heroes:
    other.hp = 0
    other.state = Dying
    other.deathTicks = -100_000
    other.manualSpells = true
  hero.hp = 100_000
  hero.state = Marching
  var victim = -1
  for i, building in game.world.buildings:
    if building.kind == BarracksBuilding and building.team != hero.team:
      victim = i
      break
  let target = game.world.buildings[victim]
  for building in game.world.buildings.mitems:
    if building.kind == TowerBuilding and building.team == target.team and
        building.lane == target.lane:
      building.hp = 0
  game.world.syncBuildings()
  var placed = false
  for tile in target.footprint:
    for dz in -2 .. 2:
      for dx in -2 .. 2:
        let candidate = PathTile(layer: tile.layer,
          x: tile.x + dx.int32, z: tile.z + dz.int32)
        if not placed and navigationOpen(int(candidate.layer),
            int(candidate.x), int(candidate.z)):
          let position = candidate.point()
          if within(position, buildingAim(target, position), TowerSiegeRange):
            hero.place(position)
            placed = true
  doAssert placed
  game.world.rebuildVision()
  var found = false
  for i in 0 ..< game.world.worldObjectCount(hero.id):
    var value: WorldObject
    if game.world.worldObjectAt(hero.id, i, value) and value.id == target.id:
      doAssert value.kind == 5 and value.alive
      found = true
  doAssert found
  doAssert game.world.applyAttackTarget(hero.id, target.id)
  let gold = hero.gold
  game.world.buildings[victim].hp = hero.heroAttackDamage
  for tick in 0 ..< 96:
    game.tickWorld(nil)
    if game.world.buildings[victim].hp <= 0:
      break
  doAssert game.world.buildings[victim].hp <= 0
  doAssert hero.gold == gold + 75
  doAssert hero.attackObjectId != target.id
  for i in 0 ..< game.world.worldObjectCount(hero.id):
    var value: WorldObject
    doAssert game.world.worldObjectAt(hero.id, i, value)
    doAssert value.id != target.id

echo "Testing unseen destruction does not leak through walkability"
block:
  let game = quietGame()
  let target = game.world.buildings[0]
  let observer = if target.team == RedTeam: BlueTeam else: RedTeam
  game.world.buildings[0].hp = 0
  game.world.syncBuildings()
  var checked = false
  for tile in target.footprint:
    if navigationOpen(int(tile.layer), int(tile.x), int(tile.z)):
      doAssert not game.world.knownWalkable(observer,
        int(tile.layer), int(tile.x), int(tile.z))
      checked = true
  doAssert checked
  var scout = Footman(id: 1000, hp: FootmanHp, team: observer)
  scout.place(target.position)
  game.world.footmen = @[scout]
  game.tickWorld(nil)
  for tile in target.footprint:
    doAssert game.world.knownWalkable(observer,
      int(tile.layer), int(tile.x), int(tile.z)) ==
      navigationOpen(int(tile.layer), int(tile.x), int(tile.z))

echo "Lane navigation and destructible building checks passed"
