import
  std/[base64, json, locks, monotimes, os, osproc, strtabs, strutils, tables,
    tempfiles, times, uri],
  mummy,
  zippy/ziparchives,
  policies
import polyworld/policies as policyPackages

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
    seed*, maxTicks*: int
    roster*: seq[RosterEntry]
  ResolvedPlayer = object
    bytes: string
    canReadLog: bool

const
  SeatCount = 10
  MaxTicks = 28800
  MaxBodyBytes = 224 * 1024 * 1024 # Ten 16 MiB artifacts encoded as base64 plus JSON.
  MaxEncodedPackageBytes = ((policyPackages.MaxPackageBytes + 2) div 3) * 4
  Instructions = staticRead("docs/llms.txt")
  RunGuide = staticRead("docs/run.md")

var
  capacityLock: Lock
  activeRuns: int

initLock(capacityLock)

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

proc parseRun*(body: string): RunInput =
  ## Validates player inputs and seating before allocating a worker.
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError:
    reject(400, "Invalid JSON")
  checkFields(node, ["seed", "roster", "config"])
  result.seed = integer(node, "seed", int32.low.int, int32.high.int)
  result.maxTicks = MaxTicks
  if node.hasKey("config"):
    checkFields(node["config"], ["max_ticks"])
    if node["config"].hasKey("max_ticks"):
      result.maxTicks = integer(node["config"], "max_ticks", 1, MaxTicks)
  if not node.hasKey("roster") or node["roster"].kind != JArray or
      node["roster"].len == 0 or node["roster"].len > SeatCount:
    reject(400, "roster must contain 1–10 entries")
  var pinned: set[0 .. SeatCount - 1]
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
        integer(entry, "slot", -1, SeatCount - 1)
      else: -1
    if slot >= 0:
      if slot in pinned:
        reject(400, "Multiple roster entries pin the same slot")
      pinned.incl slot
    else:
      hasOpenSeatSelector = true
    case field
    of "source":
      result.roster.add RosterEntry(kind: InlineSource, source: value, slot: slot)
    of "package_base64":
      if value.len > MaxEncodedPackageBytes:
        reject(413, "Uploaded package exceeds 16 MiB")
      var bytes: string
      try:
        bytes = decode(value)
      except ValueError:
        reject(400, "package_base64 must be standard padded base64 without whitespace")
      if bytes.len > policyPackages.MaxPackageBytes:
        reject(413, "Uploaded package exceeds 16 MiB")
      if encode(bytes) != value:
        reject(400, "package_base64 must be standard padded base64 without whitespace")
      if not policyPackages.isPackage(bytes):
        reject(400, "package_base64 must encode a ZIP file")
      result.roster.add RosterEntry(kind: UploadedPackage, packageBytes: bytes, slot: slot)
    else:
      result.roster.add RosterEntry(kind: PolicyReference, policyRef: value, slot: slot)
  if pinned.len < SeatCount and not hasOpenSeatSelector:
    reject(400, "Unfilled seats require a roster entry with slot -1")

proc resolvePlayers(input: RunInput): seq[ResolvedPlayer] =
  ## Pins explicit seats and fills the rest from open entries in roster order.
  var
    selected: array[SeatCount, int]
    openEntries: seq[int]
    nextOpen: int
    sources: Table[string, string]
  for slot in 0 ..< SeatCount:
    selected[slot] = -1
  for index, entry in input.roster:
    if entry.slot >= 0:
      selected[entry.slot] = index
    else:
      openEntries.add index
  for slot in 0 ..< SeatCount:
    if selected[slot] < 0:
      selected[slot] = openEntries[nextOpen mod openEntries.len]
      inc nextOpen
    let entry = input.roster[selected[slot]]
    case entry.kind
    of InlineSource:
      result.add ResolvedPlayer(bytes: entry.source, canReadLog: true)
    of UploadedPackage:
      result.add ResolvedPlayer(bytes: entry.packageBytes, canReadLog: true)
    of PolicyReference:
      let reference = entry.policyRef.strip()
      if reference notin sources:
        sources[reference] = fetchPolicyBytes(reference)
      result.add ResolvedPlayer(bytes: sources[reference],
        canReadLog: false)

proc fileUri(path: string): string =
  ## Encodes an absolute staging path for the Coworld file handoff.
  "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")

proc runMatch(input: RunInput): tuple[archive: string, fetchMs, workerMs, zipMs: int64] =
  ## Runs an isolated native game and returns only its replay and player logs.
  let fetchStarted = getMonoTime()
  let players = resolvePlayers(input)
  result.fetchMs = (getMonoTime() - fetchStarted).inMilliseconds
  let directory = createTempDir("fast-xp-", "")
  defer: removeDir(directory)
  var
    environment = newStringTable(modeCaseSensitive)
    config = %*{"seed": input.seed, "max_ticks": input.maxTicks,
      "players": [], "tokens": []}
    seats = %*{"schema": "coworld-player-seats/1", "seats": []}
  # The native worker needs runtime paths, not the API server's credentials.
  for key in ["PATH", "HOME", "TMPDIR", "LD_LIBRARY_PATH", "NIX_LD",
      "NIX_LD_LIBRARY_PATH", "SystemRoot", "WINDIR"]:
    if existsEnv(key):
      environment[key] = getEnv(key)
  for slot, player in players:
    let botPath = directory / "slot-" & $slot & ".policy"
    writeFile(botPath, player.bytes)
    config["players"].add %*{"name": "Player " & $(slot + 1)}
    config["tokens"].add %($slot)
    seats["seats"].add %*{"slot": slot, "file_uri": fileUri(botPath),
      "size_bytes": player.bytes.len,
      "log_uri": fileUri(directory / "slot-" & $slot & ".log")}
  writeFile(directory / "config.json", $config)
  writeFile(directory / "seats.json", $seats)
  for pair in [("COGAME_CONFIG_URI", "config.json"),
      ("COGAME_PLAYER_SEATS_URI", "seats.json"),
      ("COGAME_RESULTS_URI", "results.json"),
      ("COGAME_SAVE_REPLAY_URI", "replay.replay"),
      ("COGAME_PLAYER_FAILURE_URI", "failure.json")]:
    environment[pair[0]] = fileUri(directory / pair[1])
  let worker = getEnv("FAST_XP_GOTA_WORKER", getAppDir() / "gota_worker")
  let workerStarted = getMonoTime()
  var process = startProcess(worker, env = environment, options = {poParentStreams})
  defer: process.close()
  let exitCode = process.waitForExit(120_000)
  result.workerMs = (getMonoTime() - workerStarted).inMilliseconds
  if exitCode == -1:
    process.terminate()
    if process.waitForExit(1000) == -1:
      process.kill()
      discard process.waitForExit()
    reject(504, "Match exceeded the 120-second execution deadline")
  if fileExists(directory / "failure.json"):
    let failure = parseFile(directory / "failure.json")
    let slot = failure["failed_policy_index"].getInt()
    var message = "Policy loading or BASIC compilation failed for slot " & $slot
    if players[slot].canReadLog:
      message.add ": " & readFile(directory / "slot-" & $slot & ".log")
    reject(422, message)
  if exitCode != 0 or not fileExists(directory / "results.json"):
    reject(500, "Game worker failed; inspect the server diagnostics")
  let zipStarted = getMonoTime()
  var entries = initOrderedTable[string, string]()
  entries["replay.replay"] = readFile(directory / "replay.replay")
  for slot, player in players:
    if player.canReadLog:
      entries["logs/slot-" & $slot & ".txt"] =
        readFile(directory / "slot-" & $slot & ".log")
  result.archive = createZipArchive(entries)
  result.zipMs = (getMonoTime() - zipStarted).inMilliseconds

proc handleRequest(request: Request) {.gcsafe.} =
  ## Serves static documentation and synchronous, capacity-limited Gota runs.
  try:
    let methodName = if request.path == "/v1/games/gota/run": "POST" else: "GET"
    if request.path notin ["/healthz", "/docs/llms.txt", "/docs/run.md",
        "/v1/games/gota/run"]:
      reject(404, "Not found")
    if request.httpMethod != methodName:
      request.respond(405, @[("Allow", methodName)], "Method not allowed\n")
      return
    case request.path
    of "/healthz":
      request.respond(200, body = "ok\n")
    of "/docs/llms.txt", "/docs/run.md":
      request.respond(200, @[("Content-Type", "text/plain; charset=utf-8")],
        if request.path == "/docs/llms.txt": Instructions else: RunGuide)
    else:
      let token = getEnv("FAST_XP_TOKEN")
      if token.len > 0 and request.headers["Authorization"] != "Bearer " & token:
        reject(401, "A valid server bearer token is required")
      if request.headers["Content-Type"].split(';')[0].strip().toLowerAscii() !=
          "application/json":
        reject(415, "Content-Type must be application/json")
      let
        started = getMonoTime()
        input = parseRun(request.body)
        capacity = parseInt(getEnv("FAST_XP_WORKERS", "2"))
      withLock capacityLock:
        if activeRuns >= capacity:
          reject(503, "All match workers are busy; retry later")
        inc activeRuns
      defer:
        withLock capacityLock:
          dec activeRuns
      let
        run = runMatch(input)
        elapsed = (getMonoTime() - started).inMilliseconds
      request.respond(200, @[("Content-Type", "application/zip"),
        ("Content-Disposition", "attachment; filename=gota.zip"),
        ("Cache-Control", "no-store"),
        ("Server-Timing", "run;dur=" & $elapsed &
          ", fetch;dur=" & $run.fetchMs & ", worker;dur=" & $run.workerMs &
          ", zip;dur=" & $run.zipMs)], run.archive)
  except RunError as error:
    var headers = @[("Content-Type", "application/json"), ("Cache-Control", "no-store")]
    if error.status == 503:
      headers.add ("Retry-After", "1")
    request.respond(error.status, headers, $(%*{"error": error.msg}))
  except CatchableError:
    stderr.writeLine("Fast XP error: " & getCurrentExceptionMsg())
    request.respond(500, @[("Content-Type", "application/json")],
      "{\"error\":\"Internal server error\"}")

when isMainModule:
  let
    host = getEnv("FAST_XP_HOST", "127.0.0.1")
    port = parseInt(getEnv("FAST_XP_PORT", "8080"))
    capacity = parseInt(getEnv("FAST_XP_WORKERS", "2"))
    worker = getEnv("FAST_XP_GOTA_WORKER", getAppDir() / "gota_worker")
  if port < 1 or port > 65535 or capacity < 1 or capacity > 256:
    raise newException(ValueError, "Invalid FAST_XP_PORT or FAST_XP_WORKERS")
  if host notin ["127.0.0.1", "::1", "localhost"] and getEnv("FAST_XP_TOKEN").len == 0:
    raise newException(ValueError, "Set FAST_XP_TOKEN before binding a non-loopback address")
  if not fileExists(worker):
    raise newException(ValueError, "Build gota_worker first: " & worker)
  let server = newServer(handleRequest, workerThreads = capacity + 2,
    maxBodyLen = MaxBodyBytes)
  echo "Fast XP server listening on http://", host, ":", port
  server.serve(Port(port), host)
