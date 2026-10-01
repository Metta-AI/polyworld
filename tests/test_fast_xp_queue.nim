import
  std/[cpuinfo, json, monotimes, os, osproc, sequtils, strtabs, strutils, tables,
    tempfiles, times, uri],
  curly,
  ./fastxpfixtures

proc worker() =
  doAssert readFile("/proc/self/stat").split(')')[1].splitWhitespace()[16] == "10",
    "Game worker must run at nice +10"
  proc path(key: string): string = decodeUrl(parseUri(getEnv(key)).path)
  let root = path("COGAME_CONFIG_URI").parentDir.parentDir.parentDir
  let config = parseJson(readFile(path("COGAME_CONFIG_URI")))
  let seed = config["seed"].getInt()
  let started = open(root / "started", fmAppend)
  started.writeLine(seed)
  started.close()
  while fileExists(root / "gate"): sleep(10)
  if seed == 998: quit(2)
  if seed == 999:
    let child = startProcess(findExe("sleep"), args = @["180"], options = {})
    writeFile(root / "descendant", $child.processID)
    sleep(180_000)
  if seed == 997:
    let child = startProcess(findExe("sleep"), args = @["180"], options = {})
    writeFile(root / "completed-descendant", $child.processID)
  sleep(if seed >= 3000: 5 else: 100)
  stdout.writeLine(repeat('x', if seed >= 3000: 1000 else: 100_000))
  let seats = parseJson(readFile(path("COGAME_PLAYER_SEATS_URI")))
  for seat in seats["seats"]:
    writeFile(decodeUrl(parseUri(seat["log_uri"].getStr()).path), "completed\n")
  if seed == 202:
    writeFile(path("COGAME_PLAYER_FAILURE_URI"), "{\"failed_policy_index\":0}")
    quit(1)
  writeFile(path("COGAME_RESULTS_URI"), "{}")
  writeFile(path("COGAME_SAVE_REPLAY_URI"), $seed)
  if seed == 997: sleep(180_000)

proc run() =
  let root = createTempDir("queue-test-", "")
  defer: removeDir(root)
  let port = unusedPort()
  let base = "http://127.0.0.1:" & $port
  let env = environment(root, port)
  env["FAST_XP_GOTA_WORKER"] = getAppFilename()
  env["FAST_XP_PAINTBOT_COMMAND"] = $(%*[getAppFilename()])
  env["FAST_XP_AWM_COMMAND"] = $(%*[getAppFilename()])
  env["FAST_XP_GAMES"] = "gota,paintbot-pw,awm"
  env.del("FAST_XP_REQUEST_LIMIT")
  let log = root / "server.log"
  let process = launch(ServerPath, log, env)
  defer:
    removeFile(root / "gate")
    stop(process)
  proc game(seed: int, count = 1, name = "gota"): Curly =
    startCall(base, "/v1/games/" & name & "/run", %*{"seed": seed, "num_episodes": count,
      "roster": [{"player": {"source": "end"}}]})
  proc started(): seq[int] =
    if fileExists(root / "started"):
      for line in lines(root / "started"): result.add parseInt(line)
  waitUntil(records(log).anyIt(it["event"].getStr() == "server_started"), process, log)
  writeFile(root / "gate", "")
  let first = game(100, 10)
  waitUntil(started().len == 2, process, log)
  let second = game(500, name = "paintbot-pw")
  waitUntil(records(log).countIt(it["event"].getStr() == "request_accepted") == 2, process, log)
  sleep(200)
  doAssert started().len == 2
  doAssert (call(base, "/healthz")).status == 200
  var m = metrics(base)
  doAssert m["running"].getInt() == 2 and m["queued"].getInt() == 9, $m
  doAssert m["admitted_requests"].getInt() == 2 and m["worker_limit"].getInt() == 2
  doAssert m["request_limit"].getInt() == 512
  doAssert m["oldest_queue_ms"].getInt() > 0
  waitUntil((block:
    m = metrics(base)
    m["samples"].len > 0 and m["samples"][^1]["queued"].getInt() == 9), process, log)
  let activity = m["samples"][^1]["by_game"]
  doAssert activity[0]["running"].getInt() == 2 and activity[0]["queued"].getInt() == 8
  doAssert activity[1]["running"].getInt() == 0 and activity[1]["queued"].getInt() == 1
  removeFile(root / "gate")
  doAssert (finish(first)).status == 200 and (finish(second)).status == 200
  doAssert started().find(500) <= 4, $started()
  let partial = finish(game(200, 3))
  doAssert partial.status == 200
  let files = archiveFiles(partial.body, root)
  let games = parseJson(files["manifest.json"])["games"]
  doAssert toSeq(games.items).mapIt(it["http_status"].getInt()) == @[200, 200, 422]
  doAssert files.hasKey("games/000/replay.replay") and not files.hasKey("games/002/replay.replay")
  var concurrent: seq[Curly]
  for seed in 600 ..< 610: concurrent.add game(seed)
  for pending in concurrent: doAssert (finish(pending)).status == 200
  waitUntil((metrics(base))["running"].getInt() == 0 and
    (metrics(base))["admitted_requests"].getInt() == 0, process, log)
  m = metrics(base)
  doAssert m["successful_games"].getInt() == 23 and m["failed_games"].getInt() == 1
  doAssert m["single_request"]["count"].getInt() == 11 and m["batch_request"]["count"].getInt() == 2
  doAssert m["queue"]["count"].getInt() == 23 and m["worker"]["count"].getInt() == 23
  doAssert m["by_game"][0]["successful_games"].getInt() == 22
  doAssert m["by_game"][1]["successful_games"].getInt() == 1
  doAssert m["by_game"][0]["failed_games"].getInt() == 1
  let began = getMonoTime()
  let timedOut = finish(game(999))
  doAssert timedOut.status == 504, timedOut.body
  let deadline = parseInt(getEnv("FAST_XP_EXECUTION_SECONDS", "120")) * 1000
  doAssert (getMonoTime() - began).inMilliseconds in deadline ..< deadline + 10_000
  let child = parseInt(readFile(root / "descendant"))
  let stat = "/proc/" & $child & "/stat"
  doAssert not fileExists(stat) or readFile(stat).split(')')[1].strip().startsWith("Z"),
    "Timed-out worker left a running descendant"
  doAssert (metrics(base))["timeouts"].getInt() == 1
  doAssert finish(game(998)).status == 500
  doAssert finish(game(997)).status == 200
  let completedChild = parseInt(readFile(root / "completed-descendant"))
  let completedStat = "/proc/" & $completedChild & "/stat"
  doAssert not fileExists(completedStat) or readFile(completedStat).split(')')[1].strip().startsWith("Z"),
    "Completed worker left a running descendant"
  waitUntil(metrics(base)["admitted_requests"].getInt() == 0, process, log)
  let fairStarted = started().len
  writeFile(root / "gate", "")
  var paints: seq[Curly]
  for index in 0 ..< 24: paints.add game(8000 + index * 10, 10, "paintbot-pw")
  waitUntil(metrics(base)["queued"].getInt() == 238, process, log)
  let shortGame = game(9000, name = "awm")
  let gotaBatch = game(10000, 10)
  waitUntil(metrics(base)["queued"].getInt() == 249, process, log)
  doAssert started().len == fairStarted + 2
  removeFile(root / "gate")
  doAssert finish(shortGame).status == 200
  doAssert finish(gotaBatch).status == 200
  for pending in paints: doAssert finish(pending).status == 200
  let fairOrder = started()[fairStarted .. ^1]
  doAssert fairOrder.find(9000) in 2 .. 3, $fairOrder
  doAssert fairOrder.find(10000) in 2 .. 3, $fairOrder
  waitUntil(metrics(base)["admitted_requests"].getInt() == 0, process, log)
  writeFile(root / "gate", "")
  let burst = newCurly(maxInFlight = 300)
  defer: burst.close()
  for index in 0 ..< 300:
    burst.startRequest("POST", base & RunRoute, @[("Content-Type", "application/json")],
      $(%*{"seed": 3000 + index * 10, "num_episodes": 10,
        "roster": [{"player": {"source": "end"}}]}), timeout = 150, tag = $index)
  waitUntil((block:
    m = metrics(base)
    m["admitted_requests"].getInt() == 300 and m["queued"].getInt() == 2998),
    process, log, 30_000)
  doAssert m["running"].getInt() == 2
  doAssert call(base, "/healthz").status == 200
  doAssert call(base, "/").status == 200
  removeFile(root / "gate")
  var received: set[0 .. 299]
  for _ in 0 ..< 300:
    let (response, error) = burst.waitForResponse()
    doAssert error.len == 0, error
    doAssert response.code == 200, response.body
    let index = parseInt(response.request.tag)
    doAssert index notin received
    received.incl index
    let files = archiveFiles(response.body, root)
    let games = parseJson(files["manifest.json"])["games"]
    doAssert games.len == 10
    for episode in 0 ..< 10:
      doAssert games[episode]["http_status"].getInt() == 200
      doAssert files["games/" & align($episode, 3, '0') & "/replay.replay"] ==
        $(3000 + index * 10 + episode)
  doAssert received.len == 300
  waitUntil((block:
    m = metrics(base)
    m["running"].getInt() == 0 and m["queued"].getInt() == 0 and
      m["admitted_requests"].getInt() == 0), process, log)
  doAssert m["rejected_requests"].getInt() == 0
  writeFile(root / "gate", "")
  let before = started().len
  let pending = game(700, 10)
  waitUntil(started().len == before + 2, process, log)
  process.terminate()
  sleep(200)
  removeFile(root / "gate")
  let stopped = finish(pending)
  doAssert stopped.status == 200
  let stoppedFiles = archiveFiles(stopped.body, root)
  let statuses = toSeq(parseJson(stoppedFiles["manifest.json"])["games"].items).mapIt(it["http_status"].getInt())
  doAssert statuses.count(200) == 2 and statuses.count(503) == 8, $statuses
  m = metrics(base)
  doAssert m["queued"].getInt() == 0 and m["running"].getInt() == 0
  doAssert m["failed_games"].getInt() == 11
  doAssert toSeq(m["recent_games"].items).countIt(it["status"].getInt() == 503) == 8
  doAssert process.waitForExit(10_000) == 0, readFile(log)
  assertNoMatchFiles(root)
  doAssert "xxxx" notin readFile(log) and getFileSize(log) < 2 * 1024 * 1024
  env.del("FAST_XP_WORKERS")
  let automaticLog = root / "automatic.log"
  let automatic = launch(ServerPath, automaticLog, env)
  defer: stop(automatic)
  waitUntil(records(automaticLog).anyIt(it["event"].getStr() == "server_started"), automatic, automaticLog)
  doAssert metrics(base)["worker_limit"].getInt() == clamp(cpuinfo.countProcessors(), 1, 256)

if existsEnv("COGAME_CONFIG_URI"):
  worker()
else:
  run()
