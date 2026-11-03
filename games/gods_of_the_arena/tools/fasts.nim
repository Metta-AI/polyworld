import
  std/[json, math, options, os, osproc, random, streams, strutils, times],
  curly, zippy/ziparchives,
  tournaments, reports

const FastServer* = "https://fast-xp-k8s-staging.tail0f4a29.ts.net"

proc shutdownResponse*(status: int, body: string): bool =
  ## Recognizes an explicit shutdown rejection rather than an unknown timeout.
  if status != 503:
    return false
  try:
    result = tournaments.parseJson(body){"error"}.getStr ==
      "Server shutting down"
  except TournamentError:
    result = false

proc shutdownRecord*(record: JsonNode): bool =
  ## Recognizes saved shutdown failures from both old and current runners.
  if record{"attempts"} == nil or record["attempts"].len == 0:
    return false
  let attempt = record["attempts"][record["attempts"].len - 1]
  var body = attempt{"response_body"}.getStr
  if body.len == 0 and record{"error"}.getStr.startsWith("HTTP 503: "):
    body = record["error"].getStr[10 .. ^1]
  shutdownResponse(attempt{"http_status"}.getInt, body)

proc validateFastVersion*(run, attempt: JsonNode) =
  ## Pins the game version and records revisions; replay hashes verify behavior.
  require(attempt{"game_version"} == run["release"]["version"],
    "Fast XP returned a different game version")
  require(attempt{"game_revision"}.getStr.len > 0,
    "Fast XP response has no game revision")

proc fastBody*(run, game: JsonNode): JsonNode =
  ## Pins each shuffled policy seat and the accepted game release explicitly.
  result = %*{
    "game_version": run["release"]["version"],
    "seed": game["seed"], "num_episodes": 1, "roster": [],
    "config": {"max_ticks": run["game_config"]["max_ticks"]}
  }
  for slot, policy in game["seats"].elems:
    result["roster"].add %*{
      "slot": slot,
      "player": {"policy_ref": run["roster"][policy.getInt]["id"]}
    }

proc retrySeconds*(value: string, current: Time): float64 =
  ## Accepts the documented numeric and HTTP-date Retry-After formats.
  if value.len == 0:
    return 0
  try:
    return max(0.0, parseFloat(value))
  except ValueError:
    try:
      let deadline = parseTime(value, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc())
      return max(0.0, (deadline - current).inMilliseconds.float64 / 1000)
    except TimeParseError:
      raise newException(TournamentError, "Invalid Retry-After header")

proc fastReplay(directory: string, run, game, record: JsonNode,
    controls: Controls): tuple[replay, output: string] =
  ## Extracts a durable response after checking its pinned release metadata.
  let
    id = game["id"].getStr
    path = directory / "responses" / (id & ".zip")
  let attempt = record["attempts"][record["attempts"].len - 1]
  validateFastVersion(run, attempt)
  let
    archive = openZipArchive(path)
    replay = directory / "replays" / (id & ".replay")
    output = directory / "replays" / (id & "-verified.json")
  try:
    saveBytes(replay, archive.extractFile("replay.replay"), controls)
  finally:
    archive.close()
  (replay, output)

proc startFastInspection*(directory: string, run, game, record: JsonNode,
    controls: Controls): Process =
  ## Starts the preserved release verifier without blocking HTTP admissions.
  let paths = fastReplay(directory, run, game, record, controls)
  require(fileExists(controls.statsWorker), "Missing Fast XP replay inspector")
  startProcess(
    controls.statsWorker,
    args = [paths.replay, directory / "run.json", game["id"].getStr,
      paths.output],
    options = {poStdErrToStdOut}
  )

proc ingestFast*(directory: string, run, game, record: JsonNode,
    controls: Controls) =
  ## Rebuilds a result from a durable ZIP without submitting another request.
  if record["state"].getStr == "completed":
    return
  let id = game["id"].getStr
  if not fileExists(directory / "responses" / (id & ".zip")):
    return
  let (replay, output) = fastReplay(directory, run, game, record, controls)
  if not fileExists(output):
    require(fileExists(controls.statsWorker), "Missing Fast XP replay inspector")
    let response = execCmdEx(
      quoteShell(controls.statsWorker) & " " & quoteShell(replay) & " " &
      quoteShell(directory / "run.json") & " " & quoteShell(id) & " " &
      quoteShell(output)
    )
    require(response.exitCode == 0, "Fast XP inspection: " & response.output)
  let verified = readJson(output)
  validateResult(verified["result"], game, run)
  validatePlayerStats(verified["player_stats"], verified["result"], game, run)
  for slot in 0 ..< 10:
    if verified["result"].seatWin(slot) == 0:
      require(verified["result"]["scores"][slot].getFloat == 0,
        "A losing hero received Glory")
  record["result"] = verified["result"]
  record["player_stats"] = verified["player_stats"]
  record["state"] = %"completed"
  record["completed"] = %tournaments.now()
  record["replay"] = %("replays/" & id & ".replay")
  if record.hasKey("error"):
    record.delete("error")
  saveRecord(directory, record, controls)

proc executeFast*(directory: string, run: JsonNode, dataRoot: string,
    controls: Controls, stopAfter = 0): int =
  ## Drains admitted requests on pause and never blindly repeats a lost response.
  require(controls.concurrency in 1 .. 16,
    "Fast XP concurrency must be between 1 and 16")
  var
    records = loadRecords(directory, run)
    active = 0
    limit = controls.concurrency
    completed = 0
    halt = false
    message = ""
    rng = initRand(getTime().toUnix)
    nextTry = newSeq[float64](records.len)
    admitAfter = 0.0
    waiting: seq[int]
    inspections: seq[tuple[index: int, process: Process]]
  let http = newCurly(maxInFlight = controls.concurrency)
  defer:
    http.close()
    for inspection in inspections:
      discard inspection.process.waitForExit()
      inspection.process.close()
  for i, record in records:
    ingestFast(directory, run, run["schedule"][i], record, controls)
    if record["state"].getStr == "completed":
      inc completed
    elif record["state"].getStr in ["submitting", "running"]:
      raise newException(TournamentError,
        "Uncertain Fast XP response for " & record["id"].getStr &
        ". Preserve the attempt; it cannot be recovered from the server.")
    elif record["state"].getStr == "failed":
      require(controls.retryFailed and
        (not record{"uncertain"}.getBool or shutdownRecord(record)),
        "Inspect failed game " & record["id"].getStr & " before retrying")
      if shutdownRecord(record):
        let attempt = record["attempts"][record["attempts"].len - 1]
        if attempt{"response_body"}.getStr.len == 0:
          attempt["response_body"] = %record["error"].getStr[10 .. ^1]
        attempt["retry_reason"] = %"Explicit shutdown failure; retry requested"
      record["state"] = %"planned"
      record["uncertain"] = %false
      saveRecord(directory, record, controls)
    elif record["state"].getStr == "pending":
      nextTry[i] = record{"retry_not_before"}.getFloat
      admitAfter = max(admitAfter, nextTry[i])
  publish(directory, run, records, "running", dataRoot, controls = controls)
  while true:
    var changed = false
    for j in countdown(inspections.high, 0):
      let
        inspection = inspections[j]
        code = inspection.process.peekExitCode()
      if code == -1:
        continue
      let
        i = inspection.index
        record = records[i]
        id = record["id"].getStr
      try:
        require(code == 0,
          "Fast XP inspection: " & inspection.process.outputStream.readAll())
        require(fileExists(directory / "replays" / (id & "-verified.json")),
          "Fast XP inspector returned no verified result")
        ingestFast(directory, run, run["schedule"][i], record, controls)
        inc completed
      except CatchableError as error:
        record["error"] = %error.msg
        record["state"] = %"failed"
        saveRecord(directory, record, controls)
        halt = true
        message = "Saved response needs inspection: " & error.msg
      finally:
        inspection.process.close()
        inspections.delete(j)
      changed = true
    if stopAfter > 0 and completed >= stopAfter:
      stopping = true
    while true:
      let received = http.pollForResponse()
      if received.isNone:
        break
      dec active
      let
        response = received.get.response
        i = parseInt(response.request.tag)
        record = records[i]
        attempt = record["attempts"][record["attempts"].len - 1]
        id = record["id"].getStr
      attempt["received"] = %tournaments.now()
      attempt["http_status"] = %response.code
      attempt["request_id"] = %response.headers["X-Request-ID"]
      attempt["server_timing"] = %response.headers["Server-Timing"]
      if received.get.error.len > 0:
        record["state"] = %"failed"
        record["uncertain"] = %true
        record["error"] = %received.get.error
        halt = true
        message = "A Fast XP connection failed; no automatic replacement."
        saveRecord(directory, record, controls)
      elif response.code == 429 or
        shutdownResponse(response.code, response.body):
          limit = max(1, limit div 2)
          let
            retries = record{"rejections"}.getInt + 1
            minimum = if response.code == 503: 5.0 else: 0.0
            delay = max(minimum,
              retrySeconds(response.headers["Retry-After"], getTime())) +
              rng.rand(min(30.0, pow(2.0, min(retries - 1, 5).float64)))
          attempt["response_body"] = %response.body
          record["rejections"] = %retries
          record["state"] = %"pending"
          nextTry[i] = epochTime() + delay
          record["retry_not_before"] = %nextTry[i]
          admitAfter = max(admitAfter, nextTry[i])
          saveRecord(directory, record, controls)
      elif response.code == 200:
        try:
          attempt["game_version"] = %response.headers["X-Fast-XP-Game-Version"]
          attempt["game_revision"] = %response.headers["X-Fast-XP-Game-Revision"]
          saveRecord(directory, record, controls)
          saveBytes(directory / "responses" / (id & ".zip"), response.body)
          waiting.add(i)
        except CatchableError as error:
          record["error"] = %error.msg
          record["state"] = %"failed"
          saveRecord(directory, record, controls)
          halt = true
          message = "Saved response needs inspection: " & error.msg
      else:
        attempt["response_body"] = %response.body[0 ..< min(2000,
          response.body.len)]
        record["state"] = %"failed"
        record["error"] = %("HTTP " & $response.code & ": " &
          response.body[0 ..< min(2000, response.body.len)])
        record["uncertain"] = %(response.code >= 500)
        saveRecord(directory, record, controls)
        halt = true
        message = record["error"].getStr
      changed = true
    while waiting.len > 0 and inspections.len < min(4, controls.concurrency):
      let
        i = waiting[0]
        record = records[i]
      waiting.delete(0)
      try:
        inspections.add((i, startFastInspection(
          directory, run, run["schedule"][i], record, controls
        )))
      except CatchableError as error:
        record["error"] = %error.msg
        record["state"] = %"failed"
        saveRecord(directory, record, controls)
        halt = true
        message = "Saved response needs inspection: " & error.msg
        changed = true
    if stopAfter > 0 and completed >= stopAfter:
      stopping = true
    if active == 0 and waiting.len == 0 and inspections.len == 0 and
      (halt or stopping or completed == records.len):
        break
    if not stopping and not halt and epochTime() >= admitAfter:
      for i, record in records:
        let outstanding = active + waiting.len + inspections.len
        if active >= limit or
          outstanding >= controls.concurrency * 2 or
          (stopAfter > 0 and outstanding + completed >= stopAfter):
            break
        if record["state"].getStr notin ["planned", "pending"] or
          epochTime() < nextTry[i]:
            continue
        let body = fastBody(run, run["schedule"][i])
        if record["state"].getStr == "pending":
          require(record["attempts"][record["attempts"].len - 1]["body"] == body,
            "Rejected request payload changed")
          require(record["rejections"].getInt < 100,
            "Fast XP rejection retry budget exhausted")
        record["attempts"].add %*{"created": tournaments.now(), "body": body}
        record["state"] = %"running"
        saveRecord(directory, record, controls)
        http.startRequest(
          "POST",
          run["fast_server"].getStr & "/v1/games/gota/run",
          @[("Content-Type", "application/json")],
          $body,
          timeout = 3600,
          tag = $i
        )
        inc active
        changed = true
    if changed:
      publish(directory, run, records, "running", dataRoot,
        message, controls)
    sleep(250)
  let status = if completed == records.len: "completed"
    elif halt: "failed" else: "paused"
  publish(directory, run, records, status, dataRoot, message, controls)
  if status == "completed": 0 elif halt: 1 else: 130
