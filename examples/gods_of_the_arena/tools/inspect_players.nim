import std/[json, os]
import herostats, tournaments

proc main() =
  ## Extracts verified player counters using the replay's matching game build.
  require(paramCount() == 3,
    "Usage: inspect_players REPLAY METADATA OUTPUT_JSON")
  let stats = inspectReplay(paramStr(1), readStats(paramStr(2)))
  require(stats["replay_version"].getInt in 26 .. 29,
    "This replay version needs its reward accounting checked")
  for hero in stats["heroes"]:
    let counts = objectiveCounts(
      hero["xp"].getInt,
      hero["gold"].getInt,
      hero["kills"].getInt
    )
    hero["tower_kills"] = %counts[0]
    hero["last_hits"] = %counts[1]
  saveJson(paramStr(3), stats)

try:
  main()
except CatchableError as error:
  stderr.writeLine("Player statistics error: " & error.msg)
  quit(1)
