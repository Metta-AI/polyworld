import
  std/[atomics, base64, cpuinfo, deques, json, locks, monotimes, net, os, osproc, strtabs, strutils, tables,
    tempfiles, times, uri, posix],
  crunchy, mummy,
  zippy/ziparchives,
  polyworld/policies as policyPackages,
  ./[policies, metrics, games]

type
  PlayerKind* = enum
    InlineSource, UploadedPackage, PolicyReference
  RosterEntry* = object
    slot*: int
    case kind*: PlayerKind
    of InlineSource:
      source*: string
    of UploadedPackage:
      packageBytes*: string
    of PolicyReference:
      policyRef*: string
  RunInput* = object
    game*: Game
    seed*, maxTicks*, numEpisodes*: int
    roster*: seq[RosterEntry]
  StagedPlayer = object
    path, hash: string
    size: int
    slot: int
    canReadLog: bool
  GameResult = object
    index, seed, status, activeBots: int
    directory, error: string
    queueMs, workerMs, gameplayMs: int64
    roster: seq[int]
  GameJob = object
    requestId, directory: string
    game: Game
    index, seed, maxTicks: int
    queued: MonoTime
    players: seq[StagedPlayer]
    reply: ptr Channel[GameResult]
  SchedulerEvent = object
    jobs: seq[GameJob]
    worker: int
    completed: GameResult
    reply: ptr Channel[GameResult]
    stopping: bool

const
  MaxTicks = 28800
  Dashboard = staticRead("dashboard.html")
  Instructions = staticRead("docs/llms.txt")
  RunGuide = staticRead("docs/run.md")
  PaintbotGuide = staticRead("docs/paintbot-run.md")
  AwmGuide = staticRead("docs/awm-run.md")
  HttpHeadroom = 8
  GameCount = ord(high(Game)) + 1

var
  capacityLock: Lock
  activeRuns: int
  requestLimit: int
  requestSequence: uint64
  logLock: Lock
  stopping: Atomic[bool]
  schedulerEvents: Channel[SchedulerEvent]
  workerJobs: array[256, Channel[GameJob]]
  gameWorkers: array[256, Thread[int]]
  schedulerThread: Thread[int]
  shutdownThread: Thread[Server]
  metricsThread: Thread[void]

initLock(capacityLock)
initLock(logLock)

proc logEvent(event: JsonNode) =
  ## Writes one bounded metadata record, never bot contents or upstream errors.
  withLock logLock:
    stdout.writeLine($event)
    stdout.flushFile()

proc checkFields(node: JsonNode, allowed: openArray[string]) =
  ## Rejects misspelled or unsupported request fields.
  if node.kind != JObject:
    reject(400, "Expected a JSON object")
  for key in node.keys:
    if key notin allowed:
      reject(400, "Unsupported field: " & key)

proc integer(node: JsonNode, key: string, low, high: int): int =
  ## Reads a required integer with explicit bounds.
  if not node.hasKey(key) or node[key].kind != JInt:
    reject(400, key & " must be an integer")
  let value = node[key].getBiggestInt()
  if value < low or value > high:
    reject(400, key & " is out of range")
  int(value)

proc parseRun*(body: string, game = Gota): RunInput =
  ## Validates player inputs and seating before allocating a worker.
  result.game = game
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError:
    reject(400, "Invalid JSON")
  checkFields(node, ["seed", "roster", "config", "num_episodes"])
  result.seed = integer(node, "seed", int32.low.int, int32.high.int)
  result.numEpisodes = if node.hasKey("num_episodes"):
      integer(node, "num_episodes", 1, 10)
    else: 1
  if int64(result.seed) + result.numEpisodes - 1 > int32.high:
    reject(400, "Batch seeds exceed the signed 32-bit range")
  result.maxTicks = defaultTicks(game)
  if node.hasKey("config"):
    checkFields(node["config"], ["max_ticks"])
    if node["config"].hasKey("max_ticks"):
      result.maxTicks = integer(node["config"], "max_ticks", 1, MaxTicks)
  if not node.hasKey("roster") or node["roster"].kind != JArray or
      node["roster"].len == 0 or node["roster"].len > seatCount(game):
    reject(400, "roster exceeds the selected game seat count")
  var pinned: set[0 .. 15]
  var hasOpenSeatSelector = false
  for entry in node["roster"]:
    checkFields(entry, ["player", "slot"])
    if not entry.hasKey("player"):
      reject(400, "Each roster entry requires a player")
    let player = entry["player"]
    checkFields(player, ["source", "package_base64", "policy_ref"])
    if player.len != 1:
      reject(400, "Each player requires exactly one of source, package_base64 or policy_ref")
    let field = if player.hasKey("source"): "source"
      elif player.hasKey("package_base64"): "package_base64"
      else: "policy_ref"
    if player[field].kind != JString:
      reject(400, field & " must be a string")
    let value = player[field].getStr()
    if value.strip().len == 0 or '\0' in value:
      reject(400, field & " must be nonempty and contain no NUL characters")
    let slot = if entry.hasKey("slot"):
        integer(entry, "slot", -1, seatCount(game) - 1)
      else: -1
    if slot >= 0:
      if slot in pinned:
        reject(400, "Multiple roster entries pin the same slot")
      pinned.incl slot
    else:
      hasOpenSeatSelector = true
    case field
    of "source":
      if value.len > sourceLimit(game): reject(413, "BASIC source exceeds the game source limit")
      result.roster.add RosterEntry(kind: InlineSource, source: value, slot: slot)
    of "package_base64":
      if value.len > ((packageLimit(game) + 2) div 3) * 4:
        reject(413, "Uploaded package exceeds the game package limit")
      var bytes: string
      try:
        bytes = decode(value)
      except ValueError:
        reject(400, "package_base64 must be standard padded base64 without whitespace")
      if bytes.len > packageLimit(game):
        reject(413, "Uploaded package exceeds the game package limit")
      if encode(bytes) != value:
        reject(400, "package_base64 must be standard padded base64 without whitespace")
      if not policyPackages.isPackage(bytes):
        reject(400, "package_base64 must encode a ZIP file")
      result.roster.add RosterEntry(kind: UploadedPackage, packageBytes: bytes, slot: slot)
    else:
      result.roster.add RosterEntry(kind: PolicyReference, policyRef: value, slot: slot)
  if pinned.len < seatCount(game) and not hasOpenSeatSelector:
    reject(400, "Unfilled seats require a roster entry with slot -1")

proc stagePlayers(input: RunInput, directory: string): seq[StagedPlayer] =
  ## Fetches and stages each roster entry once for the whole request.
  var sources: Table[string, string]
  for index, entry in input.roster:
    var bytes: string
    case entry.kind
    of InlineSource: bytes = entry.source
    of UploadedPackage: bytes = entry.packageBytes
    of PolicyReference:
      let reference = entry.policyRef.strip()
      if reference notin sources:
        sources[reference] = fetchPolicyBytes(reference, input.game)
      bytes = sources[reference]
    let path = directory / "player-" & $index & ".policy"
    writeFile(path, bytes)
    var hash = "sha256:"
    for value in sha256(bytes): hash.add value.toHex(2).toLowerAscii()
    result.add StagedPlayer(path: path, hash: hash, size: bytes.len, slot: entry.slot,
      canReadLog: entry.kind != PolicyReference)

proc seatPlayers(players: seq[StagedPlayer], index: int, game: Game): seq[int] =
  ## Matches Observatory's per-episode rotation of unpinned entries.
  result = newSeq[int](seatCount(game))
  for slot in 0 ..< seatCount(game): result[slot] = -1
  var openEntries, openSlots: seq[int]
  for i, player in players:
    if player.slot >= 0: result[player.slot] = i
    else: openEntries.add i
  for slot in 0 ..< seatCount(game):
    if result[slot] < 0: openSlots.add slot
  if openSlots.len > 0:
    let shift = index mod openSlots.len
    for i, slot in openSlots:
      let entry = ((i - shift) mod openEntries.len + openEntries.len) mod openEntries.len
      result[slot] = openEntries[entry]

proc fileUri(path: string): string =
  ## Encodes an absolute staging path for the Coworld file handoff.
  "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")

proc waitForGame(process: Process, timeoutMs: int): int =
  ## Observes a deadline without Nim waitForExit's implicit timeout kill.
  let started = getMonoTime()
  while true:
    result = process.peekExitCode()
    if result != -1 or (getMonoTime() - started).inMilliseconds >= timeoutMs:
      return
    sleep(10)

proc collectGame(process: Process, directory: string, timeoutMs: int): int =
  ## Collects completed Coworld outputs before terminating its persistent host.
  let started = getMonoTime()
  while true:
    result = process.peekExitCode()
    if result != -1: return
    let failed = fileExists(directory / "failure.json")
    if failed or (fileExists(directory / "results.json") and fileExists(directory / "replay.replay")):
      discard parseFile(directory / (if failed: "failure.json" else: "results.json"))
      discard posix.kill(-Pid(process.processID), SIGTERM)
      if waitForGame(process, 1000) == -1:
        discard posix.kill(-Pid(process.processID), SIGKILL)
        discard process.waitForExit()
      return 0
    if (getMonoTime() - started).inMilliseconds >= timeoutMs: return -1
    sleep(10)

proc executeGame(job: GameJob): GameResult =
  ## Runs one game; artifacts remain private until its request packages results.
  result = GameResult(index: job.index, seed: job.seed, status: 200,
    directory: job.directory, activeBots: -1, gameplayMs: -1, roster: seatPlayers(job.players, job.index, job.game),
    queueMs: (getMonoTime() - job.queued).inMilliseconds)
  let started = getMonoTime()
  let game = job.game
  try:
    createDir(job.directory)
    var
      environment = newStringTable(modeCaseSensitive)
      config = %*{"seed": job.seed, "max_ticks": job.maxTicks, "players": [], "tokens": []}
      seats = %*{"schema": "coworld-player-seats/1", "seats": [],
        "player_status_uri": fileUri(job.directory / "player-status.json")}
    for key in ["PATH", "HOME", "TMPDIR", "LD_LIBRARY_PATH", "NIX_LD",
        "NIX_LD_LIBRARY_PATH", "SystemRoot", "WINDIR"]:
      if existsEnv(key): environment[key] = getEnv(key)
    environment["TMPDIR"] = job.directory
    for slot, index in result.roster:
      let player = job.players[index]
      config["players"].add %*{"name": "Player " & $(slot + 1)}
      config["tokens"].add %($slot)
      seats["seats"].add %*{"slot": slot, "file_uri": fileUri(player.path),
        "size_bytes": player.size, "content_hash": player.hash,
        "log_uri": fileUri(job.directory / "slot-" & $slot & ".log")}
    if game == Paintbot:
      config["glory"] = %*{"behind_cogs": 10, "behind_lives": 5}
      config["slots"] = newJArray()
      for slot in 0 ..< seatCount(game):
        config["slots"].add %*{"team": (if slot mod 2 == 0: "red" else: "blue")}
      environment["COGAME_ORACLE"] = "off"
      environment["COGAME_TICK_SECONDS"] = "0"
    let socket = newSocket()
    socket.bindAddr(Port(0), "127.0.0.1")
    environment["COGAME_PORT"] = $int(socket.getLocalAddr()[1])
    environment["COGAME_HOST"] = "127.0.0.1"
    socket.close()
    writeFile(job.directory / "config.json", $config)
    writeFile(job.directory / "seats.json", $seats)
    for pair in [("COGAME_CONFIG_URI", "config.json"),
        ("COGAME_PLAYER_SEATS_URI", "seats.json"),
        ("COGAME_RESULTS_URI", "results.json"),
        ("COGAME_SAVE_REPLAY_URI", "replay.replay"),
        ("COGAME_PLAYER_FAILURE_URI", "failure.json")]:
      environment[pair[0]] = fileUri(job.directory / pair[1])
    let command = workerCommand(game)
    # exec preserves the PID for deadlines. Discard public worker chatter without
    # pipe backpressure, interleaved journal lines, or a growing transcript file.
    var process = startProcess("/bin/sh", args = @["-c",
      "exec nice -n 10 \"$@\" >/dev/null 2>&1", "fast-xp-worker", command[0]] & command[1 .. ^1],
      env = environment, options = {poDaemon})
    defer: process.close()
    defer:
      discard posix.kill(-Pid(process.processID), SIGKILL)
    let exitCode = collectGame(process, job.directory, executionSeconds(game) * 1000)
    if exitCode == -1:
      discard posix.kill(-Pid(process.processID), SIGTERM)
      if waitForGame(process, 1000) == -1:
        discard posix.kill(-Pid(process.processID), SIGKILL)
        discard process.waitForExit()
      reject(504, "Match exceeded the " & $executionSeconds(game) & "-second execution deadline")
    if fileExists(job.directory / "failure.json"):
      let failure = parseFile(job.directory / "failure.json")
      let slot = failure["failed_policy_index"].getInt()
      var message = "Policy loading or BASIC compilation failed for slot " & $slot
      if job.players[result.roster[slot]].canReadLog:
        let log = job.directory / "slot-" & $slot & ".log"
        message.add ": " & failure{"message"}.getStr()
        if fileExists(log): message.add "\n" & readFile(log)
      reject(422, message)
    if exitCode != 0 or not fileExists(job.directory / "results.json") or
        not fileExists(job.directory / "replay.replay"):
      reject(500, "Game worker failed")
    if fileExists(job.directory / "player-status.json"):
      result.activeBots = 0
      for player in parseFile(job.directory / "player-status.json")["players"]:
        if player["exit_code"].getInt() == 0: inc result.activeBots
    if fileExists(job.directory / "timings.json"):
      result.gameplayMs = parseFile(job.directory / "timings.json")["gameplay_ms"].getBiggestInt()
  except RunError as error:
    result.status = error.status
    result.error = error.msg
  except CatchableError:
    result.status = 500
    result.error = "Game worker failed"
  result.workerMs = (getMonoTime() - started).inMilliseconds
  gameCompleted(job.requestId, job.index, job.seed, job.maxTicks, result.status,
    result.activeBots, result.queueMs, result.workerMs, gameName(game), seatCount(game))
  logEvent(%*{"event": "game_completed", "request_id": job.requestId,
    "game": gameName(game), "game_index": job.index, "seed": job.seed, "status": result.status,
    "queue_ms": result.queueMs, "worker_ms": result.workerMs,
    "gameplay_ms": result.gameplayMs, "active_bots": result.activeBots})

proc gameWorker(index: int) {.thread.} =
  ## Executes only dispatcher-assigned games, with channel-owned messages.
  while true:
    let job = workerJobs[index].recv()
    if job.reply == nil: break
    let completed = executeGame(job)
    schedulerEvents.send SchedulerEvent(worker: index, completed: completed, reply: job.reply)

proc dispatchGames(capacity: int) {.thread.} =
  ## Shares workers between ready games and rotates batches within each game.
  var batches: array[Game, Deque[Deque[GameJob]]]
  var idle: seq[int]
  var runningGames = newSeq[Game](capacity)
  var runningByGame: array[3, int]
  var nextGame = 0
  var closing = false
  for i in 0 ..< capacity: idle.add i
  while true:
    let event = schedulerEvents.recv()
    if event.stopping: closing = true
    if event.reply != nil:
      event.reply[].send(event.completed)
      dec runningByGame[ord(runningGames[event.worker])]
      idle.add event.worker
    if event.jobs.len > 0:
      var batch: Deque[GameJob]
      for job in event.jobs: batch.addLast job
      batches[event.jobs[0].game].addLast batch
    if closing:
      for game in Game:
        while batches[game].len > 0:
          let batch = batches[game].popFirst()
          for job in batch:
            let elapsed = (getMonoTime() - job.queued).inMilliseconds
            job.reply[].send GameResult(index: job.index, seed: job.seed, status: 503,
              error: "Server shutting down", queueMs: elapsed, gameplayMs: -1,
              roster: seatPlayers(job.players, job.index, job.game))
            gameCompleted(job.requestId, job.index, job.seed, job.maxTicks, 503, -1, elapsed, 0,
              gameName(job.game), seatCount(job.game))
            logEvent(%*{"event": "game_completed", "request_id": job.requestId,
              "game": gameName(job.game), "game_index": job.index, "seed": job.seed, "status": 503,
              "queue_ms": elapsed, "worker_ms": 0})
    while not closing and idle.len > 0:
      var selected = -1
      for offset in 0 ..< GameCount:
        let index = (nextGame + offset) mod GameCount
        if batches[Game(index)].len > 0 and
            (selected < 0 or runningByGame[index] < runningByGame[selected]):
          selected = index
      if selected < 0: break
      nextGame = (selected + 1) mod GameCount
      let game = Game(selected)
      var batch = batches[game].popFirst()
      let job = batch.popFirst()
      let worker = idle.pop()
      runningGames[worker] = job.game
      inc runningByGame[selected]
      workerJobs[worker].send(job)
      if batch.len > 0: batches[game].addLast(batch)
    var queued = 0
    var queuedByGame: array[3, int]
    var oldest = getMonoTime()
    for game in Game:
      for batch in batches[game]:
        queued += batch.len
        queuedByGame[ord(game)] += batch.len
        if batch.len > 0 and batch.peekFirst().queued < oldest: oldest = batch.peekFirst().queued
    schedulerChanged(capacity - idle.len, queued, oldest, runningByGame, queuedByGame)
    # Keep receiving late submissions from already-admitted preparation handlers.
    if closing and idle.len == capacity:
      var admitted: int
      withLock capacityLock: admitted = activeRuns
      if admitted == 0: break
  for i in 0 ..< capacity: workerJobs[i].send(GameJob())

proc collectMetrics() {.thread.} =
  var total, idle: int64
  while not stopping.load():
    sampleHost(total, idle)
    for _ in 0 ..< 50:
      if stopping.load(): return
      sleep(100)

proc shutdownSignal(signal: cint) {.noconv.} =
  ## Defers all shutdown work out of the signal handler.
  stopping.store(true)

proc shutdownMonitor(server: Server) {.thread.} =
  ## Cancels queued games while allowing admitted handlers and running games to drain.
  while not stopping.load(): sleep(50)
  schedulerEvents.send SchedulerEvent(stopping: true)
  while true:
    var admitted: int
    withLock capacityLock: admitted = activeRuns
    if admitted == 0: break
    sleep(20)
  # Mummy closes client sockets before joining handlers. Keep its event loop
  # alive through completion and allow queued responses to leave before close.
  sleep(5000)
  server.close()

proc handleRequest(request: Request) {.gcsafe.} =
  ## Keeps request ownership on the HTTP thread while games run in their own pool.
  let started = getMonoTime()
  var requestId: string
  withLock capacityLock:
    inc requestSequence
    requestId = $getTime().toUnix() & "-" & $getCurrentProcessId() & "-" & $requestSequence
  var httpStatus = 200
  var game = Gota
  var isRun = false
  for candidate in Game:
    if EnabledGames[candidate] and request.path == runPath(candidate):
      game = candidate
      isRun = true
  var episodes = 0
  var preparationMs, packagingMs, responseBytes: int64
  defer:
    if isRun:
      requestCompleted(httpStatus, episodes, (getMonoTime() - started).inMilliseconds,
        preparationMs, packagingMs, responseBytes)
  try:
    let methodName = if isRun: "POST" else: "GET"
    if not isRun and request.path notin ["/", "/v1/metrics", "/healthz", "/docs/llms.txt", "/docs/run.md",
        "/docs/gota/run.md", "/docs/paintbot-pw/run.md", "/docs/awm/run.md"]:
      reject(404, "Not found")
    if request.httpMethod != methodName:
      httpStatus = 405
      request.respond(405, @[("Allow", methodName), ("X-Request-ID", requestId)], "Method not allowed\n")
      return
    case request.path
    of "/":
      request.respond(200, @[("Content-Type", "text/html; charset=utf-8"),
        ("Cache-Control", "no-store")], Dashboard)
    of "/v1/metrics":
      let value = request.queryParams["minutes"]
      if value notin ["", "10", "15", "60", "1440"]: reject(400, "minutes must be 10, 15, 60 or 1440")
      let data = snapshot(if value == "": 60 else: parseInt(value))
      data["games"] = newJArray()
      for candidate in Game:
        if EnabledGames[candidate]: data["games"].add %gameName(candidate)
      data["build_revision"] = %getEnv("FAST_XP_BUILD_REVISION", "local")
      request.respond(200, @[("Content-Type", "application/json"),
        ("Cache-Control", "no-store")], $data)
    of "/healthz": request.respond(200, body = "ok\n")
    of "/docs/llms.txt":
      request.respond(200, @[("Content-Type", "text/plain; charset=utf-8")], Instructions)
    of "/docs/run.md", "/docs/gota/run.md", "/docs/paintbot-pw/run.md", "/docs/awm/run.md":
      var document: string
      let index = request.path == "/docs/run.md"
      for candidate in Game:
        if index or ("/" & gameName(candidate) & "/") in request.path:
          if not EnabledGames[candidate]:
            if not index: reject(404, "Game is not installed")
            continue
          document.add [RunGuide, PaintbotGuide, AwmGuide][candidate.ord] & "\n\n"
      request.respond(200, @[("Content-Type", "text/plain; charset=utf-8")],
        document)
    else:
      let token = getEnv("FAST_XP_TOKEN")
      if token.len > 0 and request.headers["Authorization"] != "Bearer " & token:
        reject(401, "A valid server bearer token is required")
      if request.headers["Content-Type"].split(';')[0].strip().toLowerAscii() != "application/json":
        reject(415, "Content-Type must be application/json")
      withLock capacityLock:
        if stopping.load(): reject(503, "Server shutting down")
        if activeRuns >= requestLimit: reject(429, "Request queue is full; retry later")
        inc activeRuns
        admissionChanged(1)
      defer:
        withLock capacityLock:
          dec activeRuns
          admissionChanged(-1)
        if stopping.load(): schedulerEvents.send SchedulerEvent(stopping: true)
      var input = parseRun(request.body, game)
      request.body = ""
      let count = input.numEpisodes
      episodes = count
      logEvent(%*{"event": "request_accepted", "request_id": requestId,
        "game": gameName(game), "num_episodes": count})
      let directory = createTempDir("fast-xp-", "")
      defer: removeDir(directory)
      let fetchStarted = getMonoTime()
      let players = stagePlayers(input, directory)
      let fetchMs = (getMonoTime() - fetchStarted).inMilliseconds
      preparationMs = fetchMs
      let reply = cast[ptr Channel[GameResult]](allocShared0(sizeof(Channel[GameResult])))
      reply[].open()
      defer:
        reply[].close()
        deallocShared(reply)
      var jobs: seq[GameJob]
      for index in 0 ..< count:
        jobs.add GameJob(game: game, requestId: requestId, index: index, seed: input.seed + index,
          maxTicks: input.maxTicks, players: players, reply: reply,
          queued: getMonoTime(), directory: directory / align($index, 3, '0'))
      input.roster.setLen(0)
      schedulerEvents.send SchedulerEvent(jobs: jobs)
      var results = newSeq[GameResult](count)
      for _ in 0 ..< count:
        let completed = reply[].recv()
        results[completed.index] = completed
      if count == 1 and results[0].status != 200:
        reject(results[0].status, results[0].error)
      let zipStarted = getMonoTime()
      var entries = initOrderedTable[string, string]()
      var manifest = %*{"request_id": requestId, "game": gameName(game), "fetch_ms": fetchMs, "games": []}
      var queueMs, workerMs, gameplayMs: int64
      var hasGameplay = true
      var failures = 0
      for game in results:
        queueMs += game.queueMs
        workerMs += game.workerMs
        if game.gameplayMs >= 0: gameplayMs += game.gameplayMs
        else: hasGameplay = false
        var record = %*{"index": game.index, "seed": game.seed,
          "status": (if game.status == 200: "completed" else: "failed"),
          "http_status": game.status, "roster_entries_by_slot": game.roster,
          "queue_ms": game.queueMs, "worker_ms": game.workerMs,
          "active_bots": game.activeBots, "artifacts": []}
        if game.gameplayMs >= 0: record["gameplay_ms"] = %game.gameplayMs
        if game.status == 200:
          let prefix = if count == 1: "" else: "games/" & align($game.index, 3, '0') & "/"
          let replay = prefix & "replay.replay"
          entries[replay] = readFile(game.directory / "replay.replay")
          record["artifacts"].add %replay
          for slot, index in game.roster:
            if players[index].canReadLog:
              let path = prefix & "logs/slot-" & $slot & ".txt"
              entries[path] = readFile(game.directory / "slot-" & $slot & ".log")
              record["artifacts"].add %path
        else:
          inc failures
          record["error"] = %game.error
        manifest["games"].add record
      if count > 1: entries["manifest.json"] = $manifest
      let archive = createZipArchive(entries)
      let zipMs = (getMonoTime() - zipStarted).inMilliseconds
      packagingMs = zipMs
      responseBytes = archive.len
      let elapsed = (getMonoTime() - started).inMilliseconds
      request.respond(200, @[("Content-Type", "application/zip"),
        ("Content-Disposition", "attachment; filename=" & gameName(game) & ".zip"),
        ("Cache-Control", "no-store"), ("X-Request-ID", requestId),
        ("Server-Timing", "run;dur=" & $elapsed & ", fetch;dur=" & $fetchMs &
          ", queue;dur=" & $queueMs & ", worker;dur=" & $workerMs & ", zip;dur=" & $zipMs &
          (if hasGameplay: ", gameplay;dur=" & $gameplayMs else: ""))], archive)
      logEvent(%*{"event": "request_completed", "request_id": requestId,
        "game": gameName(game),
        "status": 200, "num_episodes": count, "failed_games": failures,
        "fetch_ms": fetchMs, "queue_ms_sum": queueMs, "worker_ms_sum": workerMs,
        "zip_ms": zipMs, "total_ms": elapsed})
  except RunError as error:
    httpStatus = error.status
    var headers = @[("Content-Type", "application/json"), ("Cache-Control", "no-store"),
      ("X-Request-ID", requestId)]
    if error.status in [429, 503]: headers.add ("Retry-After", "5")
    request.respond(error.status, headers, $(%*{"error": error.msg}))
  except CatchableError:
    httpStatus = 500
    request.respond(500, @[("Content-Type", "application/json"), ("X-Request-ID", requestId)],
      "{\"error\":\"Internal server error\"}")
  if httpStatus != 200 and request.path notin ["/", "/v1/metrics"]:
    logEvent(%*{"event": "request_failed", "request_id": requestId, "status": httpStatus,
      "total_ms": (getMonoTime() - started).inMilliseconds})

when isMainModule:
  let
    host = getEnv("FAST_XP_HOST", "127.0.0.1")
    port = parseInt(getEnv("FAST_XP_PORT", "8080"))
    capacity = parseInt(getEnv("FAST_XP_WORKERS", $clamp(cpuinfo.countProcessors(), 1, 256)))
  requestLimit = parseInt(getEnv("FAST_XP_REQUEST_LIMIT", "512"))
  if port < 1 or port > 65535 or capacity < 1 or capacity > 256:
    raise newException(ValueError, "Invalid FAST_XP_PORT or FAST_XP_WORKERS")
  if requestLimit < 1 or requestLimit > 1024:
    raise newException(ValueError, "FAST_XP_REQUEST_LIMIT must be between 1 and 1024")
  if host notin ["127.0.0.1", "::1", "localhost"] and getEnv("FAST_XP_TOKEN").len == 0:
    raise newException(ValueError, "Set FAST_XP_TOKEN before binding a non-loopback address")
  var installed = newJArray()
  for game in Game:
    if EnabledGames[game]:
      installed.add %gameName(game)
      discard executionSeconds(game)
  setCapacity(capacity, requestLimit)
  createThread(metricsThread, collectMetrics)
  schedulerEvents.open()
  for i in 0 ..< capacity:
    workerJobs[i].open()
    createThread(gameWorkers[i], gameWorker, i)
  createThread(schedulerThread, dispatchGames, capacity)
  let server = newServer(handleRequest, workerThreads = requestLimit + HttpHeadroom, maxBodyLen = bodyLimit())
  discard posix.signal(SIGTERM, shutdownSignal)
  discard posix.signal(SIGINT, shutdownSignal)
  createThread(shutdownThread, shutdownMonitor, server)
  logEvent(%*{"event": "server_started", "workers": capacity, "request_limit": requestLimit,
    "games": installed, "build_revision": getEnv("FAST_XP_BUILD_REVISION", "local")})
  server.serve(Port(port), host)
  stopping.store(true)
  schedulerEvents.send SchedulerEvent(stopping: true)
  joinThread(metricsThread)
  joinThread(shutdownThread)
  joinThread(schedulerThread)
  for i in 0 ..< capacity:
    joinThread(gameWorkers[i])
    workerJobs[i].close()
  schedulerEvents.close()
