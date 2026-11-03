import
  std/[json, os, strutils],
  zippy,
  polyworld/[metrics, tapes],
  ../[maps, replays, scores, sim],
  tournaments

proc main() =
  ## Reconstructs Fast XP results only after verifying every replay state hash.
  require(paramCount() == 4,
    "Usage: inspect_fast REPLAY RUN_JSON GAME_ID OUTPUT_JSON")
  let
    run = readJson(paramStr(2))
    scheduled = run["schedule"][parseInt(paramStr(3)) - 1]
    bytes = readFile(paramStr(1))
    data = decodeReplay(
      if bytes.startsWith("\x1f\x8b"): uncompress(bytes) else: bytes
    )
  require(scheduled["id"].getStr == paramStr(3), "Wrong scheduled game")
  require(data.config.seed.int == scheduled["seed"].getInt,
    "Replay seed differs from schedule")
  require(data.config.maxTicks.int == run["game_config"]["max_ticks"].getInt,
    "Replay duration differs from frozen configuration")
  require(data.config.draftMode == OpenDraft, "Expected open drafting")
  let
    gameMap = generateMap(data.config.seed, data.config.mapPreset)
    game = newGame(gameMap, data.config.spawnIntervalTicks, 0, true, data)
  require(data.hashes.len > 0, "Replay contains no recorded ticks")
  game.replayPlayer = initReplayPlayer(data)
  game.historyPlayback = true
  var
    towerKills: array[10, int]
    lastHits: array[10, int]
  while game.world.tick < data.hashes.len:
    let before = game.world.tick
    game.tickWorld(nil)
    require(game.world.tick > before, "Replay stopped before its end")
    require(game.hashCheck.mismatches == 0, game.hashCheck.error)
    for event in game.world.events:
      let slot = event.actor.player.int
      if event.kind == Death and slot in 0 ..< 10:
        case event.target.kind
        of 3:
          inc lastHits[slot]
        of 4, 5:
          inc towerKills[slot]
        else:
          discard
  require(game.replayPlayer.finished, "Unconsumed replay actions")
  require(game.world.heroes.len == 10, "Expected ten heroes")
  let
    victories = game.world.scores()
    raw = %*{
      "scores": scores(game.world.totalXp(), game.world.tick.int, victories),
      "total_xp": game.world.totalXp(), "ticks": game.world.tick,
      "seed": data.config.seed, "outcome": game.world.outcome()
    }
    stats = %*{
      "verified": true, "hash_mismatches": 0,
      "replay_version": data.header.gameVersion,
      "ticks": game.world.tick, "outcome": game.world.outcome(), "heroes": []
    }
  for slot, hero in game.world.heroes:
    let
      policy = run["roster"][scheduled["seats"][slot].getInt]
      values = game.world.stats.values[slot]
    stats["heroes"].add %*{
      "slot": slot, "policy_version_id": policy["id"],
      "xp": hero.totalXp, "win": victories[slot], "level": hero.level,
      "gold": values[GoldMetric], "banked_gold": hero.gold,
      "kills": values[KillsMetric], "deaths": values[LossesMetric],
      "assists": values[AssistsMetric], "tower_kills": towerKills[slot],
      "last_hits": lastHits[slot]
    }
  validateResult(raw, scheduled, run)
  validatePlayerStats(stats, raw, scheduled, run)
  saveJson(paramStr(4), %*{"result": raw, "player_stats": stats})

try:
  main()
except CatchableError as error:
  stderr.writeLine("Fast XP replay error: " & error.msg)
  quit(1)
