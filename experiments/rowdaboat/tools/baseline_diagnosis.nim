## Descriptive audit of hosted replay outputs only; no scoring or significance.
import std/[algorithm, json, os, strutils]

proc bump(n: JsonNode, key: string, value = 1) =
  n[key] = %(n{key}.getInt + value)

if paramCount() < 2:
  quit("Usage: baseline_diagnosis metadata <xp-status.json> | player <summary.json> <seat> | timeline <prefix> <seat>", 1)
if paramStr(1) in ["player", "timeline"] and paramCount() != 3:
  quit("The player and timeline modes require a zero-based seat", 1)
case paramStr(1)
of "metadata":
  let j = parseFile(paramStr(2))
  for e in j["episodes"]:
    if e["job_index"].getInt notin [0, 1, 6]: continue
    echo "job=", e["job_index"], " replay=", e["replay_url"]
    for p in e["participants"]:
      echo "seat=", p["position"], " ", p["player_name"], " ", p["policy_name"], ":", p["version"]
of "player":
  let j = parseFile(paramStr(2))
  let seat = paramStr(3).parseInt
  let p = j["players"][seat]
  echo "source=", j["source"], " gameVersion=", j["gameVersion"], " verifiedHashes=", j["verifiedHashes"], " mismatches=", j["mismatches"]
  for key in ["seat", "player", "actions", "rejections", "events", "damageByTargetKind", "damageByCause", "purchases", "levels", "casts", "deaths", "receivedXpSources", "killTargetKinds"]:
    echo key, "=", p[key]
  for snap in p["snapshots"]:
    echo "snapshot=", snap
of "timeline":
  let prefix = paramStr(2)
  let seat = paramStr(3).parseInt
  let summary = parseFile(prefix & ".summary.json")
  if summary["gameVersion"].getInt != 64 or summary["mismatches"].getInt != 0 or
      summary["recordedTicks"].getInt != summary["verifiedHashes"].getInt:
    quit("Require a complete exact-version-64 replay audit with zero mismatches", 1)
  let endTick = summary["recordedTicks"].getInt
  var j = %*{"source": summary["source"], "seat": seat,
    "note": "Descriptive hosted replay mechanism evidence only, no score calculation",
    "goldSpentByItemId": {}, "purchases": [], "deaths": [], "respawns": [],
    "longestXpGaps": [], "basicHitCount": 0, "spellReleaseCount": 0}
  var firstDecision = 0
  for a in summary["players"][seat]["openingActions"]:
    if a["kind"].getStr != "draft":
      firstDecision = a["tick"].getInt
      break
  var xpTicks = @[firstDecision]
  var deadStart = -1
  var deadIntervals: seq[(int,int)]
  var basicTicks: seq[int]
  var spellTicks: seq[int]
  for line in lines(prefix & ".events.jsonl"):
    let e = parseJson(line)
    let tick = e["tick"].getInt
    if e["actor"]["player"].getInt == seat:
      case e["kind"].getStr
      of "GoldSpent":
        j["goldSpentByItemId"].bump($e["detail"].getInt, -e["amount"].getInt)
        j["purchases"].add %*{"tick": tick, "itemId": e["detail"],
          "cost": -e["amount"].getInt, "goldBefore": e["before"], "goldAfter": e["after"]}
      of "Damage":
        if e["cause"].getStr == "BasicAttack":
          j.bump("basicHitCount")
          basicTicks.add tick
      of "SpellReleased":
        j.bump("spellReleaseCount")
        spellTicks.add tick
      else: discard
    if e["target"]["player"].getInt == seat:
      case e["kind"].getStr
      of "XpGained":
        if e["amount"].getInt > 0 and xpTicks[^1] != tick: xpTicks.add tick
      of "Death":
        j["deaths"].add %tick
        deadStart = tick
      of "EntityRespawned":
        j["respawns"].add %tick
        if deadStart >= 0:
          deadIntervals.add (deadStart, tick)
          deadStart = -1
      else: discard
  if deadStart >= 0: deadIntervals.add (deadStart,endTick)
  var deadTicks = 0
  for interval in deadIntervals: deadTicks += interval[1] - interval[0]
  j["deadTicks"] = %deadTicks
  j["recordedTicks"] = %endTick
  if xpTicks[^1] != endTick: xpTicks.add endTick
  var allActions: seq[JsonNode]
  for line in lines(prefix & ".actions.jsonl"):
    let a = parseJson(line)
    if a["seat"].getInt == seat: allActions.add a
  var gaps: seq[JsonNode]
  for i in 1 ..< xpTicks.len:
    let startTick = xpTicks[i-1]
    let stopTick = xpTicks[i]
    var dead = 0
    for interval in deadIntervals:
      dead += max(0, min(stopTick, interval[1]) - max(startTick, interval[0]))
    var gap = %*{"start": startTick, "end": stopTick, "duration": stopTick-startTick,
      "deadTicks": dead, "aliveTicks": stopTick-startTick-dead, "actions": {},
      "firstActions": [], "lastActions": [], "basicHits": 0, "spells": 0}
    for tick in basicTicks:
      if tick > startTick and tick < stopTick: gap.bump("basicHits")
    for tick in spellTicks:
      if tick > startTick and tick < stopTick: gap.bump("spells")
    var gapActions: seq[JsonNode]
    for a in allActions:
      let tick = a["tick"].getInt
      if tick >= startTick and tick < stopTick:
        gap["actions"].bump(a["kind"].getStr)
        gapActions.add a
    for a in gapActions[0 ..< min(3,gapActions.len)]: gap["firstActions"].add a
    for a in gapActions[max(0,gapActions.len-3) ..< gapActions.len]: gap["lastActions"].add a
    gaps.add gap
  gaps.sort(proc(a,b:JsonNode):int = cmp(b["aliveTicks"].getInt,a["aliveTicks"].getInt))
  for gap in gaps[0 ..< min(6,gaps.len)]: j["longestXpGaps"].add gap
  writeFile(prefix & ".diagnosis.json", j.pretty & "\n")
  for key in ["source", "seat", "goldSpentByItemId", "deaths", "respawns", "basicHitCount", "spellReleaseCount", "deadTicks", "recordedTicks"]:
    echo key, "=", j[key]
  for gap in j["longestXpGaps"]:
    echo "gap=", gap["start"], "..", gap["end"], " alive=", gap["aliveTicks"],
      " dead=", gap["deadTicks"], " hits=", gap["basicHits"], " spells=", gap["spells"],
      " actions=", gap["actions"]
else:
  quit("Unknown mode", 1)
