import
  polyworld/[metrics, pathing],
  ../examples/gods_of_the_arena/[content, sim]

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
    buildings: @[
      Building(id: 10, team: BlueTeam, tier: OuterTower, hp: 600),
      Building(id: 11, team: BlueTeam, tier: InnerTower, hp: 800)
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
    world.buildings.add Building(
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
  world.buildings[0].hp = 0
  hero.attackObjectId = 11
  doAssert world.applyUseItem(hero.id, 0)
  doAssert world.buildings[1].hp == 800 - PoisonPotion.itemSpec.strike
  world.buildings[1].hp = 0
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

echo "Testing Vanguard attack cadence"
block:
  let
    world = itemWorld()
    hero = world.heroes[1]
  doAssert world.heroAttackTicks(hero) == 24

echo "test_gota_abilities: all checks passed"
