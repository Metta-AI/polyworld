import
  std/strutils,
  ../examples/gods_of_the_arena/[content, controls, maps, replays, sim]

proc castGame(class = Ranger): Game =
  var preset = defaultConfig()
  preset.mapSize = 128
  result = newGame(generateMap(2026, preset), 240, 10, false, ReplayData(),
    drafting = false)
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.manualSpells = true
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for building in result.world.buildings.mitems:
    building.hp = 0
  result.world.syncBuildings()
  let hero = result.world.heroes[0]
  hero.class = class
  hero.refreshHeroStats()
  hero.abilityLevels[PrimaryAbility] = 1
  hero.charges[PrimaryAbility] =
    heroAbility(class, PrimaryAbility).abilitySpec.charges
  hero.hp = hero.maxHp
  hero.maxMana = 10_000
  hero.mana = 9_000
  hero.state = Marching

echo "Testing cooldown and charge reasons prefer Ready in over Next charge"
block:
  let
    game = castGame(VanguardKnight)
    hero = game.world.heroes[0]
  hero.charges[PrimaryAbility] = 0
  hero.recharges[PrimaryAbility] = 48
  hero.cooldowns[PrimaryAbility] = 24
  doAssert game.world.abilityReadyReason(hero, PrimaryAbility).contains("Ready in")
  hero.cooldowns[PrimaryAbility] = 0
  doAssert game.world.abilityReadyReason(hero, PrimaryAbility).contains("charge")
  hero.charges[PrimaryAbility] = 1
  hero.mana = 0
  doAssert game.world.abilityReadyReason(hero, PrimaryAbility).contains("mana")
  hero.state = Dying
  doAssert game.world.abilityReadyReason(hero, PrimaryAbility).contains("Respawn")

echo "Testing a rejected key reports the reason and does not queue a cast"
block:
  let
    game = castGame()
    hero = game.world.heroes[0]
  hero.mana = 0
  doAssert not activatePlayerAbility(
    game.world, hero.id, int32(PrimaryAbility), 0,
    mapCoordinate(hero.position.x), mapCoordinate(hero.position.z) + 3
  )
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 0
  doAssert feedbackError and feedbackText.contains("mana")

echo "Testing normal cast arms instead of firing"
block:
  let
    game = castGame()
    hero = game.world.heroes[0]
  doAssert not activatePlayerAbility(
    game.world, hero.id, int32(PrimaryAbility), 0,
    mapCoordinate(hero.position.x), mapCoordinate(hero.position.z) + 3,
    NormalCast
  )
  flushPlayerCommands(game)
  doAssert armedAbility == int32(PrimaryAbility)
  doAssert game.world.casts.len == 0
  cancelPlayerAim()
  doAssert armedAbility == -1

echo "GotA cast feedback tests passed"
