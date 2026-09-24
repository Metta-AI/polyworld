import std/[json, os, strutils]
import balances

const Root = currentSourcePath().parentDir.parentDir

echo "Testing balanced schedules"
let jobs = schedule(100, 20260923)
doAssert jobs == schedule(100, 20260923)
doAssert jobs != schedule(100, 20260924)
var sides: array[10, array[2, int]]
for i, job in jobs.elems:
  var seen: set[0 .. 9]
  for slot, entry in job["roster"].elems:
    let hero = entry.getInt
    doAssert hero notin seen
    seen.incl(hero)
    inc sides[hero][slot div 5]
  doAssert seen.card == 10
  if i mod 2 == 1:
    doAssert job["seed"] == jobs[i - 1]["seed"]
    for slot in 0 ..< 5:
      doAssert job["roster"][5 + MirrorSlots[slot]] ==
        jobs[i - 1]["roster"][slot]
for exposure in sides:
  doAssert exposure == [50, 50]

echo "Testing decisive wins and paired confidence margins"
let games = newJArray()
for job in jobs:
  let heroes = newJArray()
  for slot, entry in job["roster"].elems:
    heroes.add %*{"class": entry, "team": slot div 5, "level": 8,
      "xp": 2400, "gold": 1800, "kills": 5, "deaths": 3, "assists": 4}
  games.add %*{"job": job, "outcome": "RedTeam", "heroes": heroes,
    "seconds": 10}
let summary = summarize(games)
for row in summary["heroes"]:
  doAssert row["wins"].getInt == 50
  doAssert row["losses"].getInt == 50
  doAssert row["win_rate"].getFloat == 0.5
  doAssert abs(row["margin95"].getFloat) < 1e-12
  doAssert row["level"].getFloat == 8
echo "Testing scalar and array diagnostic aggregation"
for game in games:
  for hero in game["heroes"]:
    hero["diagnostics"] = %*{"aliveTicks": 120, "casts": [0, 2, 3, 4]}
let measured = summarize(games)
for hero in measured["heroes"]:
  doAssert abs(hero["diagnostics"]["aliveTicks"].getFloat - 120) < 1e-9
  doAssert abs(hero["diagnostics"]["casts"][2].getFloat - 3) < 1e-9
echo "Testing independent validation batches with restarted pair numbers"
let pooled = poolBatches([games, games])
doAssert pooled["games"].getInt == 200
doAssert pooled["heroes"][0]["wins"].getInt == 100
doAssert pooled["heroes"][0]["win_rate"].getFloat == 0.5
doAssert games[0]["job"]["pair"].getInt == 0
doAssert games[99]["job"]["pair"].getInt == 49
for game in games:
  game["outcome"] = %"time_limit"
let draws = summarize(games)
for row in draws["heroes"]:
  doAssert row["draws"].getInt == 100
  doAssert row["wins"].getInt == 0
  doAssert row["win_rate"].kind == JNull

echo "Testing tuning thresholds, identities, and bounds"
var baseline = readFile(Root / "content.nim")
# Keep the tuning fixture separate from the exhausted-growth case below.
baseline.replaceValue(Rules[1].weakness, 20)
var unchanged = baseline
doAssert adjust(unchanged, baseline, draws, 5).len == 0
doAssert unchanged == baseline
for hero, row in summary["heroes"].elems:
  row["wins"] = %(if hero mod 2 == 0: 45 else: 55)
  row["losses"] = %(100 - row["wins"].getInt)
doAssert adjust(unchanged, baseline, summary, 5).len == 0
for row in summary["heroes"]:
  row["wins"] = %44
  row["losses"] = %56
var buffed = baseline
doAssert adjust(buffed, baseline, summary, 5).len == 10
for rule in Rules:
  doAssert buffed.value(rule.strength) > baseline.value(rule.strength)
  doAssert buffed.value(rule.weakness) == baseline.value(rule.weakness)
for row in summary["heroes"]:
  row["wins"] = %56
  row["losses"] = %44
var nerfed = baseline
doAssert adjust(nerfed, baseline, summary, 5).len == 10
for rule in Rules:
  doAssert nerfed.value(rule.strength) == baseline.value(rule.strength)
  doAssert (nerfed.value(rule.weakness) > baseline.value(rule.weakness)) ==
    rule.weakness.increase
for i in 0 ..< 100:
  discard adjust(nerfed, baseline, summary, 5)
for rule in Rules:
  let val = nerfed.value(rule.weakness)
  doAssert val >= (baseline.value(rule.weakness) + 1) div 2
  doAssert val <= baseline.value(rule.weakness) * 2
echo "Balance tests passed"

echo "Testing fixed incrementing seeds"
let fixed = fixedSchedule(100, 1988)
doAssert fixed == fixedSchedule(100, 1988)
for index, job in fixed.elems:
  doAssert job["seed"].getInt == 1988 + index
  doAssert job["roster"] == schedule(100, 1988)[index]["roster"]

echo "Testing confidence boundary decisions"
doAssert balanceStatus(%*{"win_rate": 0.37, "margin95": 0.13}) == Balanced
doAssert balanceStatus(%*{"win_rate": 0.63, "margin95": 0.13}) == Balanced
doAssert balanceStatus(%*{"win_rate": 0.369, "margin95": 0.13}) == TooWeak
doAssert balanceStatus(%*{"win_rate": 0.631, "margin95": 0.13}) == TooStrong
doAssert draws["heroes"][0].balanceStatus == NoResults
doAssert not draws.allBalanced

proc observation(source: string, crossbow: float): JsonNode =
  ## Makes a controlled search fixture with three initially unbalanced heroes.
  result = %*{"tuning": tuning(source), "heroes": [], "changes": []}
  for hero in 0 ..< HeroNames.len:
    let rate = case hero
      of 6: crossbow
      of 1: 0.8
      of 4: 0.2
      else: 0.5
    result["heroes"].add %*{"win_rate": rate, "margin95": 0.1}

echo "Testing one hero, overshoot reversal, and context isolation"
var searchSource = baseline
let history = newJArray()
history.add(observation(searchSource, 0.8))
let firstStep = adjustOne(searchSource, baseline, history, 50)
history[0]["changes"] = firstStep
doAssert firstStep.len == 1
doAssert firstStep[0]["hero"].getStr == "Crossbowman"
let
  originalTicks = baseline.value(Rules[6].weakness)
  overshotTicks = searchSource.value(Rules[6].weakness)
doAssert overshotTicks > originalTicks
for hero in 0 ..< HeroNames.len:
  doAssert searchSource.value(Rules[hero].strength) ==
    baseline.value(Rules[hero].strength)
  if hero != 6:
    doAssert searchSource.value(Rules[hero].weakness) ==
      baseline.value(Rules[hero].weakness)
history.add(observation(searchSource, 0.2))
let walkback = adjustOne(searchSource, baseline, history, 50)
history[1]["changes"] = walkback
doAssert walkback.len == 1
doAssert walkback[0]["field"].getStr == "attackTicks"
doAssert walkback[0]["method"].getStr == "Walk back overshoot"
doAssert searchSource.value(Rules[6].weakness) ==
  (originalTicks + overshotTicks) div 2
history.add(observation(searchSource, 0.5))
let secondHero = adjustOne(searchSource, baseline, history, 50)
doAssert secondHero.len == 1
doAssert secondHero[0]["hero"].getStr == "Ranger"
history[2]["changes"] = secondHero
history.add(observation(searchSource, 0.5))
history[3]["heroes"].elems[1] = %*{"win_rate": 0.5, "margin95": 0.1}
let thirdHero = adjustOne(searchSource, baseline, history, 50)
doAssert thirdHero.len == 1
doAssert thirdHero[0]["hero"].getStr == "Demon Hunter"
doAssert thirdHero[0]["field"].getStr == "damage"

var independentSource = baseline
independentSource.replaceValue(Rules[6].weakness, overshotTicks)
independentSource.replaceValue(Rules[1].weakness, 1)
let independent = %*[history[0], observation(independentSource, 0.2)]
let unrelated = adjustOne(independentSource, baseline, independent, 50)
doAssert unrelated[0]["method"].getStr == "Expand step"

echo "Testing exhausted Ranger growth and base-HP overshoot"
var fragileSource = baseline
fragileSource.replaceValue(Rules[1].weakness, 1)
let fragileHistory = %*[observation(fragileSource, 0.5)]
let fragileStep = adjustOne(fragileSource, baseline, fragileHistory, 50)
fragileHistory[0]["changes"] = fragileStep
doAssert fragileStep[0]["hero"].getStr == "Ranger"
doAssert fragileStep[0]["field"].getStr == "baseHitPoints"
doAssert fragileSource.value(Rules[1].weakness) == 1
let lowHp = fragileSource.value(RangerFragility)
fragileHistory.add(observation(fragileSource, 0.5))
fragileHistory[1]["heroes"][1]["win_rate"] = %0.2
let fragileWalkback = adjustOne(fragileSource, baseline, fragileHistory, 50)
doAssert fragileWalkback[0]["method"].getStr == "Walk back overshoot"
doAssert fragileWalkback[0]["field"].getStr == "baseHitPoints"
doAssert fragileSource.value(RangerFragility) ==
  (lowHp + baseline.value(RangerFragility)) div 2
echo "Sequential balance tests passed"

echo "Testing every role combination and mirrored role-complete teams"
for gameCount in [100, 200]:
  let complete = roleSchedule(gameCount, 1988)
  var compositions: array[32, int]
  doAssert complete == roleSchedule(gameCount, 1988)
  for index, job in complete.elems:
    doAssert job["seed"].getInt == 1988 + index
    for team in 0 .. 1:
      var roles: set[0 .. 4]
      var mask = 0
      for slot in 0 ..< 5:
        let hero = job["roster"][team * 5 + slot].getInt
        roles.incl(hero mod 5)
        if hero >= 5:
          mask = mask or (1 shl (hero mod 5))
      doAssert roles.card == 5
      if team == 0:
        inc compositions[mask]
    if index mod 2 == 1:
      for slot in 0 ..< 5:
        doAssert job["roster"][5 + MirrorSlots[slot]] ==
          complete[index - 1]["roster"][slot]
  for count in compositions:
    doAssert count in gameCount div 32 .. (gameCount + 31) div 32

echo "Testing farthest-first selection, passing heroes, and delta"
var farSource = baseline
let farHistory = %*[observation(farSource, 0.7)]
farHistory[0]["heroes"][1]["win_rate"] = %0.65
farHistory[0]["heroes"][4]["win_rate"] = %0.1
let farChange = adjustOne(farSource, baseline, farHistory, 50, true)
doAssert farChange.len == 1
doAssert farChange[0]["hero"].getStr == "Demon Hunter"
farHistory[0]["heroes"][4]["margin95"] = %0.4
farSource = baseline
let excludesPass = adjustOne(farSource, baseline, farHistory, 50, true)
doAssert excludesPass[0]["hero"].getStr == "Crossbowman"
for row in summarize(games)["heroes"]:
  doAssert row["delta_pp"].kind == JNull
let originalPolicy = "before\nsub chooseHero()\n  old = 460\nend sub\nafter\n"
let modifiedPolicy = rolePolicy(originalPolicy)
doAssert modifiedPolicy.startsWith("before\nsub chooseHero()")
doAssert modifiedPolicy.endsWith("\nend sub\nafter\n")
doAssert "old = 460" notin modifiedPolicy
doAssert "heroRole(picked) = heroRole(candidate)" in modifiedPolicy
echo "Role draft and farthest-first tests passed"
