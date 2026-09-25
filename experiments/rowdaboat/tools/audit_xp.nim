## Validate hosted provenance and emit raw scores; never calculates a keep verdict.
import std/[json, math, os, osproc, sets, strutils, tables]

const ourPlayer = "ply_eeb732fa-5f40-4fa1-beac-6571738f8108"

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

when isMainModule:
  require(paramCount() in 5..6,
    "Usage: audit_xp STATUS REQUEST OPPONENT_SNAPSHOT OWN_VERSION OUTPUT [--logs]")
  let
    status = parseFile(paramStr(1))
    request = parseFile(paramStr(2))
    opponents = parseFile(paramStr(3))
    ownVersion = paramStr(4)
    output = paramStr(5)
    count = request["num_episodes"].getInt
  require(count >= 10 and count mod 10 == 0, "Use complete ten-seat rotations")
  require(opponents.len == 3, "Need exactly three unique other players")
  var policyOwners = {ownVersion: ourPlayer}.toTable
  var opponentPlayers: HashSet[string]
  for p in opponents:
    let owner = p["player_id"].getStr
    let policy = p["policy_version_id"].getStr
    require(owner != ourPlayer and owner notin opponentPlayers, "Repeated or own opponent player")
    require(not policyOwners.hasKey(policy), "Repeated policy version")
    opponentPlayers.incl(owner)
    policyOwners[policy] = owner
  var expected: CountTable[string]
  for seat in request["roster"]:
    require(seat["slot"].getInt == -1, "Unexpected fixed seat")
    let policy = seat["player"]["policy_ref"].getStr
    require(policyOwners.hasKey(policy), "Unapproved requested policy")
    expected.inc(policy)
  require(expected[ownVersion] == 1 and request["roster"].len == 10, "Invalid own seat count")
  for p in opponents:
    require(expected[p["policy_version_id"].getStr] == 3, "Expected three seats per opponent")
  require(status["status"].getStr == "completed", "XP is not complete")
  require(status["episode_count"].getInt == count and status["completed_count"].getInt == count,
    "Episode count mismatch")
  require(status["failed_count"].getInt == 0 and status["episodes"].len == count, "Missing or failed children")
  var seen: HashSet[string]
  var rotations: CountTable[int]
  var zeroScores, cleanLogs: int
  let rows = newJArray()
  for e in status["episodes"]:
    let id = e["id"].getStr
    require(id notin seen, "Duplicate episode")
    seen.incl(id)
    require(e["status"].getStr == "completed", "Child is not complete")
    require(e["coworld_id"] == status["coworld_id"] and
      e["coworld_version"] == status["coworld_version"], "Mixed game releases")
    for key in ["error", "error_type", "failed_policy_index", "failed_agent_index"]:
      require(e{key} == nil or e[key].kind == JNull, "Hosted error: " & key)
    var actual: CountTable[string]
    var positions: HashSet[int]
    var ownSeat = -1
    for p in e["participants"]:
      let
        position = p["position"].getInt
        policy = p["policy_version_id"].getStr
      require(position in 0..9 and position notin positions, "Invalid or repeated seat")
      positions.incl(position)
      require(policyOwners.hasKey(policy), "Unapproved hosted policy")
      require(p["player_id"].getStr == policyOwners[policy], "Wrong policy owner")
      require(e["policy_version_ids"][position].getStr == policy, "Position roster mismatch")
      require(not p{"is_filler"}.getBool, "Unexpected filler")
      actual.inc(policy)
      if policy == ownVersion: ownSeat = position
    require(positions.len == 10 and actual == expected and ownSeat >= 0, "Hosted roster differs")
    rotations.inc(ownSeat)
    var ownScore: JsonNode
    var scored: HashSet[string]
    let values = newJArray()
    for p in e["scores"]:
      let policy = p["policy_version_id"].getStr
      require(policyOwners.hasKey(policy) and policy notin scored, "Invalid score policy")
      require(p["score"].kind in {JFloat, JInt} and
        p["score"].getFloat.classify notin {fcNan, fcInf, fcNegInf}, "Missing score")
      scored.incl(policy)
      values.add p
      if policy == ownVersion: ownScore = p["score"]
    require(scored.len == 4 and ownScore != nil, "Missing policy score")
    var ownSeatScore: JsonNode
    for p in e["participant_scores"]:
      if p["position"].getInt == ownSeat: ownSeatScore = p["score"]
    require(ownSeatScore != nil and ownSeatScore.getFloat == ownScore.getFloat, "Own score mismatch")
    if ownScore.getFloat == 0: inc zeroScores
    if paramCount() == 6 and paramStr(6) == "--logs":
      let path = output & ".logs" / ($e["job_index"].getInt & ".log")
      let url = "https://softmax.com/api/observatory/v2/episode-requests/" & id &
        "/" & ownVersion & "/policy-logs/" & $ownSeat
      let process = startProcess("/tmp/hosted_get", args = @["--auth", url, path], options = {poParentStreams})
      let code = process.waitForExit()
      process.close()
      require(code == 0, "Cannot retrieve own log")
      let log = readFile(path)
      let start = "Player slot " & $ownSeat & " started."
      let finish = "Player slot " & $ownSeat & " completed."
      require(start in log and finish in log, "Incomplete policy lifecycle")
      for line in log.splitLines:
        require(line.strip in ["", start, finish], "Policy log has diagnostics; inspect " & path)
      inc cleanLogs
    rows.add %*{"episode_request_id": id, "episode_id": e["episode_id"],
      "own_seat": ownSeat, "own_hosted_score": ownScore,
      "hosted_policy_scores": values, "replay_url": e["replay_url"]}
  for seat in 0..9: require(rotations[seat] == count div 10, "Unbalanced own seat rotations")
  createDir(output.parentDir)
  writeFile(output, (%*{"xp_id": status["id"], "coworld_id": status["coworld_id"],
    "coworld_version": status["coworld_version"], "own_policy_version_id": ownVersion,
    "episodes": rows, "own_zero_score_count": zeroScores, "clean_policy_logs": cleanLogs,
    "provenance_passed": true, "significance": "Not assessed; dashboard evidence required"}).pretty & "\n")
  echo "Validated ", count, " hosted episodes; own zero scores=", zeroScores,
    "; clean logs=", cleanLogs, ". No mean comparison or keep verdict."
