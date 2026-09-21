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
  let html = renderHeroStats(summary, appearances)
  doAssert "@@" notin html
  doAssert "Spell levels" in html
  for removed in ["Private player", "player-id", "first-match",
    "second-match", "excluded-match", "source error"]:
      doAssert removed notin html

echo "Testing spell ranks, level gates and effects in the hero catalog"
block:
  let catalog = heroCatalog()
  doAssert catalog.len == 10
  for name, hero in catalog:
    doAssert hero["abilities"].len == 4, name
    for i, ability in hero["abilities"].elems:
      let
        ranks = ability["ranks"]
        requirements = if i == 3: @[6, 12, 18] else: @[1, 3, 5, 7]
      doAssert ability["slot"].getInt == i
      doAssert ability["key"].getStr == ["Q", "W", "E", "R"][i]
      doAssert ability["ultimate"].getBool == (i == 3)
      doAssert ranks.len == requirements.len
      doAssert ability["icon"].getStr.startsWith("hero_assets/ability_")
      for j, rank in ranks.elems:
        doAssert rank["rank"].getInt == j + 1
        doAssert rank["required_level"].getInt == requirements[j]
        if j > 0:
          doAssert rank["amount"].getInt > ranks[j - 1]["amount"].getInt
  let
    frost = catalog["Arcanist"]["abilities"][1]
    meteor = catalog["Arcanist"]["abilities"][3]
    guard = catalog["Vanguard Knight"]["abilities"][0]
    crystal = catalog["Arcanist"]["abilities"][0]
  doAssert frost["effect"].getStr == "Damage"
  doAssert frost["ranks"][0]["amount"].getInt == 42
  doAssert frost["ranks"][3]["amount"].getInt == 105
  doAssert frost["ranks"][3]["mana_cost"].getInt == 28
  doAssert frost["charges"].getInt == 3
  doAssert frost["cooldown_seconds"].getFloat == 2.0
  doAssert frost["recharge_seconds"].getFloat == 12.0
  doAssert meteor["ranks"][2]["amount"].getInt == 240
  doAssert guard["effect"].getStr == "Healing"
  doAssert guard["ranks"][3]["amount"].getInt == 70
  doAssert crystal["effect"].getStr == "Mana restored"
  doAssert crystal["ranks"][3]["amount"].getInt == 70

echo "Hero report tests passed"
