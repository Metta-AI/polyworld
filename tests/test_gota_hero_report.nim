import
  std/[json, strutils],
  ../examples/gods_of_the_arena/tools/heropages

echo "Testing hero-only report aggregation"
block:
  let
    hero = %*{"hero": "Ranger", "players": 2, "policies": 3,
      "games": 2, "appearances": 3, "avg_xp": 450}
    summary = %*{"heroes": [hero], "start": "start", "end": "end",
      "verified_games": 2, "hero_appearances": 3,
      "fixed_faction_lineups": true,
      "excluded": [{"id": "excluded-match", "error": "source error"}],
      "versions": [{"version": "one", "heroes": [hero]},
        {"version": "two", "heroes": [hero]}]}
    appearances = %*[
      {"hero": "Ranger", "level": 1, "id": "first-match",
        "game_version": "one", "minutes": 4,
        "player_name": "Private player", "player_id": "player-id"},
      {"hero": "Ranger", "level": 2, "id": "first-match",
        "game_version": "one", "minutes": 4},
      {"hero": "Ranger", "level": 20, "id": "second-match",
        "game_version": "two", "minutes": 10}]
    report = heroSummary(summary, appearances)
    bins = report["heroes"][0]["level_bins"]
  doAssert report["games"].getInt == 2
  doAssert report["avg_minutes"].getFloat == 7
  doAssert bins[0].getInt == 2
  doAssert bins[9].getInt == 1
  doAssert report["versions"][0]["games"].getInt == 1
  doAssert report["versions"][0]["avg_minutes"].getFloat == 4
  doAssert report["versions"][0]["heroes"][0]["level_bins"][9].getInt == 0
  doAssert report["versions"][1]["heroes"][0]["level_bins"][0].getInt == 0
  doAssert report["excluded_count"].getInt == 1
  doAssert report["heroes"][0]["avg_xp"].getInt == 450
  for removed in ["players", "policies", "Private player", "player-id",
      "first-match", "second-match", "excluded-match", "source error"]:
    doAssert removed notin $report, removed & " must not enter the report"
  doAssert summary["heroes"][0].hasKey("players")
  let empty = heroSummary(summary, newJArray())
  doAssert empty["games"].getInt == 0
  doAssert empty["avg_minutes"].getFloat == 0

echo "Hero report tests passed"
