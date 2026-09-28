## Descriptive hosted-replay strategy profile. Never reads or computes scores.
## Seat identity comes from participants.position, never policy array order.
import std/[os, json, strutils, tables, sets]
if paramCount() != 4:
  quit("Usage: leader_replay_profile <metadata.json> <audit-prefix> <seat> <output.json>", 1)
let metadata = parseFile(paramStr(1))
let episode = if metadata.hasKey("episode"): metadata["episode"] else: metadata
let prefix = paramStr(2)
let seat = parseInt(paramStr(3))
let summary = parseFile(prefix & ".summary.json")
doAssert summary["source"] == episode["replay_url"]
doAssert summary["mismatches"].getInt == 0
doAssert summary["verifiedHashes"] == summary["recordedTicks"]
let player = summary["players"][seat]
var participant: JsonNode
for item in episode["participants"]:
  if item["position"].getInt == seat:
    doAssert participant.isNil
    participant = item
doAssert not participant.isNil
doAssert participant["player_name"] == player["player"]
let heroId = player["heroId"].getInt
var entities = initTable[int, JsonNode]()
var ownBasicHits = initHashSet[int]()
var camps = newJArray()
var campCounts = newJObject()
var firstDamage = newJObject()
var openingOwnNeutralDamage = newJArray()
var openingNeutralDeaths = newJArray()
var respawnTicks = newJArray()
proc bump(node: JsonNode, key: string) = node[key] = %(node{key}.getInt + 1)
for line in lines(prefix & ".events.jsonl"):
  let event = parseJson(line)
  for field in ["actor", "target"]:
    let entity = event[field]
    if entity["id"].getInt != 0 and entity["kind"].getInt != 0:
      entities[entity["id"].getInt] = entity
  if event["kind"].getStr == "EntityRespawned" and
      event["target"]["id"].getInt == heroId:
    respawnTicks.add event["tick"]
  if event["tick"].getInt <= 1400 and event["kind"].getStr == "Death" and
      event["target"]["kind"].getInt == 6:
    openingNeutralDeaths.add %*{"tick": event["tick"],
      "actorId": event["actor"]["id"], "actorKind": event["actor"]["kind"],
      "targetId": event["target"]["id"]}
  if event["actor"]["id"].getInt != heroId: continue
  let kind = event["kind"].getStr
  if kind == "Damage":
    let targetKind = $event["target"]["kind"].getInt
    if not firstDamage.hasKey(targetKind): firstDamage[targetKind] = event
    if event["cause"].getStr == "BasicAttack":
      ownBasicHits.incl(event["tick"].getInt)
    if event["tick"].getInt <= 1400 and targetKind == "6":
      openingOwnNeutralDamage.add event
  elif kind == "CampEngaged":
    campCounts.bump($event["detail"].getInt)
    camps.add %*{"tick": event["tick"], "campIndex": event["detail"],
      "tier": event["target"]["class"], "targetId": event["target"]["id"],
      "heroX": event["actor"]["x"], "heroZ": event["actor"]["z"],
      "campX": event["target"]["x"], "campZ": event["target"]["z"]}
var previousTarget = -1
var changes = newJArray()
var changeKinds = newJObject()
var attackKinds = newJObject()
var walksAfterHit = 0
var otherWalkExamples = newJArray()
for line in lines(prefix & ".actions.jsonl"):
  let action = parseJson(line)
  if action["seat"].getInt != seat: continue
  if action["kind"].getStr == "attackTarget":
    let target = action["first"].getInt
    let targetKind = if entities.hasKey(target): entities[target]["kind"].getInt else: 0
    attackKinds.bump($targetKind)
    if target != previousTarget:
      changeKinds.bump($targetKind)
      if changes.len < 80:
        changes.add %*{"tick": action["tick"], "targetId": target, "targetKind": targetKind}
      previousTarget = target
  elif action["kind"].getStr == "walk":
    if action["tick"].getInt - 1 in ownBasicHits:
      inc walksAfterHit
    elif otherWalkExamples.len < 24:
      otherWalkExamples.add action
let output = %*{"purpose": "Hosted behavior observations only; no score or significance inference.",
  "episodeId": episode["episode_id"], "release": episode["coworld_version"],
  "replayUrl": episode["replay_url"], "verifiedHashes": summary["verifiedHashes"],
  "mismatches": 0, "gameVersion": summary["gameVersion"],
  "allRecordedActionsConsumed": true,
  "actionConsumptionBasis": "replay_audit raises before writing summary unless replayPlayer.finished",
  "seatMapping": "participants.position checked against replay player name; policy_version_ids order unused",
  "seat": seat, "heroId": heroId, "player": participant["player_name"],
  "policy": participant["policy_name"], "version": participant["version"],
  "policyVersionId": participant["policy_version_id"],
  "actionCounts": player["actions"], "damageByTargetKind": player["damageByTargetKind"],
  "lastHitsByTargetKind": player["killTargetKinds"], "purchases": player["purchases"],
  "casts": player["casts"], "firstDamageByTargetKind": firstDamage,
  "openingOwnNeutralDamageThroughTick1400": openingOwnNeutralDamage,
  "allOpeningNeutralDeathsThroughTick1400": openingNeutralDeaths,
  "respawnTicks": respawnTicks,
  "targetCommandCountsByKind": attackKinds, "targetChangesByKind": changeKinds,
  "first80TargetChanges": changes, "campEngagementCounts": campCounts,
  "campEngagements": camps, "walksImmediatelyAfterBasicHit": walksAfterHit,
  "first24OtherWalks": otherWalkExamples}
createDir(paramStr(4).parentDir)
writeFile(paramStr(4), output.pretty & "\n")
echo "seat ", seat, " ", participant["player_name"], " v", participant["version"]
echo "target command kinds ", attackKinds, "; target changes ", changeKinds
echo "walks immediately after own basic hit ", walksAfterHit
echo "camp engagements by camp ", campCounts
echo "profile: ", paramStr(4)
