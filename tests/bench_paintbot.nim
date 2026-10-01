import
  std/[base64, json, monotimes, os, osproc, parseopt, sequtils, strtabs, strutils, tables, times],
  crunchy, curly,
  ./fastxpfixtures

proc digest(data: string): string =
  ## Identifies exact replay bytes across hosts and repeated requests.
  for value in sha256(data): result.add value.toHex(2).toLowerAscii()

proc main() =
  ## Measures complete requests through the configured production runner.
  var output, url, package, reference, sourcePath: string
  var ticks = 14400
  for kind, key, value in getopt():
    case key
    of "output": output = value
    of "url": url = value
    of "package": package = value
    of "opponent": reference = value
    of "source": sourcePath = value
    of "ticks": ticks = parseInt(value)
    else: raise newException(ValueError, "Unknown option: " & key)
  doAssert output.len > 0 and not dirExists(output), "Use --output:NEW_DIRECTORY"
  doAssert sourcePath.len > 0 or package.len > 0, "Supply --source:FILE or --package:ZIP"
  doAssert getEnv("FAST_XP_PAINTBOT_REPLAY").len > 0, "Configure the stock headless replay executable"
  let root = absolutePath(output)
  createDir(root)
  setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
  let player = if package.len > 0: %*{"package_base64": encode(readFile(package))}
    else: %*{"source": readFile(sourcePath)}
  var roster = %*[{"player": player}]
  if reference.len > 0:
    roster = %*[{"slot": 0, "player": player}, {"player": {"policy_ref": reference}}]
  let body = %*{"seed": 2026, "config": {"max_ticks": ticks}, "roster": roster}
  writeFile(root / "request.json", $body)
  var server: Process
  if url.len == 0:
    let port = unusedPort()
    url = "http://127.0.0.1:" & $port
    let env = environment(root, port)
    env["FAST_XP_GAMES"] = "paintbot-pw"
    server = launch(ServerPath, root / "server.log", env)
    waitUntil(records(root / "server.log").anyIt(it["event"].getStr == "server_started"), server, root / "server.log")
  defer:
    if server != nil: stop(server)
  var rows = newJArray()
  var expected: string
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
    let check = execCmdEx(quoteShell(getEnv("FAST_XP_PAINTBOT_REPLAY")) & " --replay " & quoteShell(replay))
    doAssert check.exitCode == 0, check.output
    var timings = newJObject()
    for part in response.headers["Server-Timing"].split(','):
      let fields = part.strip().split(";dur=")
      timings[fields[0]] = %parseFloat(fields[1])
    writeFile(root / ("response-" & $index & ".zip"), response.body)
    rows.add %*{"iteration": index, "wall_ms": elapsed,
      "timings_ms": timings, "active_bots": active, "replay_sha256": hash,
      "request_id": response.headers["X-Request-ID"]}
    writeFile(root / "measurements.json", rows.pretty())
  echo rows.pretty()

when isMainModule:
  main()
