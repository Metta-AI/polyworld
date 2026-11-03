import
  std/[json, monotimes, os, strutils, times],
  jsony, bassy,
  polyworld/[cli, metrics],
  ../[bots, content, maps, replays, sim],
  balance_diagnostics

type BalanceWorkerError = object of CatchableError

proc main() =
  ## Runs one isolated match with a frozen policy and assigned draft roster.
  if paramCount() != 1:
    raise newException(BalanceWorkerError, "Expected one job JSON path")
  let
    job = readFile(paramStr(1)).fromJson(JsonNode)
    config = loadConfig(job["config"].getStr)
    started = getMonoTime()
    seed = job["seed"].getInt.int32
    gameMap = generateMap(seed, config.mapPreset)
    game = newGame(
      gameMap, config.spawnIntervalTicks, 10, false, ReplayData()
    )
  game.replayData = initReplayData(
    currentSetup(game, config.maxTicks.uint32), gameMap.preset
  )
  game.replayData.config = config
  game.replayData.config.seed = seed
  if job{"replay"}.getStr.len > 0:
    game.recorder = initReplayRecorder(
      currentSetup(game, config.maxTicks.uint32), gameMap.preset
    )
    game.recorder.data.config = game.replayData.config
  var seen: set[HeroClass]
  if job["roster"].kind != JArray or job["roster"].len != HeroClassCount:
    raise newException(BalanceWorkerError, "Expected ten assigned hero slots")
  for value in job["roster"]:
    if value.kind != JInt or value.getInt notin 0 .. HeroClass.high.ord:
      raise newException(BalanceWorkerError, "Invalid hero class in roster")
    let class = HeroClass(value.getInt)
    if class in seen:
      raise newException(BalanceWorkerError, "Duplicate hero in roster")
    seen.incl(class)
  if seen.card != HeroClassCount:
    raise newException(BalanceWorkerError, "Expected all ten hero classes")
  game.loadBots([BotGroup(path: job["policy"].getStr, count: 10)])
  let roleDraft = job{"draft"}.getStr == "roles"
  if roleDraft:
    for slot, vm in game.heroVms:
      vm.runtime.setGlobal("draftConfigured", 1'i32)
      vm.runtime.setGlobal("draftPreferred", job["roster"][slot].getInt.int32)
  var diagnostics: Diagnostics
  while not game.finished():
    game.tickWorld(proc() =
      ## Applies the experimental draft, then runs the unchanged policy.
      if game.world.phase == Drafting and not roleDraft:
        let
          heroId = game.world.draftHeroId()
          slot = game.world.heroIndex(heroId)
        game.recorder.record ReplayAction(
          tick: game.world.tick.uint32, heroId: heroId,
          kind: ActionDraft, first: job["roster"][slot].getInt.int32
        )
        if not game.world.applyDraft(heroId, job["roster"][slot].getInt.int32):
          raise newException(BalanceWorkerError, "Assigned draft failed")
      else:
        game.runBotDecisions()
        for vm in game.heroVms:
          if vm == nil or vm.failed:
            raise newException(BalanceWorkerError,
              "Policy failed: " &
                (if vm == nil: "missing VM" else: vm.lastError))
    )
    if job{"diagnostics"}.getBool:
      diagnostics.collect(game.world)
  if roleDraft:
    var roles: array[2, set[HeroRole]]
    for slot, hero in game.world.heroes:
      if hero.class.ord != job["roster"][slot].getInt:
        raise newException(BalanceWorkerError, "Policy draft ignored fixture")
      roles[hero.team.ord].incl(hero.class.heroRole)
    for covered in roles:
      if covered.card != 5:
        raise newException(BalanceWorkerError, "Policy draft omitted a role")
  let heroes = newJArray()
  for slot, hero in game.world.heroes:
    let values = game.world.stats.values[slot]
    heroes.add %*{
      "class": hero.class.ord, "name": hero.class.heroSpec.name,
      "team": hero.team.ord, "slot": slot, "level": hero.level,
      "xp": hero.totalXp, "gold": values[GoldMetric],
      "kills": values[KillsMetric], "deaths": values[LossesMetric],
      "assists": values[AssistsMetric],
      "diagnostics": diagnostics[hero.class.ord].diagnosticsJson
    }
  if game.recorder != nil:
    if game.recordingError.len > 0:
      raise newException(BalanceWorkerError, game.recordingError)
    saveReplay(job["replay"].getStr, game.recorder.data)
  let result = %*{
    "job": job, "outcome": game.world.outcome(),
    "ticks": game.world.tick, "battle_ticks": game.world.battleTick(),
    "seconds": (getMonoTime() - started).inMilliseconds.float / 1000,
    "state_hash": stateHash(game).toHex(16),
    "replay_version": ReplayGameVersion, "heroes": heroes
  }
  let output = job["output"].getStr
  writeFile(output & ".tmp", result.pretty & "\n")
  moveFile(output & ".tmp", output)

try:
  main()
except CatchableError as error:
  stderr.writeLine("Balance worker: " & error.msg)
  quit(1)
