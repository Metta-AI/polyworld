import
  std/[os, strformat],
  fixxy,
  polyworld/[bodies, cli, pathing],
  ../examples/gods_of_the_arena/[bots, maps, replays, sim]

const Policy = currentSourcePath().parentDir.parentDir /
  "examples/gods_of_the_arena/players/base.bas"

proc opposite(layer: int32): int32 =
  ## Rotates a navigation layer.
  case layer
  of RedFortLayer: BlueFortLayer
  of BlueFortLayer: RedFortLayer
  else: layer

proc rotated(point: WorldPoint): WorldPoint =
  ## Rotates an exact world position.
  WorldPoint(x: -point.x, y: point.y, z: -point.z)

proc rotated(heading: Heading): Heading =
  ## Rotates an exact integer direction.
  Heading(x: -heading.x, z: -heading.z)

proc rotated(body: Body): Body =
  ## Rotates a body without changing its collision radius.
  result = body
  result.pos = -body.pos
  result.facing = wrapAngle(body.facing + FixedPi)

proc rotated(tile: PathTile): PathTile =
  ## Rotates a packed tile on the opposite navigation layer.
  PathTile(layer: tile.layer.opposite,
    x: mapTiles().int32 - 1 - tile.x,
    z: mapTiles().int32 - 1 - tile.z)

proc rotate(hero: Hero) =
  ## Reflects all spatial state while preserving the actor's identity.
  hero.team = Team(1 - hero.team.ord)
  hero.lane = 2 - hero.lane
  hero.position = hero.position.rotated
  hero.spawnPosition = hero.spawnPosition.rotated
  hero.facing = hero.facing.rotated
  hero.velocity = hero.velocity.rotated
  hero.body = hero.body.rotated
  hero.navLayer = hero.navLayer.opposite
  hero.portalDestination = hero.portalDestination.rotated
  for point in hero.movePath.mitems:
    point = point.rotated
  for layer in hero.movePathLayers.mitems:
    layer = layer.opposite
  if hero.hasMoveTarget or hero.movePath.len > 0 or
    hero.moveTileX != 0 or hero.moveTileY != 0 or hero.moveRevision != 0:
      let (x, y, offset) = splitTilePoint(fixedVec2(
        fixed(mapTiles().int32 - 1 - hero.moveTileX.int32) - hero.moveOffset.x,
        fixed(mapTiles().int32 - 1 - hero.moveTileY.int32) - hero.moveOffset.y
      ))
      hero.moveTileX = x
      hero.moveTileY = y
      hero.moveOffset = offset

proc rotated(creep: Footman): Footman =
  ## Reflects every spatial component of one creep's state.
  result = creep
  result.team = Team(1 - creep.team.ord)
  if creep.camp == 0:
    result.lane = 2 - creep.lane
  result.home = creep.home.rotated
  result.position = creep.position.rotated
  result.facing = creep.facing.rotated
  result.velocity = creep.velocity.rotated
  result.body = creep.body.rotated
  result.navLayer = creep.navLayer.opposite
  result.moveGoal = creep.moveGoal.rotated
  for tile in result.movePath.mitems:
    tile = tile.rotated

proc rotate(world: World) =
  ## Rotates the initial world while retaining storage order and random draws.
  for camp in world.camps.mitems:
    camp.center = camp.center.rotated
  for hero in world.heroes:
    hero.rotate()
  for fort in world.forts.mitems:
    fort.center = fort.center.rotated
    fort.team = Team(1 - fort.team.ord)
  swap(world.forts[0], world.forts[1])
  for building in world.buildings.mitems:
    building.position = building.position.rotated
    building.spawn = building.spawn.rotated
    building.facing = building.facing.rotated
    building.team = Team(1 - building.team.ord)
    if building.lane >= 0:
      building.lane = 2 - building.lane
    swap(building.knownAlive[RedTeam], building.knownAlive[BlueTeam])
    for tile in building.footprint.mitems:
      tile = tile.rotated
  for team in 0 .. 1:
    world.heroSpawns[team] = world.heroSpawns[team].rotated
  swap(world.heroSpawns[0], world.heroSpawns[1])
  for team in world.stats.teams.mitems:
    team = 1 - team

proc check(first, second: Game) =
  ## Reports the first field that violates equivariance after a whole tick.
  let
    a = first.world
    b = second.world
    label = &"tick={a.tick}"
  doAssert a.rng == b.rng, label & " RNG"
  doAssert a.tick == b.tick and a.nextFootmanId == b.nextFootmanId, label
  doAssert a.navigationRevision == b.navigationRevision, label & " navigation"
  doAssert a.spawnTimerTicks == b.spawnTimerTicks, label & " wave timing"
  doAssert a.heroTurnTicks == b.heroTurnTicks and
    a.heroTurnStart == b.heroTurnStart, label & " bot schedule"
  doAssert a.footmen.len == b.footmen.len, label & " creeps"
  doAssert a.camps.len == b.camps.len
  for i, camp in a.camps:
    var other = b.camps[i]
    other.center = other.center.rotated
    doAssert camp == other, label & " camp " & $i
  for i, hero in a.heroes:
    doAssert first.heroVms[i].lastInstructions ==
      second.heroVms[i].lastInstructions, label & " VM instructions " & $i
    doAssert first.heroVms[i].lastWork == second.heroVms[i].lastWork,
      label & " VM work " & $i
    let other = Hero()
    other[] = b.heroes[i][]
    other.rotate()
    for name, left, right in fieldPairs(hero[], other[]):
      doAssert left == right,
        label & " hero=" & $hero.id & " field=" & name &
          ": " & $left & " != " & $right
  for i, creep in a.footmen:
    let other = b.footmen[i].rotated
    for name, left, right in fieldPairs(creep, other):
      doAssert left == right,
        label & " creep=" & $creep.id & " field=" & name &
          ": " & $left & " != " & $right
  for i, building in a.buildings:
    doAssert building.hp == b.buildings[i].hp, label & " building health"
    doAssert building.targetId == b.buildings[i].targetId, label & " target"
    doAssert building.attackTicks == b.buildings[i].attackTicks,
      label & " tower cooldown"
    for team in Team:
      doAssert building.knownAlive[team] ==
        b.buildings[i].knownAlive[Team(1 - team.ord)], label & " fog memory"
  for i in 0 .. 1:
    doAssert a.forts[i].hp == b.forts[1 - i].hp, label & " fort health"
    doAssert a.teamHeroKills[i] == b.teamHeroKills[1 - i], label & " kills"
    doAssert a.teamHeroDeaths[i] == b.teamHeroDeaths[1 - i], label & " deaths"
    for j, cell in a.teamVisible[i]:
      doAssert cell == b.teamVisible[1 - i][a.teamVisible[i].high - j],
        label & &" vision team={i}, tile={j}"
      doAssert a.teamExplored[i][j] ==
        b.teamExplored[1 - i][a.teamExplored[i].high - j], label & " explored"
  doAssert a.casts.len == b.casts.len, label & " casts"
  for i, spell in a.casts:
    var other = b.casts[i]
    other.origin = other.origin.rotated
    other.position = other.position.rotated
    other.direction = other.direction.rotated
    doAssert spell == other, label & " spell " & $i
  doAssert a.stats.values == b.stats.values, label & " stats"
  doAssert a.gameOver == b.gameOver, label & " result"
  if a.gameOver:
    doAssert a.draw == b.draw, label & " draw"
    if not a.draw:
      doAssert a.winner != b.winner, label & " winner"

proc checkRotation(seed, mapSeed: int32, size, ticks: int) =
  ## Runs real policies on paired worlds and compares every authoritative tick.
  var preset = defaultConfig()
  preset.seed = mapSeed
  preset.mapSize = size
  let
    first = newGame(generateMap(seed, preset), 480, 10, false,
      ReplayData(), drafting = false)
    second = newGame(generateMap(seed, preset), 480, 10, false,
      ReplayData(), drafting = false)
  second.world.rotate()
  first.loadBots([BotGroup(path: Policy, count: 10)])
  second.loadBots([BotGroup(path: Policy, count: 10)])
  for tick in 1 .. ticks:
    first.tickWorld(proc() =
      ## Runs the original policies.
      first.runBotDecisions())
    second.tickWorld(proc() =
      ## Runs the rotated policies with the same actor identities.
      second.runBotDecisions())
    check(first, second)
    for game in [first, second]:
      for vm in game.heroVms:
        doAssert not vm.failed, vm.lastError
    if first.world.gameOver:
      break
  echo "Mirrored ticks: ", first.world.tick, ", seed: ", seed,
    ", map seed: ", mapSeed, ", size: ", size

echo "Testing complete simulation rotation with actual BASIC policies"
when defined(gotaLongSymmetry):
  for (seed, mapSeed, size) in [(7, 54, 116), (0, 54, 116), (8, 55, 116),
    (42, 0, 116), (7, 54, 64), (7, 54, 128), (7, 54, 256)]:
      checkRotation(seed.int32, mapSeed.int32, size, 28_800)
else:
  checkRotation(7, 54, 116, 1000)
