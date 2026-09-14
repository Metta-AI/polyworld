import
  std/[json, os, times],
  zippy,
  ../examples/gods_of_the_arena/tools/herostats,
  ../examples/gods_of_the_arena/[maps, replays, sim]

echo "Testing fractional completion-window boundaries"
block:
  let
    first = timestamp("2026-09-13T18:23:46.637658Z")
    last = first + initDuration(hours = 24)
  doAssert timestamp(stamp(first)) == first
  doAssert timestamp("2026-09-13T11:23:46.637658-07:00") == first
  doAssert inWindow(%*{"completed_at": stamp(first)}, first, last)
  doAssert not inWindow(%*{"completed_at": stamp(last)}, first, last)
  doAssert not inWindow(%*{"completed_at": newJNull()}, first, last)
  doAssert not inWindow(%*{"completed_at":
    "2026-09-13T18:23:46.637657Z"}, first, last)

echo "Testing full pagination and completed-time selection"
block:
  let
    first = timestamp("2026-09-13T00:00:00Z")
    last = first + initDuration(hours = 24)
    fetch: FetchPage = proc(path: string): JsonNode =
      ## Emulates a round crossing the boundary and a second episode page.
      case path
      of "/rounds?league_id=test&limit=200":
        %*{"entries": [{"id": "round_old", "round_number": 1,
          "created_at": "2026-09-12T23:00:00Z",
          "completed_at": "2026-09-13T00:30:00Z"}],
          "next_cursor": "second"}
      of "/rounds?league_id=test&limit=200&cursor=second":
        %*{"entries": [], "next_cursor": newJNull()}
      of "/rounds/round_old/episodes?limit=1000":
        %*{"entries": [{"id": "ereq_1",
          "completed_at": "2026-09-13T00:01:00Z"},
          {"id": "ereq_old", "completed_at": "2026-09-12T23:59:00Z"}],
          "next_cursor": "more"}
      of "/rounds/round_old/episodes?limit=1000&cursor=more":
        %*{"entries": [{"id": "ereq_1",
          "completed_at": "2026-09-13T00:01:00Z"},
          {"id": "ereq_2", "completed_at": "2026-09-13T00:02:00Z"}],
          "next_cursor": newJNull()}
      else:
        raise newException(HeroStatsError, "Unexpected test request")
    manifest = collect(fetch, "test", first, last)
  doAssert manifest["matches"].len == 2
  doAssert manifest["matches"][1]["id"].getStr == "ereq_2"
  doAssert manifest["matches"][0]["round_number"].getInt == 1

echo "Testing appearance denominators, draws, versions, and earned gold"
block:
  let hero = %*{"class": 0, "hero": "Vanguard Knight", "win": 1,
    "draw": false, "level": 5, "xp": 700, "kills": 3, "deaths": 2,
    "assists": 4, "gold": 300, "banked_gold": 10, "player_id": "player_1",
    "policy_version_id": "policy_1", "team": "BlueTeam"}
  var records = @[
    %*{"id": "a", "verified": true, "game_version": "one",
      "minutes": 5, "heroes": [hero]},
    %*{"id": "b", "verified": true, "game_version": "two",
      "minutes": 10, "heroes": [hero.copy()]}
  ]
  records[1]["heroes"][0]["win"] = %0
  records[1]["heroes"][0]["draw"] = %true
  records[1]["heroes"][0]["xp"] = %200
  let row = aggregate(records)[0]
  doAssert row["games"].getInt == 2
  doAssert row["win_rate"].getFloat == 0.5
  doAssert row["draws"].getInt == 1
  doAssert row["avg_xp"].getFloat == 450
  doAssert row["avg_gold"].getFloat == 300
  doAssert row["avg_banked_gold"].getFloat == 10
  doAssert row["gold_per_minute"].getFloat == 40
  doAssert row["players"].getInt == 1
  doAssert aggregate(records, "one")[0]["win_rate"].getFloat == 1
  records[0]["heroes"].add(hero.copy())
  let duplicate = aggregate(records)[0]
  doAssert duplicate["appearances"].getInt == 3
  doAssert duplicate["games"].getInt == 2
  doAssert duplicate["win_rate_ci95"].kind == JNull
  records[0]["verified"] = %false
  doAssert aggregate(records)[0]["games"].getInt == 1
  doAssert abs(wilson(50, 100)[0] - 0.4038315) < 0.000001

echo "Testing exact replay playback and rejection of corrupt state hashes"
block:
  let
    path = getTempDir() / ("gota-hero-stats-" & $getCurrentProcessId() &
      ".replay")
    game = newGame(generateMap(2026), 240, 10, false, ReplayData())
    metadata = %*{"id": "test", "coworld_version": "fixture",
      "completed_at": "2026-09-14T00:00:00Z",
      "participants": [], "participant_scores": []}
  game.recorder = initReplayRecorder(currentSetup(game, 3), game.map.preset)
  for slot in 0 ..< 10:
    metadata["participants"].add %*{"position": slot,
      "player_id": "player_" & $slot, "policy_version_id": "p" & $slot}
    metadata["participant_scores"].add %*{"position": slot, "score": 0}
  for i in 0 ..< 3:
    game.tickWorld(proc() =
      ## Records a stationary control game without running player scripts.
      game.world.heroTurnStart =
        (game.world.heroTurnStart + 1) mod game.world.heroes.len)
  saveReplay(path, game.recorder.data)
  try:
    let record = inspectReplay(path, metadata)
    doAssert record["verified"].getBool
    doAssert record["heroes"].len == 10
    doAssert record["ticks"].getInt == 3
    doAssert record["heroes"][0]["gold"].getInt == 0
    doAssert record["heroes"][0]["banked_gold"].getInt == 150
    writeFile(path, compress(readFile(path)))
    doAssert inspectReplay(path, metadata)["verified"].getBool
    game.recorder.data.hashes[1] = game.recorder.data.hashes[1] xor 1
    saveReplay(path, game.recorder.data)
    var rejected = false
    try:
      discard inspectReplay(path, metadata)
    except HeroStatsError:
      rejected = true
    doAssert rejected, "Divergent replays must never enter the averages"
  finally:
    removeFile(path)

echo "Hero statistics tests passed"
