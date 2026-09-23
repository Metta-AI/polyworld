import
  std/algorithm,
  fixxy,
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

type Observer = enum CreepObserver, HeroObserver, TowerObserver

proc arena(): Game =
  ## Creates an open lane with only explicitly enabled participants.
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

proc middle(): WorldPoint =
  ## Reads a cell center on the actual middle lane.
  let point = lanePathPoints[1][lanePathPoints[1].len div 2]
  const Unit = WorldScale div PathUnitsPerTile
  WorldPoint(x: point.x * Unit, y: point.y * Unit, z: point.z * Unit)

proc crossing(kind: Observer, reverse, outward: bool): int32 =
  ## Acquires from the starting positions while an enemy crosses the radius.
  let
    game = arena()
    origin = middle()
    bait = game.world.heroes[1]
    radius =
      case kind
      of CreepObserver: FootmanSightRadius
      of HeroObserver: heroAttackRange(Ranger)
      of TowerObserver: TowerAttackRanges[OuterTower]
    gap = if outward: -2000'i32 else: 2000'i32
    start = WorldPoint(x: origin.x + radius + gap,
      y: origin.y, z: origin.z)
  bait.hp = bait.maxHp
  bait.state = Marching
  bait.controls[StunControl].ends = 10_000
  bait.place(WorldPoint(
    x: origin.x + (if outward: radius + 4 * WorldScale else: 0),
    y: origin.y, z: origin.z))
  var enemy = Footman(id: 1001, team: BlueTeam, hp: FootmanHp, lane: 1,
    targetHeroId: bait.id)
  enemy.place(start)
  enemy.body.facing = if outward: FixedZero else: FixedPi
  enemy.facing = Heading(x: if outward: WorldScale else: -WorldScale)
  case kind
  of CreepObserver:
    var observer = Footman(id: 1000, team: RedTeam, hp: FootmanHp, lane: 1)
    observer.place(origin)
    game.world.footmen.add observer
  of HeroObserver:
    let hero = game.world.heroes[0]
    hero.class = Ranger
    hero.refreshHeroStats()
    hero.hp = hero.maxHp
    hero.state = Marching
    hero.place(origin)
  of TowerObserver:
    game.world.buildings = @[
      Building(id: 10, team: RedTeam, kind: TowerBuilding, tier: OuterTower,
        lane: 1, position: origin, hp: 1000, maxHp: 1000)
    ]
  game.world.footmen.add enemy
  if reverse:
    game.world.footmen.reverse()
  game.tickWorld(nil)
  let finish = game.world.footmanById(enemy.id).position
  if outward:
    doAssert finish.x > start.x, $kind
  else:
    doAssert finish.x < start.x, $kind
  case kind
  of CreepObserver: game.world.footmanById(1000).targetId
  of HeroObserver: game.world.heroes[0].attackObjectId
  of TowerObserver: game.world.buildings[0].targetId

echo "Testing acquisition uses one position snapshot for every unit type"
for kind in Observer:
  for outward in [false, true]:
    for reverse in [false, true]:
      let expected = if outward: 1001'i32 else: 0'i32
      doAssert crossing(kind, reverse, outward) == expected,
        $kind & ", outward=" & $outward & ", reversed=" & $reverse

echo "Testing respawns publish health and position together"
block:
  let
    game = arena()
    hero = game.world.heroes[5]
  hero.deathTicks = 0
  hero.deathTicks = hero.respawnTicks() - 1
  var observer = Footman(id: 1000, team: RedTeam, hp: FootmanHp, lane: 1)
  observer.place(WorldPoint(x: hero.spawnPosition.x + WorldScale,
    y: hero.spawnPosition.y, z: hero.spawnPosition.z))
  game.world.footmen.add observer
  game.tickWorld(nil)
  doAssert hero.hp == hero.maxHp and hero.state == Marching
  doAssert within(hero.position, hero.spawnPosition, 2),
    $hero.position & " != " & $hero.spawnPosition
  doAssert game.world.footmen[0].targetHeroId == 0
  game.tickWorld(nil)
  doAssert game.world.footmen[0].targetHeroId == hero.id

echo "Testing explicit immediate healing survives the unit commit"
for reverse in [false, true]:
  let
    game = arena()
    caster = game.world.heroes[0]
    point = middle()
  caster.class = VanguardKnight
  caster.refreshHeroStats()
  caster.place(point)
  caster.state = Marching
  caster.hp = caster.maxHp div 2
  caster.mana = caster.maxMana
  caster.abilityLevels[PassiveAbility] = 1
  caster.charges[PassiveAbility] = 1
  caster.spellsReady = true
  let hp = caster.hp
  if reverse:
    game.world.heroes.reverse()
    for i, hero in game.world.heroes:
      game.world.stats.teams[i] = hero.team.ord
  game.world.heroTurnTicks = 1
  game.tickWorld(proc() =
    ## Submits the healing command before unit planning and commit.
    doAssert game.world.applyCastTarget(
      caster.id, PassiveAbility.ord.int32, caster.id
    )
  )
  doAssert caster.hp > hp
  doAssert caster.hp <= caster.maxHp

echo "GotA movement phases passed"

proc crowded(order: array[3, int], reverseCreeps, fixed: bool):
    seq[FixedVec2] =
  ## Resolves the same mixed crowd under independent actor permutations.
  let
    game = arena()
    origin = middle()
  var heroes: array[3, Hero]
  for i in 0 ..< 3:
    heroes[i] = game.world.heroes[i]
    heroes[i].hp = heroes[i].maxHp
    heroes[i].state = Marching
    heroes[i].team = Team(i mod 2)
    heroes[i].place(WorldPoint(x: origin.x + i.int32 * 8000,
      y: origin.y, z: origin.z))
  if fixed:
    heroes[1].controls[RootControl].ends = 1000
  let fixedPosition = heroes[1].body.pos
  for i in 0 ..< 3:
    game.world.heroes[i] = heroes[order[i]]
  for i, hero in game.world.heroes:
    game.world.stats.teams[i] = hero.team.ord
  for i in 0 ..< 8:
    var creep = Footman(id: 1000 + i.int32, team: Team(i mod 2),
      hp: FootmanHp, lane: 1, swingTicks: -1)
    creep.place(WorldPoint(x: origin.x + (i mod 3).int32 * 6000 + 4000,
      y: origin.y, z: origin.z + (i div 3).int32 * 6000 + 5000))
    creep.body.radius = 0.22'fx
    game.world.footmen.add creep
  if reverseCreeps:
    game.world.footmen.reverse()
  game.tickWorld(nil)
  if fixed:
    doAssert heroes[1].body.pos == fixedPosition
  for hero in heroes:
    result.add hero.body.pos
  for id in 1000'i32 .. 1007'i32:
    result.add game.world.footmanById(id).body.pos

echo "Testing collision corrections commute under actor permutations"
for fixed in [false, true]:
  let expected = crowded([0, 1, 2], false, fixed)
  for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2],
    [1, 2, 0], [2, 0, 1], [2, 1, 0]]:
      for reverse in [false, true]:
        doAssert crowded(order, reverse, fixed) == expected
