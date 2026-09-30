import
  std/[base64, json, os, osproc, sequtils, strtabs, strutils, tables, tempfiles],
  crunchy, mummy,
  ./fastxpfixtures

const
  PaintbotRoot = currentSourcePath().parentDir.parentDir.parentDir / "paintbot-pw"
  Route = "/v1/games/paintbot-pw/run"

proc digest(data: string): string =
  ## Hashes the mock's downloadable policy.
  for value in sha256(data): result.add value.toHex(2).toLowerAscii()

proc mock(request: Request) {.gcsafe.} =
  ## Provides a submitted opponent without exposing its logs to the caller.
  let source = "print \"private-paintbot-log\"\nidle = 1\n"
  if request.path == "/v2/policy-files/download":
    doAssert request.headers["Authorization"] == "Bearer fixture"
    request.respond(200, body = $(%*{"content_hash": digest(source), "size_bytes": source.len,
      "download_url": "http://127.0.0.1:" & paramStr(2) & "/artifact"}))
  else:
    doAssert request.headers["Authorization"].len == 0
    request.respond(200, body = source)

proc verify(files: OrderedTable[string, string], root: string) =
  ## Extracts every replay and checks its recorded per-tick hashes.
  for name, bytes in files:
    if name.endsWith(".replay"):
      let path = root / name.replace('/', '-')
      writeFile(path, bytes)
      let result = execCmdEx(quoteShell(PaintbotRoot / "coworld/paintbot/replay_check") &
        " --replay " & quoteShell(path))
      doAssert result.exitCode == 0, result.output

proc run() =
  ## Exercises real Paintbot packages, privacy, batching and deterministic replays.
  let root = createTempDir("paintbot-api-test-", "")
  defer: removeDir(root)
  let
    port = unusedPort()
    mockPort = unusedPort()
    base = "http://127.0.0.1:" & $port
    env = environment(root, port)
    log = root / "server.log"
  env["FAST_XP_GAME"] = "paintbot-pw"
  env["FAST_XP_PAINTBOT_WORKER"] = PaintbotRoot / "coworld/paintbot/paintbot_worker"
  env["FAST_XP_OBSERVATORY_TOKEN"] = "fixture"
  env["FAST_XP_OBSERVATORY_URL"] = "http://127.0.0.1:" & $mockPort
  let upstream = launch(getAppFilename(), root / "mock.log", env, @["--mock", $mockPort])
  defer: stop(upstream)
  let server = launch(ServerPath, log, env)
  defer: stop(server)
  waitUntil(records(log).anyIt(it["event"].getStr == "server_started"), server, log)
  doAssert call(base, "/docs/llms.txt").body.contains(Route)
  doAssert call(base, "/v1/games/gota/run").status == 404
  doAssert metrics(base)["game"].getStr == "paintbot-pw"
  var body = %*{"seed": 2026, "config": {"max_ticks": 240}, "roster": [
    {"slot": 0, "player": {"source": "print \"uploaded-paintbot-log\"\nidle = 1\n"}},
    {"player": {"policy_ref": "fixture:v1"}}]}
  let first = call(base, Route, body)
  doAssert first.status == 200, first.body
  let files = archiveFiles(first.body, root)
  doAssert files.len == 2 and "logs/slot-0.txt" in files
  doAssert "uploaded-paintbot-log" in files["logs/slot-0.txt"]
  for value in files.values: doAssert "private-paintbot-log" notin value
  verify(files, root)
  let second = call(base, Route, body)
  doAssert second.status == 200, second.body
  doAssert archiveFiles(second.body, root)["replay.replay"] == files["replay.replay"]
  body["roster"][0]["player"] = %*{"package_base64": encode(readFile(paramStr(1)))}
  let neural = call(base, Route, body)
  doAssert neural.status == 200, neural.body
  let neuralFiles = archiveFiles(neural.body, root)
  doAssert "failed" notin neuralFiles["logs/slot-0.txt"].toLowerAscii
  verify(neuralFiles, root)
  body["num_episodes"] = %10
  body["config"]["max_ticks"] = %24
  let batch = call(base, Route, body)
  doAssert batch.status == 200, batch.body
  let batchFiles = archiveFiles(batch.body, root)
  let games = parseJson(batchFiles["manifest.json"])["games"]
  doAssert games.len == 10
  for index in 0 ..< games.len:
    let game = games[index]
    doAssert game["http_status"].getInt == 200
    doAssert game["seed"].getInt == 2026 + index
    doAssert game["roster_entries_by_slot"].len == 16
  verify(batchFiles, root)
  body["roster"][0]["slot"] = %16
  doAssert call(base, Route, body).status == 400
  body["roster"][0]["slot"] = %0
  body["num_episodes"] = %1
  body["roster"][0]["player"] = %*{"package_base64": encode("PK\x03\x04broken")}
  let bad = call(base, Route, body)
  doAssert bad.status == 200, bad.body
  doAssert "Policy initialization failed" in archiveFiles(bad.body, root)["logs/slot-0.txt"]
  body["roster"][0]["player"] = %*{"source": "if\n"}
  doAssert call(base, Route, body).status == 422
  body["roster"][0]["player"] = %*{"source": "idle = 1\n"}
  doAssert call(base, Route, body).status == 200
  waitUntil(metrics(base)["admitted_requests"].getInt == 0, server, log)
  assertNoMatchFiles(root)

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--mock":
    newServer(mock).serve(Port(parseInt(paramStr(2))), "127.0.0.1")
  else:
    doAssert paramCount() == 1, "Pass a Paintbot neural fixture ZIP"
    run()
