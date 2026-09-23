import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, tapes],
  ../examples/gods_of_the_arena/[bots, content, controls, maps, replays, sim]

const BasePolicy = currentSourcePath().parentDir.parentDir /
  "examples/gods_of_the_arena/players/base.bas"

proc buybackGame(): Game =
  ## Creates a quiet arena for exact death and buyback timing checks.
  result = newGame(
    generateMap(54),
    240,
    10,
    false,
    ReplayData(),
    drafting = false
  )
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for building in result.world.buildings.mitems:
    building.hp = 0
  let hero = result.world.heroes[0]
  hero.state = Marching
  hero.hp = hero.maxHp
  hero.deathTicks = 0

echo "Testing capped death timers and per-hero buyback prices"
block:
  let
    game = buybackGame()
    world = game.world
    hero = world.heroes[0]
  doAssert hero.deaths == 0
  doAssert hero.respawnTicks() == 0
  doAssert world.buybackPrice(hero.id) == 0
  doAssert world.buybackPrice(-1) == 0
  for (death, seconds) in [
    (1'i32, 9'i32), (2, 14), (3, 19), (11, 59), (12, 60), (20, 60)
  ]:
    hero.deaths = death - 1
    hero.hp = 0
    game.tickWorld(nil)
    let duration = seconds * TickRate
    doAssert hero.state == Dying and hero.deaths == death
    doAssert hero.respawnTicks() == duration
    doAssert world.buybackPrice(hero.id) == 100 * death
    for tick in 1 ..< duration:
      game.tickWorld(nil)
      doAssert hero.state == Dying and hero.deaths == death
      doAssert hero.respawnTicks() == duration - tick
      doAssert world.buybackPrice(hero.id) == 100 * death
    game.tickWorld(nil)
    doAssert hero.state == Marching and hero.hp == hero.maxHp
    doAssert hero.deaths == death and hero.deathTicks == 0
    doAssert hero.respawnTicks() == 0
    doAssert world.buybackPrice(hero.id) == 0
  doAssert world.heroes[1].deaths == 0
  let
    snapshot = world.clone()
    hash = game.stateHash()
  inc hero.deaths
  doAssert game.stateHash() != hash
  doAssert snapshot.heroes[0].deaths == 20
  world.restore(snapshot)
  doAssert game.stateHash() == hash

echo "Testing both base teams buy back immediately when affordable"
for team in Team:
  let
    game = buybackGame()
    world = game.world
    index = team.ord * 5
    hero = world.heroes[index]
  game.loadBots([BotGroup(path: BasePolicy, count: 10)])
  for i in 0 ..< game.heroVms.len:
    if i != index:
      game.heroVms[i] = nil
  let vm = game.heroVms[index]
  game.recorder = initReplayRecorder(game.currentSetup(10), game.map.preset)
  hero.state = Dying
  hero.hp = 0
  hero.deathTicks = 0
  hero.deaths = 12
  hero.gold = 1199
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert hero.state == Dying and hero.gold == 1199
  doAssert game.recorder.data.actions.len == 0
  hero.gold = 1200
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert hero.state == Marching and hero.gold == 0
  doAssert hero.hp == hero.maxHp and hero.deaths == 12
  doAssert game.recorder.data.actions.len == 1
  doAssert game.recorder.data.actions[0].kind == ActionBuyback
  doAssert game.recorder.data.actions[0].heroId == hero.id
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert hero.abilityLevels[PrimaryAbility] == 1
  for i in 1 ..< game.recorder.data.actions.len:
    doAssert game.recorder.data.actions[i].kind != ActionBuyback

echo "Testing buyback validation, exact payment, and full restoration"
block:
  let
    game = buybackGame()
    world = game.world
    hero = world.heroes[0]
  hero.gold = 200
  doAssert not world.applyBuyback(-1)
  doAssert not world.applyBuyback(hero.id)
  doAssert hero.lastActionError == ActionNotDead
  doAssert hero.gold == 200
  doAssert world.applyLevelAbility(hero.id, PrimaryAbility.ord)
  let levels = hero.abilityLevels
  hero.hp = 0
  game.tickWorld(nil)
  hero.gold = 99
  doAssert not world.applyBuyback(hero.id)
  doAssert hero.lastActionError == ActionInsufficientGold
  doAssert hero.gold == 99 and hero.state == Dying
  hero.gold = 100
  hero.mana = 0
  hero.inventory[0] = ManaPotion
  hero.itemCounts[0] = 2
  hero.cooldowns[PrimaryAbility] = 200
  hero.charges[PrimaryAbility] = 0
  hero.recharges[PrimaryAbility] = 100
  hero.portalCooldownEnds = world.tick + 100
  hero.potionCooldownEnds[HealthRecovery] = world.tick + 100
  hero.controls[StunControl].ends = world.tick + 100
  hero.controls[RootControl].ends = world.tick + 100
  hero.controls[SilenceControl].ends = world.tick + 100
  let cooldownEnds = world.tick + 100
  doAssert world.applyBuyback(hero.id)
  doAssert hero.lastActionError == NoActionError
  doAssert hero.gold == 0 and hero.deaths == 1
  doAssert hero.hp == hero.maxHp and hero.mana == hero.maxMana
  doAssert abs(hero.position.x - hero.spawnPosition.x) <= 1
  doAssert abs(hero.position.z - hero.spawnPosition.z) <= 1
  doAssert hero.position.y == hero.spawnPosition.y
  doAssert hero.state == Marching and hero.deathTicks == 0
  doAssert not hero.hasMoveTarget and hero.attackObjectId == 0
  doAssert hero.inventory[0] == ManaPotion and hero.itemCounts[0] == 2
  doAssert hero.cooldowns[PrimaryAbility] == 0
  doAssert hero.recharges[PrimaryAbility] == 0
  doAssert hero.charges[PrimaryAbility] ==
    heroAbility(hero.class, PrimaryAbility).abilitySpec.charges
  doAssert hero.abilityLevels == levels and hero.abilityPoints == 0
  doAssert hero.charges[UltimateAbility] == 0
  doAssert hero.controls == default(typeof(hero.controls))
  doAssert hero.portalCooldownEnds == cooldownEnds
  doAssert hero.potionCooldownEnds[HealthRecovery] == cooldownEnds
  doAssert not world.applyBuyback(hero.id)
  doAssert hero.gold == 0 and hero.deaths == 1
  hero.hp = 0
  game.tickWorld(nil)
  doAssert hero.deaths == 2
  doAssert world.buybackPrice(hero.id) == 200
  hero.gold = 500
  world.gameOver = true
  doAssert world.buybackPrice(hero.id) == 0
  doAssert not world.applyBuyback(hero.id)
  doAssert hero.lastActionError == ActionMatchEnded
  doAssert hero.gold == 500 and hero.state == Dying

echo "Testing human buyback commands record accepted and rejected attempts"
block:
  let
    game = buybackGame()
    hero = game.world.heroes[0]
  game.recorder = initReplayRecorder(game.currentSetup(10), game.map.preset)
  hero.hp = 0
  game.tickWorld(nil)
  hero.gold = 100
  queueBuyback(hero.id)
  queueBuyback(hero.id)
  game.flushPlayerCommands()
  doAssert hero.state == Marching and hero.gold == 0
  doAssert game.recorder.data.actions.len == 2
  for action in game.recorder.data.actions:
    doAssert action.kind == ActionBuyback and action.heroId == hero.id
  doAssert hero.lastActionError == ActionNotDead

echo "Testing dead BASIC decisions, buyback queries, replay, and seeking"
block:
  let
    directory = createTempDir("gota-buyback-", "")
    path = directory / "buyback.bas"
    game = buybackGame()
    hero = game.world.heroes[0]
  defer:
    removeDir(directory)
  writeFile(path, """
turns = turns + 1
if selfRespawnTicks > 0 then
  deaths = selfDeaths
  remaining = selfRespawnTicks
  price = buybackPrice()
  bought = buyback()
  duplicate = buyback()
  priceAfter = buybackPrice()
  snapshotHp = selfHp
  snapshotGold = selfGold
else
  alivePrice = buybackPrice()
end if
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  for i in 1 ..< game.heroVms.len:
    game.heroVms[i] = nil
  let vm = game.heroVms[0]
  hero.hp = 0
  hero.gold = 100
  game.world.heroTurnTicks = 1
  game.recorder = initReplayRecorder(game.currentSetup(10), game.map.preset)
  let initial = game.world.clone()
  for tick in 1 .. 5:
    game.tickWorld(proc() =
      ## Runs the real host at the normal decision phase.
      game.runBotDecisions()
    )
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("turns") == 5
  doAssert vm.runtime.getGlobal("deaths") == 1
  doAssert vm.runtime.getGlobal("remaining") == HeroDeathTicks + 8 * TickRate
  doAssert vm.runtime.getGlobal("price") == 100
  doAssert vm.runtime.getGlobal("bought") == 1
  doAssert vm.runtime.getGlobal("duplicate") == 0
  doAssert vm.runtime.getGlobal("priceAfter") == 0
  doAssert vm.runtime.getGlobal("alivePrice") == 0
  doAssert vm.runtime.getGlobal("snapshotHp") == 0
  doAssert vm.runtime.getGlobal("snapshotGold") == 100
  doAssert hero.state != Dying and hero.gold == 0 and hero.deaths == 1
  let
    data = decodeReplay(encodeReplay(game.recorder.data))
    playback = newGame(game.map, 240, 0, true, data)
  doAssert data.actions.len == 2
  playback.historyPlayback = true
  playback.replayPlayer = initReplayPlayer(data)
  for pass in 0 .. 1:
    playback.world.restore(initial)
    playback.replayPlayer.syncCursor(0)
    for tick in 1 .. 5:
      playback.tickWorld(nil)
    doAssert playback.hashCheck.mismatches == 0, playback.hashCheck.error
    doAssert playback.stateHash() == game.stateHash()
