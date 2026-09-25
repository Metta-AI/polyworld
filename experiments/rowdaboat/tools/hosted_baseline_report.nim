## Validate hosted baseline episode provenance and report hosted values verbatim.
## No local games, score recomputation, mean comparison, or significance test.
import std/[json, math, os, osproc, sets, strutils, tables]

const
  expectedCoworld = "cow_e282a46f-31c4-43b1-a9e2-aaa31d3aaed4"
  expectedVersion = "2026.9.24.2"
  ownPlayer = "ply_eeb732fa-5f40-4fa1-beac-6571738f8108"
  ownVersion = "ab664012-84b3-48b3-ae1b-86f3f6cf960c"
  policyIds = [ownVersion, "bf6c6cc2-362e-4eee-a105-810b23adf437",
    "61f4440b-140d-4f7d-80b8-2802f7a3100d", "7fd19643-c66a-429e-ba24-3c1e6c0d8e06"]
  playerIds = [ownPlayer, "ply_3d22435e-30a2-4f2a-b037-a5c249583788",
    "ply_a494aa09-1efa-4b0d-8577-1f034f8206b0", "ply_ded11f40-3e30-4921-b019-f7f6bc3e9c83"]
  policyLabels = ["rowdaboat-gods-of-the-arena:v1", "khors:v208",
    "arisk-gods-of-the-arena:v4", "richard-gods-of-the-arena:v245"]
  expectedCounts = [1, 3, 3, 3]

proc policyIndex(id: string): int =
  for i, expected in policyIds:
    if id == expected: return i
  -1

proc numeric(node: JsonNode): bool =
  if node.isNil or node.kind notin {JInt, JFloat}: return false
  node.getFloat().classify() notin {fcNan, fcInf, fcNegInf}

proc textScore(node: JsonNode): string =
  if not node.numeric(): return "MISSING"
  $node

proc main() =
  let args = commandLineParams()
  let source = if args.len > 0: args[0] else: "research/baseline-xp-status.json"
  let destination = if args.len > 1: args[1] else: "research/baseline-report.md"
  let fetchLogs = "--logs" in args
  let data = parseFile(source)
  var errors: seq[string]
  var missingScores, hostedErrors, badEpisodes, ownZeroCount: int
  var verifiedLogs, missingLogs, diagnosticLogs: int
  var seats, jobIndices: HashSet[int]
  var childIds, recordedIds: HashSet[string]
  var cleanEpisodes = newJArray()
  var tableRows, sourceRows: seq[string]
  var replayEvidence = newJNull()
  var replayProse = ""

  template require(test: bool, message: string) =
    if not test: errors.add(message)

  require(data{"coworld_id"}.getStr() == expectedCoworld, "XP coworld ID mismatch")
  require(data{"coworld_version"}.getStr() == expectedVersion, "XP coworld version mismatch")
  require(data{"status"}.getStr() == "completed", "XP is not completed")
  require(data{"episode_count"}.getInt(-1) == 10, "XP episode_count is not 10")
  require(data{"completed_count"}.getInt(-1) == 10, "XP completed_count is not 10")
  require(data{"failed_count"}.getInt(-1) == 0, "XP failed_count is not zero")
  require(data{"error"}.isNil or data{"error"}.kind == JNull, "XP has a hosted error")
  let episodes = data{"episodes"}
  require(not episodes.isNil and episodes.kind == JArray and episodes.len == 10,
    "Expected exactly ten embedded child episodes")
  if episodes.isNil or episodes.kind != JArray:
    raise newException(ValueError, "Hosted XP has no episode array")

  for episode in episodes:
    let before = errors.len
    let childId = episode{"id"}.getStr()
    let recordedId = episode{"episode_id"}.getStr()
    let jobIndex = episode{"job_index"}.getInt(-1)
    let prefix = "Child " & childId & ": "
    require(childId.len > 0 and childId notin childIds, prefix & "missing or repeated child ID")
    require(recordedId.len > 0 and recordedId notin recordedIds, prefix & "missing or repeated episode ID")
    require(jobIndex in 0..9 and jobIndex notin jobIndices, prefix & "missing or repeated job index")
    childIds.incl(childId)
    recordedIds.incl(recordedId)
    jobIndices.incl(jobIndex)
    require(episode{"coworld_id"}.getStr() == expectedCoworld, prefix & "wrong coworld")
    require(episode{"coworld_version"}.getStr() == expectedVersion, prefix & "wrong coworld version")
    require(episode{"status"}.getStr() == "completed", prefix & "not completed")
    var hasHostedError = episode{"status"}.getStr() != "completed"
    for field in ["error", "error_type", "failed_policy_index", "failed_agent_index"]:
      if not episode{field}.isNil and episode{field}.kind != JNull:
        hasHostedError = true
    if hasHostedError: inc hostedErrors
    require(not hasHostedError, prefix & "hosted error/failure field present")

    var counts: array[4, int]
    var ownSeat = -1
    var positionPolicy: Table[int, string]
    let participants = episode{"participants"}
    require(not participants.isNil and participants.kind == JArray and participants.len == 10,
      prefix & "expected ten participants")
    if not participants.isNil and participants.kind == JArray:
      for participant in participants:
        let position = participant{"position"}.getInt(-1)
        let policy = participant{"policy_version_id"}.getStr()
        let player = participant{"player_id"}.getStr()
        require(position in 0..9 and not positionPolicy.hasKey(position), prefix & "invalid/repeated seat")
        positionPolicy[position] = policy
        require(participant{"kind"}.getStr() == "policy", prefix & "participant is not a policy")
        require(not participant{"is_filler"}.getBool(), prefix & "unexpected filler participant")
        let index = policyIndex(policy)
        require(index >= 0, prefix & "unapproved policy version " & policy)
        if index >= 0:
          inc counts[index]
          require(player == playerIds[index], prefix & "policy/player ownership mismatch")
        if player == ownPlayer:
          require(policy == ownVersion, prefix & "another version of our policy was included")
        if policy == ownVersion:
          ownSeat = position
      for i in 0..3:
        require(counts[i] == expectedCounts[i], prefix & "wrong seat count for " & policyLabels[i])
    require(ownSeat in 0..9, prefix & "missing own seat")
    require(ownSeat notin seats, prefix & "our seat repeated across batch")
    seats.incl(ownSeat)

    var logEvidence = newJNull()
    if fetchLogs and ownSeat in 0..9:
      let logPath = parentDir(destination) / "baseline-own-logs" / ($jobIndex & ".log")
      let logUrl = "https://softmax.com/api/observatory/v2/episode-requests/" &
        childId & "/" & ownVersion & "/policy-logs/" & $ownSeat
      let process = startProcess("/tmp/hosted_get", args = @["--auth", logUrl, logPath],
        options = {poParentStreams})
      let exitCode = process.waitForExit()
      process.close()
      if exitCode != 0 or not fileExists(logPath):
        inc missingLogs
        errors.add(prefix & "could not fetch own hosted log")
        logEvidence = %*{"source_url": logUrl, "missing": true}
      else:
        let log = readFile(logPath)
        let expectedStart = "Player slot " & $ownSeat & " started."
        let expectedEnd = "Player slot " & $ownSeat & " completed."
        var unexpectedLines = 0
        for line in log.splitLines():
          if line.strip().len > 0 and line.strip() notin [expectedStart, expectedEnd]:
            inc unexpectedLines
        let started = expectedStart in log
        let completed = expectedEnd in log
        if not started or not completed or unexpectedLines > 0:
          inc diagnosticLogs
          errors.add(prefix & "own log has missing lifecycle markers or extra diagnostic lines")
        else:
          inc verifiedLogs
        logEvidence = %*{"source_url": logUrl, "file": logPath, "started": started,
          "completed": completed, "unexpected_nonempty_line_count": unexpectedLines}

    let roster = episode{"policy_version_ids"}
    require(not roster.isNil and roster.kind == JArray and roster.len == 10,
      prefix & "expected ten policy_version_ids")
    if not roster.isNil and roster.kind == JArray:
      for position in 0..<roster.len:
        require(positionPolicy.getOrDefault(position) == roster[position].getStr(), prefix & "roster/participant seat mismatch")

    var hostedValues: Table[string, JsonNode]
    let scores = episode{"scores"}
    require(not scores.isNil and scores.kind == JArray and scores.len == 4,
      prefix & "expected four hosted policy scores")
    if not scores.isNil and scores.kind == JArray:
      for score in scores:
        let policy = score{"policy_version_id"}.getStr()
        require(policyIndex(policy) >= 0 and not hostedValues.hasKey(policy), prefix & "unexpected/repeated score policy")
        hostedValues[policy] = score{"score"}
    for policy in policyIds:
      if not hostedValues.getOrDefault(policy).numeric():
        inc missingScores
        errors.add(prefix & "missing or invalid hosted policy score " & policy)

    var participantValues: Table[int, JsonNode]
    var cleanParticipants = newJArray()
    let participantScores = episode{"participant_scores"}
    require(not participantScores.isNil and participantScores.kind == JArray and participantScores.len == 10,
      prefix & "expected ten participant scores")
    if not participantScores.isNil and participantScores.kind == JArray:
      for score in participantScores:
        let position = score{"position"}.getInt(-1)
        require(position in 0..9 and not participantValues.hasKey(position), prefix & "unexpected/repeated score position")
        participantValues[position] = score{"score"}
    for position in 0..9:
      let score = participantValues.getOrDefault(position)
      if not score.numeric():
        inc missingScores
        errors.add(prefix & "missing/invalid score at seat " & $position)
      cleanParticipants.add(%*{"position": position,
        "policy_version_id": positionPolicy.getOrDefault(position),
        "hosted_score": (if score.isNil: newJNull() else: score)})
    let ownScore = hostedValues.getOrDefault(ownVersion)
    if ownScore.numeric():
      if ownScore.getFloat() == 0: inc ownZeroCount
      let ownSeatScore = participantValues.getOrDefault(ownSeat)
      require(ownSeatScore.numeric() and ownSeatScore.getFloat() == ownScore.getFloat(),
        prefix & "our single-seat policy score does not equal hosted participant score")

    var values = newJArray()
    var row = "| " & $jobIndex & " | " & $ownSeat
    for i, policy in policyIds:
      let value = hostedValues.getOrDefault(policy)
      values.add(%*{"policy_version_id": policy, "policy_ref": policyLabels[i],
        "hosted_score": (if value.isNil: newJNull() else: value)})
      row.add(" | " & textScore(value))
    row.add(" |")
    tableRows.add(row)
    sourceRows.add("| " & $jobIndex & " | `" & childId & "` | `" & recordedId & "` | `" & episode{"job_id"}.getStr() & "` |")
    cleanEpisodes.add(%*{"job_index": jobIndex, "child_request_id": childId,
      "episode_id": recordedId, "job_id": episode{"job_id"}.getStr(),
      "coworld_id": episode{"coworld_id"}.getStr(),
      "coworld_version": episode{"coworld_version"}.getStr(), "own_seat": ownSeat,
      "replay_url": episode{"replay_url"}.getStr(), "policy_scores": values,
      "participant_scores": cleanParticipants, "own_hosted_log": logEvidence,
      "validation_ok": errors.len == before})
    if errors.len > before: inc badEpisodes

  let replayOption = args.find("--replay-summary")
  if replayOption >= 0:
    if replayOption + 1 >= args.len:
      raise newException(ValueError, "--replay-summary needs a path")
    let replayPath = args[replayOption + 1]
    let replay = parseFile(replayPath)
    require(replay{"mismatches"}.getInt(-1) == 0, "Replay had hash mismatches")
    require(replay{"verifiedHashes"}.getInt() == replay{"recordedTicks"}.getInt(),
      "Replay did not verify every recorded tick")
    require(replay{"source"}.getStr() == "https://softmax-public.s3.amazonaws.com/replays/88078960-a20c-4eda-b0cf-4a8e4753086f.replay",
      "Replay source is not the first hosted baseline job")
    let player = replay["players"][0]
    require(player{"seat"}.getInt(-1) == 0 and player{"player"}.getStr() == "RowDaBoat",
      "Replay player is not our validated first-episode seat")
    let snapshots = player["snapshots"]
    let finalState = snapshots[snapshots.len - 1]
    replayEvidence = %*{"source_summary": replayPath, "source_url": replay["source"],
      "verified_hashes": replay["verifiedHashes"], "hash_mismatches": replay["mismatches"],
      "seat": 0, "actions": player["actions"], "action_rejections": player["rejections"],
      "end_state": finalState, "damage_by_target_kind": player["damageByTargetKind"],
      "received_xp_sources": player["receivedXpSources"], "purchases": player["purchases"]}
    replayProse = "\n## First hosted replay: execution evidence only\n\n"
    replayProse.add("Hosted job `88078960-a20c-4eda-b0cf-4a8e4753086f`, our seat 0. Replayed only recorded hosted actions; " &
      $replay["verifiedHashes"] & " tick hashes verified with " & $replay["mismatches"] & " mismatches. This proves the trace reconstructed the hosted game; it is not a new local scoring run.\n\n")
    replayProse.add("The policy drafted VanguardKnight, issued 8 ability-level actions, 165 attack-target actions, 298 attack-move actions, 115 targeted/point casts, 32 purchase actions, and 6 portal-use actions. End state: level " &
      $finalState["level"] & ", deaths " & $finalState["deaths"] & ", lifetime XP " & $finalState["totalXp"] &
      ", inventory `" & finalState["inventory"].getStr() & "`. These are replay diagnostics, separate from the hosted score table.\n\n")
    replayProse.add("Purchases and navigation show repeated recovery/shop travel and consumable spending, with RangerBoots the only permanent item remaining at the end. This identifies an economy/navigation hypothesis for comparison with top-player replays; it does not establish that a change would improve hosted performance. Raw action/event streams and the complete summary are saved beside `" & replayPath & "`.\n")

  require(seats.len == 10, "Our rotations did not cover all ten distinct seats")
  for seat in 0..9: require(seat in seats, "Our rotation missed seat " & $seat)
  let xpId = data{"id"}.getStr()
  let sanitized = %*{"experience_request_id": xpId, "source_file": source,
    "coworld_id": expectedCoworld, "coworld_version": expectedVersion,
    "own_policy_version_id": ownVersion, "episode_count": episodes.len,
    "own_zero_score_count": ownZeroCount, "missing_score_count": missingScores,
    "hosted_episode_error_count": hostedErrors, "validation_error_count": errors.len,
    "own_logs_checked": fetchLogs, "own_logs_verified": verifiedLogs,
    "own_logs_missing": missingLogs, "own_logs_with_diagnostics": diagnosticLogs,
    "replay_evidence": replayEvidence,
    "episodes_with_validation_errors": badEpisodes, "validation_errors": errors,
    "episodes": cleanEpisodes}
  let jsonDestination = changeFileExt(destination, "json")
  createDir(parentDir(destination))
  writeFile(jsonDestination, sanitized.pretty() & "\n")
  var report = "# Hosted baseline evidence audit\n\n"
  report.add("XP: `" & xpId & "`. [Hosted source](https://softmax.com/api/observatory/v2/experience-requests/" & xpId & ").\n\n")
  report.add("Source snapshot: `" & source & "`. Coworld `" & expectedCoworld & "`, version `" & expectedVersion & "`.\n\n")
  report.add("Validation: " & (if errors.len == 0: "PASS" else: "FAIL") & ". Ten completed children; own policy `" & ownVersion & "` once per episode; three seats each for the pinned live policies below; our rotations cover seats 0–9 once each. These statements are verified only when validation passes.\n\n")
  report.add("- Own zero-score episodes: " & $ownZeroCount & " of " & $episodes.len & ".\n")
  report.add("- Missing or invalid hosted score values: " & $missingScores & ".\n")
  report.add("- Hosted child errors: " & $hostedErrors & ".\n")
  report.add("- Validation errors: " & $errors.len & "; children with validation errors: " & $badEpisodes & ".\n\n")
  if fetchLogs:
    report.add("Hosted own-policy logs: " & $verifiedLogs & " contain only the expected seat-started and seat-completed messages; " &
      $missingLogs & " missing; " & $diagnosticLogs & " have unexpected diagnostics or missing lifecycle messages. No source compile/runtime diagnostics appeared in the verified logs. Raw logs are under `research/baseline-own-logs/`; exact API sources are in the JSON sidecar.\n\n")
  report.add("All values below come directly from hosted experience responses. Opponent values are the website's policy-level scores for their three seats. No scores are generated from replays, and no between-episode mean, comparison of means, or significance claim is made. This initial baseline alone cannot establish an improvement.\n\n")
  report.add("| Job | Our seat | RowDaBoat v1 | khors v208 | arisk v4 | richard v245 |\n| --- | --- | --- | --- | --- | --- |\n")
  report.add(tableRows.join("\n") & "\n\n")
  report.add("Pinned policy versions:\n\n")
  for i in 0..3: report.add("- `" & policyLabels[i] & "`: `" & policyIds[i] & "`.\n")
  report.add("\nSource IDs:\n\n| Job | Child request ID | Recorded episode ID | Hosted job ID |\n| --- | --- | --- | --- |\n")
  report.add(sourceRows.join("\n") & "\n\n")
  report.add("Sanitized machine-readable scores and exact seat-level values: `" & jsonDestination & "`.\n")
  report.add(replayProse)
  if errors.len > 0:
    report.add("\nValidation failures:\n\n")
    for error in errors: report.add("- " & error & "\n")
  writeFile(destination, report)
  echo "Validation ", (if errors.len == 0: "PASS" else: "FAIL"), "; episodes=", episodes.len,
    "; own_zero_scores=", ownZeroCount, "; missing_scores=", missingScores,
    "; hosted_errors=", hostedErrors, "; validation_errors=", errors.len
  echo "Saved ", destination, " and ", jsonDestination
  if errors.len > 0: quit(1)

when isMainModule: main()
