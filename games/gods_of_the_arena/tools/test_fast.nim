import
  std/[json, os, sequtils, sets, strutils, tables, times],
  tournaments, fasts, reports,
  ../scores

echo "Checking Fast XP retry delays"
doAssert retrySeconds("", fromUnix(0)) == 0
doAssert retrySeconds("7", fromUnix(0)) == 7
doAssert retrySeconds("Thu, 01 Jan 1970 00:00:12 GMT", fromUnix(5)) == 7
doAssert retrySeconds("Thu, 01 Jan 1970 00:00:12 GMT", fromUnix(20)) == 0

echo "Checking explicit shutdown recovery without retrying unknown failures"
doAssert shutdownResponse(503, "{\"error\":\"Server shutting down\"}")
doAssert not shutdownResponse(504, "{\"error\":\"Server shutting down\"}")
doAssert not shutdownResponse(503, "{\"error\":\"upstream connection lost\"}")
doAssert not shutdownResponse(503, "not JSON")
doAssert shutdownRecord(%*{
  "uncertain": true,
  "error": "HTTP 503: {\"error\":\"Server shutting down\"}",
  "attempts": [{"http_status": 503}]
})
doAssert not shutdownRecord(%*{
  "uncertain": true, "error": "Connection timed out",
  "attempts": [{"http_status": 0}]
})

echo "Checking same-version redeployments retain release verification"
let versionRun = %*{"release": {"version": "2026.10.8.1"}}
validateFastVersion(versionRun, %*{
  "game_version": "2026.10.8.1", "game_revision": "new-service-revision"
})
for attempt in [
  %*{"game_version": "2026.10.9.1", "game_revision": "other"},
  %*{"game_version": "2026.10.8.1", "game_revision": ""}
]:
  var rejected = false
  try:
    validateFastVersion(versionRun, attempt)
  except TournamentError:
    rejected = true
  doAssert rejected

echo "Checking frozen seats and exact format budgets"
var run = %*{
  "schema": Schema, "id": "fast-fixture", "name": "Fast XP fixture",
  "created": "2026-10-09T00:00:00Z", "settings": defaults(),
  "release": {"id": "fixture", "version": "2026.10.8.1"},
  "game_config": {"max_ticks": 28800}, "roster": [],
  "schedule": scheduleGames(2000, 10, "both", 20261009)
}
run["settings"]["games"] = %2000
run["settings"]["ladders"] = %*["glory"]
for i in 0 ..< 10:
  run["roster"].add %*{
    "id": "policy-" & $i, "name": "Player " & $i, "version": "bot:v1"
  }
for kind in Formats:
  doAssert run["schedule"].elems.countIt(it["format"].getStr == kind) == 1000
for game in run["schedule"]:
  let body = fastBody(run, game)
  doAssert body["num_episodes"].getInt == 1
  doAssert body["game_version"] == run["release"]["version"]
  doAssert body["seed"] == game["seed"]
  doAssert body["roster"].len == 10
  for slot, seat in body["roster"].elems:
    doAssert seat["slot"].getInt == slot
    doAssert seat["player"]["policy_ref"] ==
      run["roster"][game["seats"][slot].getInt]["id"]
  if game["format"].getStr == "mixed":
    doAssert game["seats"].elems.mapIt(it.getInt).toHashSet.len == 10
  else:
    doAssert game["seats"][0] != game["seats"][5]
    for slot in 0 ..< 10:
      doAssert game["seats"][slot] == game["seats"][(slot div 5) * 5]

echo "Checking only Glory panels and zero scores for losers and timeouts"
run["schedule"] = scheduleGames(40, 10, "both", 20261009)
run["settings"]["games"] = %40
var records: seq[JsonNode]
for game in run["schedule"]:
  let raw = %*{
    "scores": [], "total_xp": [], "ticks": 1440, "seed": game["seed"],
    "outcome": if game["id"].getStr == "000001": "time_limit" else: "RedTeam"
  }
  for slot in 0 ..< 10:
    raw["total_xp"].add %(100 + slot)
    raw["scores"].add %score(100 + slot, 1440, raw.seatWin(slot) == 1)
  for policy, values in gameValues(game, raw):
    if values[0] == 0:
      doAssert values[2] == 0
  records.add %*{
    "id": game["id"], "state": "completed", "attempts": [], "result": raw
  }
let
  summary = summarize(run, records, "completed")
  html = render(summary, Root.parentDir / "polyworld_art")
doAssert summary["panels"].len == 2
doAssert summary["completed"].getInt == 40
doAssert summary["included"].getInt == 40
for panel in summary["panels"]:
  doAssert panel["ladder"].getStr == "glory"
  doAssert panel["completed"].getInt == 20
  doAssert panel["history"].len == 2
doAssert "2 leaderboards" in html
doAssert "panel-mixed-glory" in html and "panel-mono-glory" in html
doAssert "panel-mixed-wins" notin html and "panel-mixed-score" notin html
echo "All Fast XP tournament checks passed"
