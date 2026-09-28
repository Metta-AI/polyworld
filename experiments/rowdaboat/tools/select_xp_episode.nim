## Select completed hosted XP metadata by job and candidate, without scores.
## Output is accepted directly by leader_replay_profile.
import std/[os, json, strutils, sets]

if paramCount() != 4:
  quit("Usage: select_xp_episode <xp-status.json> <job-index> <candidate-id> <output.json>", 1)
let status = parseFile(paramStr(1))
let job = parseInt(paramStr(2))
let candidate = paramStr(3)
var episode: JsonNode
for item in status["episodes"]:
  if item["job_index"].getInt == job:
    doAssert episode.isNil, "duplicate job index"
    episode = item
doAssert not episode.isNil, "job not found"
doAssert episode["status"].getStr == "completed", "job not completed"
var participants = newJArray()
var positions = initHashSet[int]()
var seat = -1
for item in episode["participants"]:
  let position = item["position"].getInt
  doAssert position >= 0 and position notin positions
  positions.incl position
  participants.add %*{"position": position, "player_name": item["player_name"],
    "policy_name": item["policy_name"], "version": item["version"],
    "policy_version_id": item["policy_version_id"]}
  if item["policy_version_id"].getStr == candidate:
    doAssert seat == -1, "candidate appears multiple times"
    seat = position
doAssert seat >= 0, "candidate not found"
let output = %*{"purpose": "Hosted replay identity only; no scores.",
  "xpRequestId": status["id"], "id": episode["id"],
  "episode_id": episode["episode_id"], "job_index": job,
  "coworld_version": episode["coworld_version"],
  "replay_url": episode["replay_url"], "participants": participants,
  "candidateId": candidate, "candidateSeat": seat,
  "seatMapping": "Explicit participants.position; policy_version_ids order unused"}
createDir(paramStr(4).parentDir)
writeFile(paramStr(4), output.pretty & "\n")
echo "job ", job, "; candidate seat ", seat, "; replay ", episode["replay_url"]
echo "metadata: ", paramStr(4)
