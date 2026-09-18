import std/[json, os, sequtils, strutils, sysrand]
import tournaments, reports, runners, softmax, sites, collections

proc stop() {.noconv.} =
  ## Lets the current save or response finish before pausing the runner.
  stopping = true

proc main(): int =
  ## Creates or resumes a named tournament entirely through Nim.
  let arguments = parseArguments(commandLineParams())
  if arguments["help"].getBool:
    echo """GotA tournament runner
  --run NAME          Saved run under tmp/gota/tournaments/NAME
  --games N           Total games, required for a new run
  --top N             Ranked active entrants (default 10)
  --format FORMAT     mixed, mono, or both (default both)
  --league ID         GotA league by default
  --division ID       Competition division by default
  --seed N            Sampling seed (default 2026)
  --check-every N     Stability interval per format (default 10)
  --concurrency N     Concurrent remote requests (default 4)
  --retry-failed      Add replacement attempts for failed scheduled games
  --report-only       Rebuild saved reports without network requests
  --collect-stats     Collect missing replay stats, including with --report-only
  --stats-worker PATH Replay inspector built for the run's game release
  --site PATH         Update PATH/GOTA/standings/index.html as results arrive
                      Defaults to the sibling polyworld-buff checkout if present
  --no-site           Write only the run's local files
  --server URL        API server (default existing Softmax environment)

Press Ctrl+C to pause. Repeat --run NAME to resume."""
    return 0
  let
    directory = OutputRoot / arguments["run"].getStr
    dataRoot = getEnv("POLYWORLD_DATA", Root.parentDir / "polyworld_data")
    path = directory / "run.json"
    siteRoot = if arguments["no_site"].getBool: ""
      elif arguments.hasKey("site"): absolutePath(arguments["site"].getStr)
      elif dirExists(DefaultSite): DefaultSite else: ""
    controls = Controls(
      concurrency: arguments["concurrency"].getInt,
      pollMilliseconds: 10000,
      retryFailed: arguments["retry_failed"].getBool,
      siteRoot: siteRoot,
      statsWorker: arguments{"stats_worker"}.getStr(
        Root / "tmp/gota/tools/inspect_players")
    )
  validateSite(siteRoot)
  require(not symlinkExists(directory), "Run directories cannot be symlinks")
  var run: JsonNode
  if fileExists(path):
    run = readJson(path)
    validateResume(run, arguments)
  else:
    require(not arguments["report_only"].getBool, "No saved run exists")
    require(arguments["settings"].hasKey("games"),
      "--games is required for a new run")
    let settings = defaults()
    for name, value in arguments["settings"]:
      settings[name] = value
    let server = arguments{"server"}.getStr(
      getEnv("COGAMES_API_URL", "https://softmax.com/api"))
    let client = connect(server)
    try:
      run = client.snapshot(settings)
    finally:
      client.close()
    var id = ""
    for value in urandom(16):
      id.add(toHex(value, 2).toLowerAscii())
    run["schema"] = %Schema
    run["id"] = %id
    run["name"] = arguments["run"]
    run["created"] = %now()
    run["settings"] = settings
    run["server"] = %server
    run["web_url"] = %(if server.endsWith("/api"): server[0 .. ^5]
      else: server)
    run["schedule"] = scheduleGames(settings["games"].getInt,
      run["roster"].len, settings["format"].getStr, settings["seed"].getInt)
    saveJson(path, run)
  let
    records = loadRecords(directory, run)
    complete = records.allIt(it["state"].getStr == "completed")
  publish(directory, run, records, if complete: "completed" else: "paused",
    dataRoot, controls = controls)
  echo "Report: ", directory / "report.html"
  if siteRoot.len > 0:
    echo "Site: ", siteRoot / "GOTA/standings/index.html"
  if (not arguments["report_only"].getBool or
    arguments["collect_stats"].getBool) and records.anyIt(
      it["state"].getStr == "completed" and not it.hasKey("player_stats")):
      let client = connect(run["server"].getStr)
      try:
        for i, game in run["schedule"].elems:
          if stopping:
            break
          if records[i]["state"].getStr == "completed" and
            not records[i].hasKey("player_stats"):
              collectStats(client.transport(), directory, run, game,
                records[i], controls)
              publish(directory, run, records,
                if complete: "completed" else: "paused", dataRoot,
                controls = controls)
      finally:
        client.close()
  if stopping:
    return 130
  if arguments["report_only"].getBool or complete:
    return 0
  let client = connect(run["server"].getStr)
  try:
    result = execute(
      client.transport(),
      directory,
      run,
      dataRoot,
      controls
    )
  except CatchableError as error:
    publish(directory, run, loadRecords(directory, run), "paused", dataRoot,
      error.msg, controls)
    raise
  finally:
    client.close()

setControlCHook(stop)
try:
  quit(main())
except TournamentError as error:
  stderr.writeLine("Tournament error: " & error.msg)
  quit(1)
