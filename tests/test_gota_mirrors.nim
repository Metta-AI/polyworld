import
  std/[os, strformat],
  polyworld/cli,
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

const
  Policy = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/players/base.bas"
  MirrorSlots = [3, 4, 2, 0, 1]

proc checkMirror(seed: int32, roster, ticks: int) =
  ## Compares equal lineups using each faction's actual IDs and spawn seats.
  let game = newGame(generateMap(seed), 480, 10, false,
    ReplayData(), drafting = false)
  for hero in game.world.heroes:
    let slot =
      if hero.team == RedTeam: hero.slot
      else: MirrorSlots[hero.slot]
    hero.class = HeroClass(slot + roster * 5)
    hero.refreshHeroStats()
  game.loadBots([BotGroup(path: Policy, count: 10)])
  for tick in 1 .. ticks:
    game.tickWorld(proc() =
      ## Runs the same policy in all ten seats.
      game.runBotDecisions())
    for red in game.world.heroes:
      if red.team != RedTeam:
        continue
      let blue = game.world.heroes[5 + MirrorSlots[red.slot]]
      let label = &"seed={seed} roster={roster} tick={tick} class={red.class}"
      doAssert red.class == blue.class, label
      doAssert red.spawnPosition.x == -blue.spawnPosition.x and
        red.spawnPosition.z == -blue.spawnPosition.z, label & " spawns"
      doAssert red.position.x == -blue.position.x and
        red.position.y == blue.position.y and
        red.position.z == -blue.position.z, label & " position"
      doAssert red.velocity.x == -blue.velocity.x and
        red.velocity.z == -blue.velocity.z, label & " velocity"
      doAssert (red.hp, red.maxHp, red.mana, red.maxMana, red.level,
        red.xp, red.totalXp, red.creepXpRemainder, red.gold, red.deaths) ==
        (blue.hp, blue.maxHp, blue.mana, blue.maxMana, blue.level,
        blue.xp, blue.totalXp, blue.creepXpRemainder, blue.gold, blue.deaths),
        label & " health and economy"
      doAssert (red.state, red.swingTicks, red.damageLanded,
        red.attacksLanded) == (blue.state, blue.swingTicks,
        blue.damageLanded, blue.attacksLanded), label & " combat"
      doAssert red.inventory == blue.inventory and
        red.itemCounts == blue.itemCounts, label & " inventory"
      doAssert red.abilityLevels == blue.abilityLevels and
        red.charges == blue.charges and red.cooldowns == blue.cooldowns and
        red.recharges == blue.recharges, label & " abilities"
      doAssert red.potionCooldownEnds == blue.potionCooldownEnds and
        red.recoveryApplied == blue.recoveryApplied and
        red.recoveryStarted == blue.recoveryStarted, label & " recovery"
    doAssert game.world.teamHeroKills[0] == game.world.teamHeroKills[1]
    doAssert game.world.forts[0].hp == game.world.forts[1].hp
    for vm in game.heroVms:
      doAssert not vm.failed, vm.lastError
    if game.finished():
      break
  echo "Equal-lineup ticks: ", game.world.tick, ", seed: ", seed,
    ", roster: ", roster, ", kills: ", game.world.teamHeroKills

echo "Testing equal lineups with actual opposite-side actor identities"
when defined(gotaLongSymmetry):
  for seed in [0, 7, 8, 42, 1365528421]:
    for roster in 0 .. 1:
      checkMirror(seed.int32, roster, 28_800)
else:
  for roster in 0 .. 1:
    checkMirror(7, roster, 1200)
