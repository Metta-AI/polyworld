import
  std/[json, os, strutils],
  ../[maps, replays, sim],
  balance_diagnostics

proc main() =
  ## Verifies a sample against the exact source and tuning of its batch.
  doAssert paramCount() in 1 .. 2, "Expected replay and optional diagnostics path"
  let
    data = loadReplay(paramStr(1))
    map = generateMap(data.config.seed, data.config.mapPreset)
    game = newGame(
      map, data.config.spawnIntervalTicks, 0, true, data
    )
  game.replayPlayer = initReplayPlayer(data)
  game.historyPlayback = true
  var diagnostics: Diagnostics
  let timeline = newJArray()
  while game.world.tick < data.hashes.len:
    doAssert not game.finished(), "Replay finished before its last hash"
    game.tickWorld(nil)
    if paramCount() == 2:
      diagnostics.collect(game.world)
      when defined(replayEvents):
        for event in game.world.events:
          if event.kind == Death and event.target.kind == 2:
            timeline.add %*{"tick": event.tick,
              "victim": event.target.class, "killer_kind": event.actor.kind,
              "killer_class": event.actor.class, "cause": $event.cause,
              "ability": event.detail}
    doAssert game.hashCheck.mismatches == 0, "Replay hash mismatch"
  doAssert game.finished(), "Replay ended before the match finished"
  if paramCount() == 2:
    let heroes = newJArray()
    for hero, values in diagnostics:
      heroes.add %*{"class": hero, "diagnostics": values.diagnosticsJson}
    writeFile(paramStr(2), (%*{"heroes": heroes, "deaths": timeline}).pretty)
  echo "Verified ", game.world.tick, " ticks; ", game.world.outcome(),
    "; final hash ", stateHash(game).toHex(16)

main()
