import
  polyworld/[metrics, pathing],
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

proc itemWorld(): World =
  ## Creates visible targets without running navigation or bot decisions.
  result = World(
    stats: newCombatStats(3),
    heroes: @[
      Hero(id: 100, team: RedTeam, class: Ranger, level: 1, gold: 500),
      Hero(id: 105, team: BlueTeam, class: VanguardKnight, level: 1),
      Hero(id: 101, team: RedTeam, class: DeathKnight, level: 1)
    ],
    footmen: @[
      Footman(id: 1000, team: BlueTeam, hp: 60)
    ],
    towers: @[
      Tower(id: 10, team: BlueTeam, tier: OuterTower, hp: 600),
      Tower(id: 11, team: BlueTeam, tier: InnerTower, hp: 800)
    ],
    forts: [
      Fort(id: 1, team: RedTeam, hp: FortHp),
      Fort(id: 2, team: BlueTeam, hp: FortHp)
    ]
  )
  for i, hero in result.heroes:
    hero.refreshHeroStats()
    result.stats.teams[i] = hero.team.ord
  for team in Team:
    result.teamVisible[team.ord] = newSeq[uint8](GridTiles * GridTiles)
    for cell in result.teamVisible[team.ord].mitems:
      cell = 255
  result.heroes[0].inventory[0] = PoisonPotion
  result.heroes[0].itemCounts[0] = 3

proc combatGame(class: HeroClass): Game =
  ## Isolates one attacker and a nearby enemy from bots, creeps and towers.
  result = newGame(generateMap(2026), 240, 10, false, ReplayData())
  let world = result.world
  world.legacyAbilities = true
  world.spawnTimerTicks = 1000
  world.heroTurnTicks = 1000
  for hero in world.heroes:
    hero.state = Dying
    hero.hp = 0
  for tower in world.towers.mitems:
    tower.attackTicks = 1000
  let
    attacker = world.heroes[0]
    target = world.heroes[5]
  attacker.class = class
  attacker.refreshHeroStats()
  attacker.state = Marching
  attacker.hp = attacker.maxHp
  attacker.mana = attacker.maxMana
  attacker.attackObjectId = target.id
  target.state = Marching
  target.hp = 100_000
  target.maxHp = 100_000
  var position = attacker.position
  position.x += 30_000
  target.place(position)
  for hero in [attacker, target]:
    for slot in HeroAbilitySlot:
      hero.cooldowns[slot] = 1000

echo "Testing poison range boundaries for every hero class"
for class in HeroClass:
  let
    world = itemWorld()
    hero = world.heroes[0]
    target = world.heroes[1]
    range = heroAttackRange(class)
  hero.class = class
  hero.attackObjectId = target.id
  target.position.x = range + 1
  let hp = target.hp
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert target.hp == hp and hero.itemCounts[0] == 3
  target.position.x = range
  doAssert world.applyUseItem(hero.id, 0)
  doAssert target.hp == hp - PoisonPotion.itemSpec.strike
  doAssert hero.itemCounts[0] == 2

echo "Testing poison rejects hidden, dead and friendly targets"
block:
  let
    world = itemWorld()
    hero = world.heroes[0]
    target = world.heroes[1]
  hero.attackObjectId = target.id
  for cell in world.teamVisible[RedTeam.ord].mitems:
    cell = 0
  doAssert not world.applyUseItem(hero.id, 0)
  for cell in world.teamVisible[RedTeam.ord].mitems:
    cell = 255
  target.hp = 0
  doAssert not world.applyUseItem(hero.id, 0)
  target.hp = 100
  target.state = Dying
  doAssert not world.applyUseItem(hero.id, 0)
  hero.attackObjectId = world.heroes[2].id
  doAssert not world.applyUseItem(hero.id, 0)
  hero.attackObjectId = 999_999
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert hero.itemCounts[0] == 3

echo "Testing poison respects tower order and God protection"
block:
  let
    world = itemWorld()
    hero = world.heroes[0]
  for lane in 1 .. 2:
    world.towers.add Tower(
      id: int32(20 + lane),
      team: BlueTeam,
      lane: lane,
      tier: OuterTower,
      hp: 600
    )
  hero.attackObjectId = 11
  doAssert not world.applyUseItem(hero.id, 0)
  hero.attackObjectId = 2
  doAssert not world.applyUseItem(hero.id, 0)
  world.towers[0].hp = 0
  hero.attackObjectId = 11
  doAssert world.applyUseItem(hero.id, 0)
  doAssert world.towers[1].hp == 800 - PoisonPotion.itemSpec.strike
  world.towers[1].hp = 0
  hero.attackObjectId = 2
  world.forts[1].center.x = heroAttackRange(hero.class) + 1
  doAssert not world.applyUseItem(hero.id, 0)
  world.forts[1].center.x -= 1
  doAssert world.applyUseItem(hero.id, 0)
  doAssert world.forts[1].hp == FortHp - PoisonPotion.itemSpec.strike

echo "Testing poison pays a creep bounty only once"
block:
  let
    world = itemWorld()
    hero = world.heroes[0]
    gold = hero.gold
  hero.attackObjectId = 1000
  world.footmen[0].hp = 1
  doAssert world.applyUseItem(hero.id, 0)
  doAssert hero.gold == gold + 15
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert hero.gold == gold + 15 and hero.itemCounts[0] == 2

echo "Testing zero-HP heroes cannot resurrect with consumables or equipment"
for hp in [0'i32, -10'i32]:
  let
    world = itemWorld()
    hero = world.heroes[0]
    gold = hero.gold
  hero.hp = hp
  hero.inventory[0] = VitalityElixir
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert not world.applyBuyItem(hero.id, int32(KnightArmor.ord))
  doAssert hero.hp == hp and hero.itemCounts[0] == 3
  doAssert hero.gold == gold and hero.inventory[1] == NoItem

echo "Testing a lethal passive does not spend another spell on the corpse"
block:
  let
    game = combatGame(Crossbowman)
    hero = game.world.heroes[0]
    target = game.world.heroes[5]
  target.hp = FinalMeasure.legacyAbilitySpec.damage
  for slot in HeroAbilitySlot:
    hero.cooldowns[slot] = 0
  game.tickWorld(nil)
  doAssert target.hp == 0
  doAssert hero.mana == hero.maxMana
  doAssert hero.cooldowns[PassiveAbility] > 0
  for slot in [PrimaryAbility, SecondaryAbility, UltimateAbility]:
    doAssert hero.cooldowns[slot] == 0
  doAssert hero.attackObjectId == 0 and hero.targetHeroId == 0
  doAssert game.world.stats.values[0][KillsMetric] == 1

echo "Testing all forty historical ability effects, mana and cooldowns"
for class in HeroClass:
  for slot in HeroAbilitySlot:
    let
      game = combatGame(class)
      hero = game.world.heroes[0]
      target = game.world.heroes[5]
      spec = heroAbility(class, slot).legacyAbilitySpec
    hero.cooldowns[slot] = 0
    if spec.kind == Heal:
      hero.hp -= spec.heal
    if spec.kind == Restore:
      hero.mana = 0
    let
      hp = hero.hp
      mana = hero.mana
      targetHp = target.hp
    game.tickWorld(nil)
    doAssert hero.cooldowns[slot] == spec.cooldownTicks, $class & " " & $slot
    case spec.kind
    of Strike:
      doAssert target.hp == targetHp - spec.damage
      doAssert hero.mana == mana - spec.manaCost
    of Heal:
      doAssert hero.hp == hp + spec.heal
      doAssert hero.mana == mana - spec.manaCost
    of Restore:
      doAssert hero.mana == mana + spec.restore

echo "Testing failed spells do not spend mana or cooldown"
block:
  let
    game = combatGame(Arcanist)
    hero = game.world.heroes[0]
    target = game.world.heroes[5]
    spec = FrostLance.legacyAbilitySpec
    targetHp = target.hp
  hero.cooldowns[PrimaryAbility] = 0
  hero.mana = spec.manaCost - 1
  game.tickWorld(nil)
  doAssert hero.mana == spec.manaCost - 1
  doAssert hero.cooldowns[PrimaryAbility] == 0
  doAssert target.hp == targetHp
block:
  let
    game = combatGame(Ranger)
    hero = game.world.heroes[0]
    target = game.world.heroes[5]
    spec = StormEagle.legacyAbilitySpec
    mana = hero.mana
    targetHp = target.hp
  hero.cooldowns[UltimateAbility] = 0
  var position = hero.position
  position.x += spec.range + 1
  target.place(position)
  game.tickWorld(nil)
  doAssert hero.mana == mana
  doAssert hero.cooldowns[UltimateAbility] == 0
  doAssert target.hp == targetHp

echo "Testing live and historical Vanguard attack cadence"
block:
  let
    world = itemWorld()
    hero = world.heroes[1]
  doAssert world.heroAttackTicks(hero) == 24
  world.legacyCombat = true
  doAssert world.heroAttackTicks(hero) == 26

echo "Testing old replay rules preserve the historical poison behavior"
block:
  let
    world = itemWorld()
    hero = world.heroes[0]
  world.legacyCombat = true
  hero.attackObjectId = 2
  world.forts[1].center.x = 6_000_000
  doAssert world.applyUseItem(hero.id, 0)
  doAssert world.forts[1].hp == FortHp - PoisonPotion.itemSpec.strike

echo "test_gota_abilities: all checks passed"
