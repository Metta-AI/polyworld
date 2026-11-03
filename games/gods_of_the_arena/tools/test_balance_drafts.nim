import
  std/[json, os],
  bassy,
  polyworld/cli,
  balances, ../[bots, content, maps, replays, sim]

proc main() =
  ## Exercises the real BASIC draft with seeded preferences and fallback picks.
  doAssert paramCount() == 2, "Expected policy and config paths"
  let
    policy = paramStr(1)
    config = loadConfig(paramStr(2))
    fixtures = roleSchedule(100, 1988)
  for configured in [false, true]:
    for job in fixtures:
      let
        map = generateMap(job["seed"].getInt.int32, config.mapPreset)
        game = newGame(map, config.spawnIntervalTicks, 10, false, ReplayData())
      game.loadBots([BotGroup(path: policy, count: 10)])
      if configured:
        for slot, vm in game.heroVms:
          vm.runtime.setGlobal("draftConfigured", 1'i32)
          vm.runtime.setGlobal("draftPreferred",
            job["roster"][slot].getInt.int32)
      while game.world.phase == Drafting:
        doAssert game.world.tick < 120, "Draft did not finish promptly"
        game.tickWorld(proc() =
          ## Executes the policy's actual draft commands through the host API.
          game.runBotDecisions()
        )
        for vm in game.heroVms:
          doAssert not vm.failed, vm.lastError
      var
        roles: array[2, set[HeroRole]]
        heroes: set[HeroClass]
      for slot, hero in game.world.heroes:
        roles[hero.team.ord].incl(hero.class.heroRole)
        heroes.incl(hero.class)
        if configured:
          doAssert hero.class.ord == job["roster"][slot].getInt
      doAssert heroes.card == 10
      doAssert roles[0].card == 5 and roles[1].card == 5
  echo "All 200 draft-only checks passed; no combat games were played"

main()
