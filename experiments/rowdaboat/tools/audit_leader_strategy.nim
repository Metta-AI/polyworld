## Descriptive equipment/farming evidence from an already-verified hosted replay.
## Never computes game scores, comparisons, or statistical significance.
import std/[json, os, strutils, tables]

if paramCount() != 4:
  quit("Usage: audit_leader_strategy <prefix> <latest-replay-metadata.json> <comma-separated-seats> <output.json>", 1)
let prefix = paramStr(1)
let summary = parseFile(prefix & ".summary.json")
let meta = parseFile(paramStr(2))
let episode = meta["episode"]
doAssert summary["gameVersion"].getInt == 64
doAssert summary["mismatches"].getInt == 0
doAssert summary["verifiedHashes"].getInt == summary["recordedTicks"].getInt
doAssert summary["source"].getStr == episode["replay_url"].getStr
let endTick = summary["recordedTicks"].getInt
var selected = initTable[int, JsonNode]()
var heroes = initTable[int, int]()
var entities = initTable[int, JsonNode]()
var campById = initTable[int, int]()
var previousTargets = initTable[int, int]()
for seatText in paramStr(3).split(','):
  let seat = seatText.parseInt
  let p = summary["players"][seat]
  var identity: JsonNode
  for row in episode["participants"]:
    if row["position"].getInt == seat:
      doAssert identity.isNil, "Duplicate metadata position"
      identity = row
  doAssert not identity.isNil, "Missing participant position"
  doAssert p["seat"].getInt == seat
  heroes[seat] = p["heroId"].getInt
  selected[seat] = %*{"seat": seat, "heroId": heroes[seat],
    "player": identity["player_name"], "replayPlayer": p["player"],
    "policy": identity["policy_name"], "version": identity["version"],
    "policyVersionId": identity["policy_version_id"], "team": p["team"],
    "class": p["snapshots"][^1]["class"], "actions": p["actions"],
    "rejections": p["rejections"], "purchases": [], "goldSpentByItem": {},
    "campEngagements": [], "portals": p["portals"], "deaths": [],
    "respawns": [], "snapshots": [], "minuteBins": {}, "openingActions": [],
    "damageByTargetKind": {}, "lastHitsByTargetKind": {}, "basicHits": 0,
    "casts": p["casts"], "levels": p["levels"], "healingReceived": p["healingReceived"],
    "attackTransitions": [], "killTimeline": []}
  for s in p["snapshots"]:
    var snap = s.copy
    snap.delete("totalXp")
    selected[seat]["snapshots"].add snap

proc bump(n: JsonNode, key: string, amount = 1) =
  n[key] = %(n{key}.getInt + amount)

for line in lines(prefix & ".events.jsonl"):
  let e = parseJson(line)
  let actorSeat = e["actor"]["player"].getInt
  let targetSeat = e["target"]["player"].getInt
  let tick = e["tick"].getInt
  for field in ["actor", "target"]:
    let entity = e[field]
    let id = entity["id"].getInt
    if id > 0 and not entities.hasKey(id): entities[id] = entity
  if e["kind"].getStr == "CampEngaged":
    campById[e["target"]["id"].getInt] = e["detail"].getInt
  if selected.hasKey(actorSeat) and e["actor"]["id"].getInt == heroes[actorSeat]:
    let p = selected[actorSeat]
    let binKey = $(tick div (24 * 60))
    if not p["minuteBins"].hasKey(binKey):
      p["minuteBins"][binKey] = %*{"startTick": tick div 1440 * 1440,
        "damageByTargetKind": {}, "lastHitsByTargetKind": {}, "basicHits": 0,
        "spellReleases": 0, "campEngagements": []}
    let bin = p["minuteBins"][binKey]
    case e["kind"].getStr
    of "GoldSpent":
      p["goldSpentByItem"].bump($e["detail"].getInt, -e["amount"].getInt)
      p["purchases"].add %*{"tick": tick, "itemId": e["detail"],
        "cost": -e["amount"].getInt, "goldBefore": e["before"],
        "goldAfter": e["after"], "cause": e["cause"]}
    of "Damage":
      if e["amount"].getInt > 0:
        let kind = $e["target"]["kind"].getInt
        p["damageByTargetKind"].bump(kind, e["amount"].getInt)
        bin["damageByTargetKind"].bump(kind, e["amount"].getInt)
        if e["cause"].getStr == "BasicAttack":
          p.bump("basicHits")
          bin.bump("basicHits")
    of "Death":
      let kind = $e["target"]["kind"].getInt
      p["lastHitsByTargetKind"].bump(kind)
      bin["lastHitsByTargetKind"].bump(kind)
      p["killTimeline"].add %*{"tick": tick, "targetId": e["target"]["id"],
        "kind": e["target"]["kind"], "tierOrClass": e["target"]["class"],
        "heroX": e["actor"]["x"], "heroZ": e["actor"]["z"],
        "targetX": e["target"]["x"], "targetZ": e["target"]["z"]}
    of "SpellReleased": bin.bump("spellReleases")
    of "CampEngaged":
      let detail = %*{"tick": tick, "camp": e["detail"], "targetId": e["target"]["id"],
        "heroX": e["actor"]["x"], "heroZ": e["actor"]["z"]}
      p["campEngagements"].add detail
      bin["campEngagements"].add detail
    else: discard
  if selected.hasKey(targetSeat) and e["target"]["id"].getInt == heroes[targetSeat]:
    let p = selected[targetSeat]
    if e["kind"].getStr == "Death": p["deaths"].add %tick
    if e["kind"].getStr == "EntityRespawned": p["respawns"].add %tick

for line in lines(prefix & ".actions.jsonl"):
  let a = parseJson(line)
  let seat = a["seat"].getInt
  if selected.hasKey(seat) and selected[seat]["openingActions"].len < 60:
    selected[seat]["openingActions"].add a
  if selected.hasKey(seat) and a["kind"].getStr == "attackTarget":
    let target = a["first"].getInt
    if previousTargets.getOrDefault(seat) != target:
      previousTargets[seat] = target
      var transition = %*{"tick": a["tick"], "targetId": target}
      if entities.hasKey(target):
        transition["targetKind"] = entities[target]["kind"]
        transition["tierOrClass"] = entities[target]["class"]
        transition["initialTargetX"] = entities[target]["x"]
        transition["initialTargetZ"] = entities[target]["z"]
      if campById.hasKey(target): transition["camp"] = %campById[target]
      selected[seat]["attackTransitions"].add transition

var output = %*{"purpose": "Hosted league replay strategy evidence only; no game scores or significance.",
  "episodeId": episode["episode_id"], "round": meta["round"]["round_number"],
  "source": summary["source"], "coworldVersion": episode["coworld_version"],
  "gameVersion": summary["gameVersion"], "verifiedHashes": summary["verifiedHashes"],
  "mismatches": summary["mismatches"], "players": []}
for seatText in paramStr(3).split(','):
  let p = selected[seatText.parseInt]
  output["players"].add p
  echo p["player"], " seat=", p["seat"], " class=", p["class"], " basicHits=", p["basicHits"]
  echo "goldSpent=", p["goldSpentByItem"], " lastHits=", p["lastHitsByTargetKind"]
  echo "early target changes (before tick6000):"
  for a in p["attackTransitions"]:
    if a["tick"].getInt < 6000: echo a
  echo "early kills (before tick4000):"
  for k in p["killTimeline"]:
    if k["tick"].getInt < 4000: echo k
writeFile(paramStr(4), output.pretty & "\n")
