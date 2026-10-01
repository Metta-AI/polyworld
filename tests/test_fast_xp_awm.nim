import
  std/[base64, json, os, osproc, sequtils, strtabs, strutils, tables, tempfiles],
  crunchy, mummy,
  zippy/ziparchives,
  ./fastxpfixtures

const
  Route = "/v1/games/awm/run"
  UploadedSource = "print \"uploaded-awm-log\"\n" & staticRead("../coworld/awm/players/base.bas")

proc digest(bytes: string): string =
  ## Hashes the mock's policy and deterministic replay.
  for value in sha256(bytes): result.add value.toHex(2).toLowerAscii()

proc mock(request: Request) {.gcsafe.} =
  ## Supplies private BASIC opponents through the existing policy-file contract.
  let bytes = if "broken" in request.uri: "print \"private-awm-secret\"\nif\n"
    else: "print \"private-awm-log\"\nend\n"
  if request.path == "/v2/policy-files/download":
    doAssert request.headers["Authorization"] == "Bearer fixture"
    let reference = request.queryParams["policy_ref"]
    let policy = if reference == "broken:v1": "print \"private-awm-secret\"\nif\n"
      else: "print \"private-awm-log\"\nend\n"
    request.respond(200, body = $(%*{"content_hash": digest(policy), "size_bytes": policy.len,
      "download_url": "http://127.0.0.1:" & paramStr(2) & "/artifact?ref=" & reference}))
  else:
    doAssert request.headers["Authorization"].len == 0
    request.respond(200, body = bytes)

proc verify(files: OrderedTable[string, string], root: string) =
  ## Checks every recorded action hash with the unmodified headless executable.
  for name, bytes in files:
    if name.endsWith(".replay"):
      let path = root / name.replace('/', '-')
      writeFile(path, bytes)
      let checked = execCmdEx(quoteShell(getEnv("FAST_XP_AWM_REPLAY")) & " --replay " & quoteShell(path))
      doAssert checked.exitCode == 0, checked.output
      doAssert "5 players" in checked.output

proc run() =
  ## Exercises league defaults, packages, privacy, batching and failure collection.
  doAssert getEnv("FAST_XP_AWM_COMMAND").len > 0
  doAssert getEnv("FAST_XP_AWM_REPLAY").len > 0
  let root = createTempDir("awm-api-test-", "")
  defer: removeDir(root)
  let
    port = unusedPort()
    mockPort = unusedPort()
    base = "http://127.0.0.1:" & $port
    env = environment(root, port)
    log = root / "server.log"
  env["FAST_XP_GAMES"] = "gota,paintbot-pw,awm"
  env["FAST_XP_OBSERVATORY_TOKEN"] = "fixture"
  env["FAST_XP_OBSERVATORY_URL"] = "http://127.0.0.1:" & $mockPort
  let upstream = launch(getAppFilename(), root / "mock.log", env, @["--mock", $mockPort])
  defer: stop(upstream)
  let server = launch(ServerPath, log, env)
  defer: stop(server)
  waitUntil(records(log).anyIt(it["event"].getStr == "server_started"), server, log)
  doAssert metrics(base)["games"].len == 3
  let instructions = call(base, "/docs/llms.txt")
  for route in ["gota", "paintbot-pw", "awm"]:
    doAssert instructions.body.contains("/v1/games/" & route & "/run")
    doAssert call(base, "/docs/" & route & "/run.md").status == 200
    doAssert call(base, "/docs/" & route & "/llms.txt").status == 404
  var body = %*{"seed": 2026, "roster": [
    {"slot": 0, "player": {"source": UploadedSource}},
    {"player": {"policy_ref": "fixture:v1"}}]}
  let first = call(base, Route, body)
  doAssert first.status == 200, first.body
  let files = archiveFiles(first.body, root)
  doAssert files.len == 2 and "uploaded-awm-log" in files["logs/slot-0.txt"]
  for value in files.values: doAssert "private-awm-log" notin value
  verify(files, root)
  let second = call(base, Route, body)
  doAssert second.status == 200, second.body
  doAssert digest(archiveFiles(second.body, root)["replay.replay"]) == digest(files["replay.replay"])
  let package = createZipArchive({"policy.bas": UploadedSource, "resource.txt": "resource"}.toOrderedTable)
  body["roster"][0]["player"] = %*{"package_base64": encode(package)}
  let packaged = call(base, Route, body)
  doAssert packaged.status == 200, packaged.body
  doAssert archiveFiles(packaged.body, root)["replay.replay"] == files["replay.replay"]
  body["num_episodes"] = %10
  let batch = call(base, Route, body)
  doAssert batch.status == 200, batch.body
  let batchFiles = archiveFiles(batch.body, root)
  let manifest = parseJson(batchFiles["manifest.json"])
  doAssert manifest["game"].getStr == "awm" and manifest["games"].len == 10
  for index in 0 ..< 10:
    let game = manifest["games"][index]
    doAssert game["http_status"].getInt == 200 and game["active_bots"].getInt == 5
    doAssert game["roster_entries_by_slot"].len == 5
    doAssert game["seed"].getInt == 2026 + index
  verify(batchFiles, root)
  body["num_episodes"] = %1
  body["roster"][0]["slot"] = %5
  doAssert call(base, Route, body).status == 400
  body["roster"][0]["slot"] = %0
  body["roster"][0]["player"] = %*{"source": repeat('x', 256 * 1024 + 1)}
  doAssert call(base, Route, body).status == 413
  body["roster"][0]["player"] = %*{"source": "if\n"}
  doAssert call(base, Route, body).status == 422
  body["roster"][0]["player"] = %*{"source": UploadedSource}
  body["roster"][1]["player"] = %*{"policy_ref": "broken:v1"}
  let broken = call(base, Route, body)
  doAssert broken.status == 422, broken.body
  doAssert "private-awm-secret" notin broken.body
  body["roster"][1]["player"] = %*{"policy_ref": "fixture:v1"}
  doAssert call(base, Route, body).status == 200
  waitUntil(metrics(base)["admitted_requests"].getInt == 0, server, log)
  assertNoMatchFiles(root)

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--mock":
    newServer(mock).serve(Port(parseInt(paramStr(2))), "127.0.0.1")
  else:
    run()
