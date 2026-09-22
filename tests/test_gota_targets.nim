import
  std/algorithm,
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

proc arena(): Game =
  ## Creates a quiet middle lane with no active buildings or opposing scripts.
  result = newGame(generateMap(7), 100_000, 10, false,
    ReplayData(), drafting = false)
  result.world.spawnTimerTicks = 100_000
  for building in result.world.buildings.mitems:
    building.hp = 0
  result.world.syncBuildings()
  for hero in result.world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
    hero.manualSpells = true

proc middle(): WorldPoint =
  ## Returns a valid cell center from the actual middle lane.
  let point = lanePathPoints[1][lanePathPoints[1].len div 2]
  const Unit = WorldScale div PathUnitsPerTile
  WorldPoint(x: point.x * Unit, y: point.y * Unit, z: point.z * Unit)

proc target(reverse: bool, creep: bool): int32 =
  ## Reads the actual autonomous acquisition with either enemy storage order.
  let
    game = arena()
    origin = middle()
    hero = game.world.heroes[0]
  hero.place(origin)
  hero.hp = hero.maxHp
  hero.state = Marching
  for i in 0 ..< 2:
    var enemy = Footman(id: 1001 + i.int32, team: BlueTeam, hp: FootmanHp,
      state: Fighting, swingTicks: 0, targetHeroId: hero.id)
    var position = origin
    if i == 0:
      position.x += WorldScale div 2
    else:
      position.z += WorldScale div 2
    enemy.place(position)
    game.world.footmen.add enemy
  if reverse:
    game.world.footmen.reverse()
  if creep:
    hero.hp = 0
    hero.state = Dying
    var observer = Footman(id: 1000, team: RedTeam, hp: FootmanHp)
    observer.place(origin)
    game.world.footmen.add observer
  game.tickWorld(nil)
  if creep:
    game.world.footmanById(1000).targetId
  else:
    hero.attackObjectId

echo "Testing autonomous target ties ignore enemy storage order"
for creep in [false, true]:
  let
    first = target(false, creep)
    second = target(true, creep)
  doAssert first != 0
  doAssert first == second,
    "creep=" & $creep & ", targets=" & $first & "," & $second

proc healed(reverse: bool): int32 =
  ## Reads the automatic healing target with either ally storage order.
  let
    game = arena()
    hero = game.world.heroes[0]
    origin = middle()
  hero.class = DruidWarden
  hero.refreshHeroStats()
  hero.place(origin)
  hero.hp = hero.maxHp
  hero.mana = hero.maxMana
  hero.state = Marching
  hero.manualSpells = false
  hero.abilityLevels[PrimaryAbility] = 1
  hero.charges[PrimaryAbility] = 1
  hero.spellsReady = true
  for i in 1 .. 2:
    let ally = game.world.heroes[i]
    ally.state = Marching
    ally.hp = ally.maxHp div 2
    var point = origin
    if i == 1:
      point.x += WorldScale
    else:
      point.z += WorldScale
    ally.place(point)
  if reverse:
    swap(game.world.heroes[1], game.world.heroes[2])
  game.tickWorld(nil)
  doAssert game.world.casts.len == 1
  doAssert game.world.casts[0].ability == HealingBloom
  game.world.casts[0].targetId

echo "Testing automatic healing ignores ally storage order"
doAssert healed(false) == healed(true)

proc shot(reverse: bool): int32 =
  ## Sweeps a real ground projectile across two equally distant opponents.
  let
    game = arena()
    caster = game.world.heroes[0]
    origin = middle()
    spec = FrostLance.abilitySpec(1)
  caster.place(origin)
  caster.hp = caster.maxHp
  caster.state = Marching
  caster.stunnedUntil = 1000
  for i in 5 .. 6:
    let enemy = game.world.heroes[i]
    enemy.place(WorldPoint(x: origin.x + 3000, y: origin.y,
      z: origin.z + (if i == 5: 6000'i32 else: -6000'i32)))
    enemy.hp = enemy.maxHp
    enemy.state = Marching
    enemy.stunnedUntil = 1000
  if reverse:
    swap(game.world.heroes[5], game.world.heroes[6])
  game.world.casts.add SpellCast(ability: FrostLance, level: 1,
    heroId: caster.id, origin: origin,
    position: WorldPoint(x: origin.x + WorldScale, y: origin.y, z: origin.z),
    direction: Heading(x: WorldScale), started: -spec.castTicks,
    impact: 10, ends: 22)
  game.tickWorld(nil)
  var hits = 0
  for enemy in game.world.heroes:
    if enemy.team == BlueTeam and enemy.hp > 0 and enemy.hp < enemy.maxHp:
      result = enemy.id
      inc hits
  doAssert hits == 1

echo "Testing projectile ties ignore enemy storage order"
doAssert shot(false) == shot(true)

echo "Testing siege aim ignores footprint storage order"
block:
  let game = newGame(generateMap(7), 480, 10, false,
    ReplayData(), drafting = false)
  for building in game.world.buildings:
    var reversed = building
    reversed.footprint.reverse()
    var partner: Building
    for other in game.world.buildings:
      if other.position.x == -building.position.x and
        other.position.z == -building.position.z:
          partner = other
    doAssert partner.id != 0 and partner.team != building.team
    for x in -6 .. 6:
      for z in -6 .. 6:
        let point = WorldPoint(
          x: building.position.x + x.int32 * (WorldScale div 2),
          y: building.position.y,
          z: building.position.z + z.int32 * (WorldScale div 2)
        )
        doAssert building.buildingAim(point) == reversed.buildingAim(point),
          "building=" & $building.id & ", point=" & $point
        let
          aim = building.buildingAim(point)
          opposite = partner.buildingAim(WorldPoint(
            x: -point.x, y: point.y, z: -point.z))
        doAssert aim == WorldPoint(x: -opposite.x, y: opposite.y,
          z: -opposite.z), "building=" & $building.id & ", point=" & $point
