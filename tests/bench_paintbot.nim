import
  std/[base64, json, monotimes, os, osproc, parseopt, sequtils, strtabs, strutils, tables, times],
  crunchy, curly,
  ./fastxpfixtures

const PaintbotRoot = currentSourcePath().parentDir.parentDir.parentDir / "paintbot-pw"

proc digest(data: string): string =
  ## Identifies exact replay bytes across hosts and repeated requests.
  for value in sha256(data): result.add value.toHex(2).toLowerAscii()

proc main() =
  ## Compares direct native execution with complete HTTP requests.
  var output, url, package, reference: string
  var ticks = 14400
  for kind, key, value in getopt():
    case key
    of "output": output = value
    of "url": url = value
    of "package": package = value
    of "opponent": reference = value
    of "ticks": ticks = parseInt(value)
    else: raise newException(ValueError, "Unknown option: " & key)
  doAssert output.len > 0 and not dirExists(output), "Use --output:NEW_DIRECTORY"
  let root = absolutePath(output)
  createDir(root)
  setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
  let source = readFile(PaintbotRoot / "examples/paintbot/players/base.bas")
  let player = if package.len > 0: %*{"package_base64": encode(readFile(package))}
    else: %*{"source": source}
  var roster = %*[ {"player": player} ]
  if reference.len > 0:
    roster = %*[{"slot": 0, "player": player}, {"player": {"policy_ref": reference}}]
  let body = %*{"seed": 2026, "config": {"max_ticks": ticks}, "roster": roster}
  writeFile(root / "request.json", $body)
  var server: Process
  if url.len == 0:
    let port = unusedPort()
    url = "http://127.0.0.1:" & $port
    let env = environment(root, port)
    env["FAST_XP_GAME"] = "paintbot-pw"
    env["FAST_XP_PAINTBOT_WORKER"] = PaintbotRoot / "coworld/paintbot/paintbot_worker"
    server = launch(ServerPath, root / "server.log", env)
    waitUntil(records(root / "server.log").anyIt(it["event"].getStr == "server_started"), server, root / "server.log")
  defer:
    if server != nil: stop(server)
  var rows = newJArray()
  var expected: string
  if reference.len == 0 and server != nil:
    let directory = root / "direct"
    createDir(directory)
    let policy = directory / "player.policy"
    writeFile(policy, if package.len > 0: readFile(package) else: source)
    var config = %*{"seed": 2026, "max_ticks": ticks,
      "glory": {"behind_cogs": 10, "behind_lives": 5}, "players": [], "tokens": [], "slots": []}
    var seats = %*{"schema": "coworld-player-seats/1", "seats": [],
      "player_status_uri": "file://" & directory / "player-status.json"}
    for slot in 0 ..< 16:
      config["players"].add %*{"name": "Player " & $(slot + 1)}
      config["tokens"].add %($slot)
      config["slots"].add %*{"team": (if slot mod 2 == 0: "red" else: "blue")}
      seats["seats"].add %*{"slot": slot, "file_uri": "file://" & policy,
        "size_bytes": getFileSize(policy), "log_uri": "file://" & directory / ("slot-" & $slot & ".log")}
    writeFile(directory / "config.json", $config)
    writeFile(directory / "seats.json", $seats)
    let env = newStringTable(modeCaseSensitive)
    for key in ["PATH", "HOME", "LD_LIBRARY_PATH", "NIX_LD", "NIX_LD_LIBRARY_PATH"]:
      if existsEnv(key): env[key] = getEnv(key)
    for pair in [("COGAME_CONFIG_URI", "config.json"), ("COGAME_PLAYER_SEATS_URI", "seats.json"),
        ("COGAME_RESULTS_URI", "results.json"), ("COGAME_SAVE_REPLAY_URI", "replay.replay"),
        ("COGAME_PLAYER_FAILURE_URI", "failure.json")]: env[pair[0]] = "file://" & directory / pair[1]
    let started = getMonoTime()
    let worker = launch(PaintbotRoot / "coworld/paintbot/paintbot_worker", directory / "worker.log", env)
    doAssert worker.waitForExit(300_000) == 0, readFile(directory / "worker.log")
    worker.close()
    let elapsed = (getMonoTime() - started).inMilliseconds
    expected = digest(readFile(directory / "replay.replay"))
    rows.add %*{"mode": "direct", "wall_ms": elapsed, "replay_sha256": expected,
      "gameplay_ms": parseFile(directory / "timings.json")["gameplay_ms"],
      "ticks": parseFile(directory / "results.json")["ticks"]}
  let client = newCurly()
  defer: client.close()
  for index in 0 ..< 3:
    let started = getMonoTime()
    let response = client.post(url & "/v1/games/paintbot-pw/run",
      @[("Content-Type", "application/json")], $body, timeout = 1800)
    let elapsed = (getMonoTime() - started).inMilliseconds
    doAssert response.code == 200, response.body
    let files = archiveFiles(response.body, root)
    doAssert files.len == (if reference.len > 0: 2 else: 17), "Unexpected log visibility"
    let hash = digest(files["replay.replay"])
    if expected.len == 0: expected = hash
    doAssert hash == expected, "Replay bytes changed"
    let observed = parseJson(client.get(url & "/v1/metrics", timeout = 10).body)
    var active = -1
    for game in observed["recent_games"]:
      if game["request_id"].getStr == response.headers["X-Request-ID"]:
        active = game["active_bots"].getInt
    doAssert active == 16, "A benchmark seat failed to execute"
    let replay = root / ("replay-" & $index & ".replay")
    writeFile(replay, files["replay.replay"])
    let check = execCmdEx(quoteShell(PaintbotRoot / "coworld/paintbot/replay_check") & " --replay " & quoteShell(replay))
    doAssert check.exitCode == 0, check.output
    var timings = newJObject()
    for part in response.headers["Server-Timing"].split(','):
      let fields = part.strip().split(";dur=")
      timings[fields[0]] = %parseFloat(fields[1])
    writeFile(root / ("response-" & $index & ".zip"), response.body)
    rows.add %*{"mode": "http", "iteration": index, "wall_ms": elapsed,
      "timings_ms": timings, "active_bots": active, "replay_sha256": hash,
      "request_id": response.headers["X-Request-ID"]}
    writeFile(root / "measurements.json", rows.pretty())
  echo rows.pretty()

when isMainModule:
  main()
