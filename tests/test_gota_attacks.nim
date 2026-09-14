import
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, controls, maps, replays, sim]

proc attackGame(class: HeroClass): Game =
  ## Isolates basic attacks in the arena with manual spell control.
  result = newGame(generateMap(2026), 240, 10, false, ReplayData())
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.manualSpells = true
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for tower in result.world.towers.mitems:
    tower.hp = 0
  let hero = result.world.heroes[0]
  hero.class = class
  hero.refreshHeroStats()
  hero.hp = hero.maxHp
  hero.state = Marching
  let tile = layers[GroundLayer].tiles[18 * GridTiles + 56]
  var point = WorldPoint(
    x: (56 - GridTiles div 2) * WorldScale + WorldScale div 2,
    z: (18 - GridTiles div 2) * WorldScale + WorldScale div 2
  )
  for height in tile.tops:
    point.y += height.int32 * WorldScale div 32
  hero.place(point)

proc enemyHero(game: Game, offset: int32): Hero =
  ## Places a passive enemy hero east of the attacker.
  result = game.world.heroes[5]
  result.state = Marching
  result.hp = 100_000
  result.maxHp = 100_000
  var point = game.world.heroes[0].position
  point.x += offset
  result.place(point)

proc addCreep(game: Game, id: int32, offset: int32, team = BlueTeam) =
  ## Adds a living creep at a measured offset from the attacking hero.
  var
    creep = Footman(id: id, team: team, hp: 10_000)
    point = game.world.heroes[0].position
  point.z += offset
  creep.place(point)
  game.world.footmen.add creep

echo "Testing all ten heroes acquire the nearest creep before other enemies"
for class in HeroClass:
  let
    game = attackGame(class)
    hero = game.world.heroes[0]
    other = game.enemyHero(40_000)
  game.addCreep(1000, 60_000)
  game.addCreep(1001, 110_000)
  game.addCreep(1002, 20_000, RedTeam)
  game.tickWorld(nil)
  doAssert hero.attackObjectId == 1000, $class
  doAssert hero.targetFootmanId == 1000
  doAssert hero.targetHeroId == 0 and other.hp == 100_000

echo "Testing selected targets override creeps and all classes chase into range"
for class in HeroClass:
  let
    game = attackGame(class)
    hero = game.world.heroes[0]
    range = heroAttackRange(class)
    other = game.enemyHero(range + 2 * WorldScale)
    start = hero.position
    hp = other.hp
  game.addCreep(1000, 80_000)
  queueAttackTarget(hero.id, other.id)
  flushPlayerCommands(game)
  for tick in 0 ..< 100:
    game.tickWorld(nil)
    doAssert hero.attackObjectId == other.id, $class
    if other.hp < hp:
      break
    if not within(hero.position, other.position, range):
      doAssert other.hp == hp
  doAssert hero.position.x > start.x, $class & " did not chase"
  doAssert other.hp == hp - hero.heroAttackDamage, $class
  doAssert within(hero.position, other.position, range + 100), $class
  let inRange = hero.position
  game.tickWorld(nil)
  doAssert within(hero.position, inRange, 10),
    $class & " kept walking after reaching attack range"

echo "Testing basic attack damage scales independently of all four spells"
for class in HeroClass:
  for level in [1, 10, 20]:
    let
      game = attackGame(class)
      hero = game.world.heroes[0]
      other = game.enemyHero(60_000)
    hero.level = level
    hero.refreshHeroStats()
    hero.mana = 0
    hero.maxMana = 0
    for slot in HeroAbilitySlot:
      hero.charges[slot] = 0
      hero.recharges[slot] = 10_000
      hero.cooldowns[slot] = 10_000
    doAssert class.heroAttackCasting in {MeleeCast, ProjectileCast}
    doAssert hero.class.heroSpec.abilities.len == 4
    doAssert game.world.applyAttackTarget(hero.id, other.id)
    let damage = class.heroSpec.baseDamage +
      int32(level - 1) * class.heroSpec.damagePerLevel
    for tick in 0 ..< int(heroAttackTicks(class)):
      game.tickWorld(nil)
      if other.hp < 100_000:
        break
    doAssert other.hp == 100_000 - damage, $class & " level " & $level
    doAssert hero.mana == 0 and game.world.casts.len == 0
    for slot in HeroAbilitySlot:
      doAssert hero.charges[slot] == 0

echo "Testing a lost chase target returns the hero to nearby creeps"
block:
  let
    game = attackGame(Ranger)
    hero = game.world.heroes[0]
    other = game.enemyHero(8 * WorldScale)
  doAssert game.world.applyAttackTarget(hero.id, other.id)
  game.tickWorld(nil)
  doAssert hero.hasMoveTarget
  other.hp = 0
  game.addCreep(1000, 100_000)
  game.tickWorld(nil)
  doAssert hero.attackObjectId == 1000
  doAssert not hero.hasMoveTarget

echo "Testing ordinary walking suppresses automatic target acquisition"
block:
  let
    game = attackGame(Ranger)
    hero = game.world.heroes[0]
  game.addCreep(1000, 100_000)
  queueWalkTo(
    hero.id, mapCoordinate(hero.position.x) + 3,
    mapCoordinate(hero.position.z)
  )
  flushPlayerCommands(game)
  game.tickWorld(nil)
  doAssert hero.hasMoveTarget and hero.attackObjectId == 0

echo "Testing an extra ability can end a chase without leaving a stale path"
block:
  let
    game = attackGame(VanguardKnight)
    hero = game.world.heroes[0]
    other = game.enemyHero(90_000)
  doAssert game.world.applyAttackTarget(hero.id, other.id)
  game.tickWorld(nil)
  doAssert hero.hasMoveTarget
  other.hp = 1
  hero.manualSpells = false
  for slot in HeroAbilitySlot:
    hero.charges[slot] = 0
  hero.charges[PrimaryAbility] = 1
  game.tickWorld(nil)
  doAssert other.hp <= 0
  doAssert hero.attackObjectId == 0 and not hero.hasMoveTarget
  doAssert hero.movePath.len == 0
  game.addCreep(1000, 100_000)
  game.tickWorld(nil)
  doAssert hero.attackObjectId == 1000

echo "Testing idle heroes leave enemy heroes alone without a selected target"
for class in [VanguardKnight, Ranger, Arcanist]:
  let game = attackGame(class)
  discard game.enemyHero(60_000)
  game.tickWorld(nil)
  doAssert game.world.heroes[0].attackObjectId == 0

echo "Testing old arena replays retain historical target acquisition"
for class in [VanguardKnight, Ranger]:
  let
    game = attackGame(class)
    hero = game.world.heroes[0]
    other = game.enemyHero(60_000)
  game.world.legacyAttacks = true
  game.tickWorld(nil)
  doAssert hero.attackObjectId ==
    (if class == VanguardKnight: other.id else: 0)

echo "Testing replay versions select the recorded basic attack rules"
block:
  let game = attackGame(Ranger)
  for version in [ArenaGameVersion, ReplayGameVersion]:
    let recorder = initReplayRecorder(game.currentSetup(20))
    recorder.data.header.gameVersion = version
    let replay = newGame(game.map, 240, 10, true, recorder.data)
    doAssert replay.world.legacyAttacks == (version == ArenaGameVersion)
    doAssert not replay.world.legacyAbilities

echo "GOTA basic attack tests passed"
