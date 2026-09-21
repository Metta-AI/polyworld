import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, pathing, tapes],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

proc quietGame(team = RedTeam, size = 116): Game =
  ## Creates a real map with one living hero and no nearby combat.
  var preset = defaultConfig()
  preset.mapSize = size
  result = newGame(generateMap(54, preset), 100_000, 10, false, ReplayData())
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.manualSpells = true
    hero.state = Dying
    hero.deathTicks = -100_000
    hero.hp = 0
  for building in result.world.buildings.mitems:
    building.hp = 0
  let hero = result.world.heroes[team.ord * 5]
  hero.state = Marching
  hero.hp = hero.maxHp
  hero.gold = 10_000
  result.tickWorld(nil)

proc step(game: Game, ticks: int) =
  ## Advances the normal tick pipeline with no bot decisions.
  for i in 0 ..< ticks:
    game.tickWorld(nil)

proc enter(hero: Hero, area: BaseArea) =
  ## Places a test hero on an open tile of the requested generated region.
  for z in 0 ..< mapTiles():
    for x in 0 ..< mapTiles():
      if baseArea(x, z) == area and isWalkable(GroundLayer, x, z):
        hero.place(WorldPoint(
          x: (x - mapTiles() div 2).int32 * WorldScale + WorldScale div 2,
          z: (z - mapTiles() div 2).int32 * WorldScale + WorldScale div 2
        ))
        hero.navLayer = GroundLayer
        return
  doAssert false, "No open floor in " & $area

echo "Testing purchases and spawn recovery use the exact own base floors"
for size in [64, 116, 256]:
  for team in Team:
    let
      game = quietGame(team, size)
      world = game.world
      hero = world.heroes[team.ord * 5]
      keep = if team == RedTeam: RedKeep else: BlueKeep
      spawn = if team == RedTeam: RedSpawn else: BlueSpawn
      enemySpawn = if team == RedTeam: BlueSpawn else: RedSpawn
    doAssert hero.inOwnSpawn and hero.canShop
    doAssert world.applyBuyItem(hero.id, HealthPotion.ord.int32)
    doAssert world.applyBuyItem(hero.id, HealthPotion.ord.int32)
    doAssert hero.itemCounts[0] == 2
    doAssert hero.gold == 10_000 - 2 * HealthPotion.itemSpec.cost
    for area in [OutsideBase, enemySpawn]:
      hero.enter(area)
      let gold = hero.gold
      doAssert not hero.inOwnSpawn and not hero.canShop
      doAssert not world.applyBuyItem(hero.id, HealthPotion.ord.int32)
      doAssert hero.lastActionError == ActionOutsideKeep
      doAssert hero.gold == gold and hero.itemCounts[0] == 2
      hero.hp = 1
      hero.mana = 0
      game.step(TickRate)
      doAssert hero.hp == 1 and hero.mana == TickRate div 6
    hero.enter(keep)
    doAssert hero.canShop and not hero.inOwnSpawn
    doAssert world.applyBuyItem(hero.id, ManaPotion.ord.int32)
    hero.hp = 1
    game.step(TickRate)
    doAssert hero.hp == 1
    hero.enter(spawn)
    hero.hp = 1
    hero.mana = 0
    game.step(TickRate)
    doAssert abs(hero.hp - (1 + hero.maxHp div SpawnRecoverySeconds)) <= 1
    doAssert hero.mana >= hero.maxMana div SpawnRecoverySeconds
    game.step(4 * TickRate)
    doAssert hero.hp == hero.maxHp and hero.mana == hero.maxMana
    hero.hp = 0
    doAssert not hero.canShop and not hero.inOwnSpawn
    game.step(1)
    doAssert hero.hp == 0 and hero.state == Dying

echo "Testing potion stacks, exact regeneration, and shared family cooldowns"
for item in [HealthPotion, VitalityElixir, ManaPotion, ManaElixir]:
  let
    game = quietGame()
    world = game.world
    hero = world.heroes[0]
    spec = item.itemSpec
    kind = if spec.heal > 0: HealthRecovery else: ManaRecovery
    alternative =
      if spec.heal > 0:
        (if item == HealthPotion: VitalityElixir else: HealthPotion)
      else:
        (if item == ManaPotion: ManaElixir else: ManaPotion)
  doAssert world.applyBuyItem(hero.id, item.ord.int32)
  doAssert world.applyBuyItem(hero.id, item.ord.int32)
  doAssert world.applyBuyItem(hero.id, alternative.ord.int32)
  hero.enter(OutsideBase)
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert hero.itemCounts[0] == 2
  doAssert hero.itemCooldown(0, world.tick) == 0
  hero.maxHp = 1000
  hero.maxMana = 1000
  hero.hp = 1
  hero.mana = 0
  doAssert world.applyUseItem(hero.id, 0)
  doAssert hero.itemCounts[0] == 1
  doAssert hero.itemCooldown(0, world.tick) == 10 * TickRate
  doAssert hero.itemCooldown(1, world.tick) == 10 * TickRate
  doAssert not world.applyUseItem(hero.id, 1)
  doAssert hero.lastActionError == ActionCooldown
  doAssert hero.itemCounts[1] == 1
  if spec.recoveryTicks > 0:
    doAssert hero.hp == 1 and hero.mana == 0
    doAssert hero.recoveryItems[kind] == item
  else:
    doAssert hero.hp == 1 + spec.heal
    doAssert hero.mana == spec.restore
  game.step(PotionCooldownTicks - 1)
  doAssert hero.itemCooldown(0, world.tick) == 1
  doAssert not world.applyUseItem(hero.id, 0)
  game.step(1)
  doAssert hero.hp == 1 + spec.heal
  doAssert hero.mana == spec.restore + PotionCooldownTicks div 6
  doAssert hero.recoveryItems[kind] == NoItem
  doAssert hero.itemCooldown(0, world.tick) == 0
  doAssert world.applyUseItem(hero.id, 0)
  doAssert hero.inventory[0] == NoItem and hero.itemCounts[0] == 0
  doAssert not world.applyUseItem(hero.id, 1)

echo "Testing damage cancels both recovery effects and preserves cooldowns"
block:
  let
    game = quietGame()
    world = game.world
    hero = world.heroes[0]
  hero.inventory[0] = HealthPotion
  hero.inventory[1] = ManaPotion
  hero.itemCounts[0] = 2
  hero.itemCounts[1] = 2
  hero.enter(OutsideBase)
  hero.hp = 100
  hero.mana = 0
  doAssert world.applyUseItem(hero.id, 0)
  doAssert world.applyUseItem(hero.id, 1)
  game.step(TickRate)
  doAssert hero.hp == 112
  let saved = world.clone()
  let savedHash = game.stateHash()
  hero.recoveryItems[HealthRecovery] = NoItem
  doAssert game.stateHash() != savedHash
  world.restore(saved)
  doAssert game.stateHash() == savedHash
  let target = world.heroes[0]
  let attacker = world.heroes[5]
  attacker.state = Marching
  attacker.hp = attacker.maxHp
  attacker.place(target.position)
  attacker.inventory[0] = PoisonPotion
  attacker.itemCounts[0] = 1
  attacker.attackObjectId = target.id
  for cell in world.teamVisible[attacker.team.ord].mitems:
    cell = 255
  doAssert world.applyUseItem(attacker.id, 0)
  doAssert target.recoveryItems == default(typeof(target.recoveryItems))
  doAssert target.itemCooldown(0, world.tick) == 9 * TickRate
  when defined(replayEvents):
    var interruptions = 0
    for event in world.events:
      if event.kind == RecoveryInterrupted:
        inc interruptions
    doAssert interruptions == 2
  attacker.state = Dying
  attacker.deathTicks = -100_000
  let hp = target.hp
  game.step(TickRate)
  doAssert target.hp == hp

echo "Testing BASIC inventory queries and exact replay regeneration"
block:
  let
    directory = createTempDir("gota-potions-", "")
    path = directory / "potions.bas"
    game = newGame(generateMap(54), 100_000, 10, false, ReplayData())
  defer:
    removeDir(directory)
  writeFile(path, """
shop = canShop()
spawn = inOwnSpawn()
if started = 0 then
  learned = levelAbility(1)
  bought = buyItem(22)
  boughtAgain = buyItem(22)
  started = 1
end if
if selfMana < selfMaxMana then
  useItem(0)
end if
count = itemCount(0)
remaining = itemCooldown(0)
invalid = itemCooldown(-1) + itemCooldown(99)
castPoint(1, selfX, selfY)
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  game.recorder = initReplayRecorder(game.currentSetup(300), game.map.preset)
  for tick in 1 .. 300:
    game.tickWorld(proc() = game.runBotDecisions())
  var consumed = false
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.getGlobal("learned") == 1
    doAssert vm.runtime.getGlobal("bought") == 1
    doAssert vm.runtime.getGlobal("boughtAgain") == 1
    doAssert vm.runtime.getGlobal("shop") == 1
    doAssert vm.runtime.getGlobal("spawn") == 1
    doAssert vm.runtime.getGlobal("invalid") == 0
    if vm.runtime.getGlobal("count") < 2:
      consumed = true
  doAssert consumed
  let
    data = decodeReplay(game.recorder.data.encodeReplay())
    playback = newGame(generateMap(54), 100_000, 0, true, data)
  playback.historyPlayback = true
  playback.replayPlayer = initReplayPlayer(data)
  var snapshot: World
  for tick in 1 .. 300:
    playback.tickWorld(nil)
    if tick == 50:
      snapshot = playback.world.clone()
  doAssert playback.hashCheck.mismatches == 0
  doAssert playback.stateHash() == game.stateHash()
  playback.world.restore(snapshot)
  playback.replayPlayer.syncCursor(uint32(snapshot.tick))
  for tick in 51 .. 300:
    playback.tickWorld(nil)
  doAssert playback.hashCheck.mismatches == 0
  doAssert playback.stateHash() == game.stateHash()

echo "test_gota_potions: all checks passed"
