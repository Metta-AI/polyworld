## Strict mechanism evidence from a verified hosted replay; never scores a game.
import std/[os, json, strutils, tables, sets, sha1]
import ../../../examples/gods_of_the_arena/content

if paramCount() != 6:
  quit("Usage: audit_recovery_sequence <xp-status.json> <job-index> <candidate-id> <audit-prefix> <candidate-commit> <output.json>", 1)
let status = parseFile(paramStr(1))
let jobIndex = parseInt(paramStr(2))
let candidate = paramStr(3)
let prefix = paramStr(4)
var episode: JsonNode
for item in status["episodes"]:
  if item["job_index"].getInt == jobIndex:
    doAssert episode.isNil, "duplicate job index"
    episode = item
doAssert not episode.isNil and episode["status"].getStr == "completed"
var seat = -1
var participant: JsonNode
for item in episode["participants"]:
  if item["policy_version_id"].getStr == candidate:
    doAssert seat < 0, "candidate occupies multiple seats"
    seat = item["position"].getInt
    participant = item
doAssert seat >= 0
doAssert episode["policy_version_ids"][seat].getStr == candidate
let summary = parseFile(prefix & ".summary.json")
doAssert summary["source"].getStr == episode["replay_url"].getStr
doAssert summary["gameVersion"].getInt == 64
doAssert summary["verifiedHashes"].getInt > 0
doAssert summary["verifiedHashes"] == summary["recordedTicks"]
doAssert summary["mismatches"].getInt == 0
let heroId = summary["players"][seat]["heroId"].getInt

var actions = initTable[int, seq[JsonNode]]()
for line in lines(prefix & ".actions.jsonl"):
  let action = parseJson(line)
  if action["seat"].getInt == seat:
    actions.mgetOrPut(action["tick"].getInt, @[]).add action
var hits: seq[JsonNode]
var rejected = initHashSet[string]()
proc rejectionKey(tick, kind: int): string = $tick & ":" & $kind
for line in lines(prefix & ".events.jsonl"):
  let event = parseJson(line)
  if event["actor"]["player"].getInt != seat or
      event["actor"]["id"].getInt != heroId: continue
  if event["kind"].getStr == "ActionRejected":
    rejected.incl(rejectionKey(event["tick"].getInt, event["action"].getInt))
  elif event["kind"].getStr == "Damage" and
      event["cause"].getStr == "BasicAttack" and event["amount"].getInt > 0:
    hits.add event

proc compactHit(event: JsonNode): JsonNode =
  %*{"tick": event["tick"], "actorId": event["actor"]["id"],
    "class": $HeroClass(event["actor"]["class"].getInt),
    "targetId": event["target"]["id"], "targetKind": event["target"]["kind"],
    "damage": event["amount"], "targetHpAfter": event["after"]}

var sequences = newJArray()
var accelerated = 0
var exactCadence = 0
for i, hit in hits:
  let h = hit["tick"].getInt
  let target = hit["target"]["id"].getInt
  if hit["after"].getInt <= 0: continue
  if not actions.hasKey(h + 1) or not actions.hasKey(h + 2): continue
  # The candidate returns immediately after each hook action. Single-action
  # decisions distinguish this fingerprint from an incidental ordinary turn.
  if actions[h + 1].len != 1 or actions[h + 2].len != 1: continue
  let walk = actions[h + 1][0]
  let attack = actions[h + 2][0]
  if walk["kind"].getStr != "walk" or attack["kind"].getStr != "attackTarget": continue
  if attack["first"].getInt != target: continue
  if rejectionKey(h + 1, 1) in rejected or rejectionKey(h + 2, 2) in rejected: continue
  let period = heroAttackTicks(HeroClass(hit["actor"]["class"].getInt)).int
  let expected = period * 45 div 100 + 1
  var second = newJNull()
  var gap = 0
  if i + 1 < hits.len and hits[i + 1]["target"]["id"].getInt == target:
    second = compactHit(hits[i + 1])
    gap = hits[i + 1]["tick"].getInt - h
  let faster = gap > 0 and gap < period
  if faster: inc accelerated
  if gap == expected: inc exactCadence
  sequences.add %*{"firstHit": compactHit(hit), "acceptedWalk": walk,
    "acceptedSameTargetReattack": attack, "noRejectionForEitherAction": true,
    "nativeAttackPeriodTicks": period, "expectedResetIntervalTicks": expected,
    "nextSameTargetHit": second, "observedIntervalTicks": gap,
    "accelerated": faster, "exactResetCadence": gap == expected}

var roster = newJArray()
for item in episode["participants"]:
  roster.add %*{"seat": item["position"], "player": item["player_name"],
    "policy": item["policy_name"], "version": item["version"],
    "policyVersionId": item["policy_version_id"]}
let receipt = %*{
  "purpose": "Hosted replay behavior proof only; no game score, XP delta, or significance claim.",
  "xpRequestId": status["id"], "episodeRequestId": episode["id"],
  "episodeId": episode["episode_id"], "jobIndex": jobIndex,
  "coworldVersion": episode["coworld_version"], "replayGameVersion": summary["gameVersion"],
  "replayUrl": episode["replay_url"], "replaySha1": $secureHashFile(prefix & ".replay"),
  "verifiedHashes": summary["verifiedHashes"], "hashMismatches": 0,
  "allRecordedActionsConsumed": true,
  "candidate": {"policyVersionId": candidate, "policyVersion": participant["version"],
    "policy": participant["policy_name"], "player": participant["player_name"],
    "seat": seat, "heroId": heroId, "commit": paramStr(5)},
  "roster": roster, "successfulBasicHits": hits.len,
  "strictFreshHitWalkSameTargetReattackSequences": sequences.len,
  "acceleratedNextSameTargetHits": accelerated, "exactResetCadenceNextHits": exactCadence,
  "sequences": sequences}
createDir(paramStr(6).parentDir)
writeFile(paramStr(6), receipt.pretty & "\n")
echo "candidate seat ", seat, "; basic hits ", hits.len, "; strict hook sequences ",
  sequences.len, "; accelerated next hits ", accelerated, "; exact cadence ", exactCadence
echo "Sanitized mechanism receipt: ", paramStr(6)
