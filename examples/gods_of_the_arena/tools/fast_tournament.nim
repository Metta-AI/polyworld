import
  std/[json, os, sequtils, strutils, sysrand],
  curly,
  tournaments, reports, runners, softmax, sites, fasts

proc stop() {.noconv.} =
  ## Stops new admissions while retaining responses from requests in flight.
  stopping = true

proc main(): int =
  ## Runs the two Glory tournaments using bounded synchronous Fast XP requests.
  var
    arguments: seq[string]
    prepareOnly = false
    stopAfter = 0
  let supplied = commandLineParams()
  var i = 0
  while i < supplied.len:
    case supplied[i]
    of "--prepare-only":
      prepareOnly = true
    of "--stop-after":
      inc i
      require(i < supplied.len, "--stop-after needs a completed-game count")
      stopAfter = parseInt(supplied[i])
      require(stopAfter > 0, "--stop-after must be positive")
    else:
      arguments.add(supplied[i])
    inc i
  let options = parseArguments(arguments)
  if options["help"].getBool:
    echo """GotA Fast XP tournament (Glory only)
  --run NAME          Saved run under tmp/gota/tournaments/NAME
  --games N           Total games; both formats split this equally
  --top N             Ranked active players (default 10)
  --format FORMAT     mixed, mono, or both (default both)
  --seed N            Frozen shuffled schedule seed
  --concurrency N     Requests in flight (default 4, maximum 16)
  --stats-worker PATH Inspector compiled from the hosted release source
  --prepare-only      Snapshot roster and schedule without submitting games
  --stop-after N      Pause after N total completions for an acceptance check
  --report-only       Rebuild the saved report offline
  --retry-failed      Retry known failures; never retry uncertain requests
  --site PATH         Update the local Polyworld Buff checkout
  --no-site           Only write the local report
Ctrl+C stops scheduling, then waits for admitted responses before exiting."""
    return 0
  let
    directory = OutputRoot / options["run"].getStr
    path = directory / "run.json"
    dataRoot = getEnv("POLYWORLD_ART", Root.parentDir / "polyworld_art")
    siteRoot = if options["no_site"].getBool: ""
      elif options.hasKey("site"): absolutePath(options["site"].getStr)
      elif dirExists(DefaultSite): DefaultSite else: ""
    controls = Controls(
      concurrency: options["concurrency"].getInt,
      retryFailed: options["retry_failed"].getBool,
      siteRoot: siteRoot,
      statsWorker: options{"stats_worker"}.getStr(
        Root / "tmp/gota/tools/inspect_fast")
    )
  validateSite(siteRoot)
  require(not symlinkExists(directory), "Run directories cannot be symlinks")
  var run: JsonNode
  if fileExists(path):
    run = readJson(path)
    validateResume(run, options)
    require(run{"transport"}.getStr == "fast-xp", "Not a Fast XP run")
  else:
    require(not options["report_only"].getBool, "No saved Fast XP run")
    require(options["settings"].hasKey("games"), "New runs require --games")
    let settings = defaults()
    for name, value in options["settings"]:
      settings[name] = value
    settings["ladders"] = %*["glory"]
    let
      server = options{"server"}.getStr(
        getEnv("COGAMES_API_URL", "https://softmax.com/api"))
      client = connect(server)
    try:
      run = client.snapshot(settings)
    finally:
      client.close()
    let http = newCurly()
    try:
      let response = http.get(FastServer & "/v1/games")
      require(response.code == 200, "Cannot read the Fast XP game catalog")
      for game in tournaments.parseJson(response.body)["games"]:
        if game["game"].getStr == "gota":
          require(game["ready"].getBool, "GotA Fast XP is not ready")
          require(game["current_version"] == run["release"]["version"],
            "Fast XP differs from the Competition game release")
          run["fast_release"] = game
      require(run.hasKey("fast_release"), "GotA is missing from Fast XP")
    finally:
      http.close()
    var id = ""
    for value in urandom(16):
      id.add(toHex(value, 2).toLowerAscii())
    run["schema"] = %Schema
    run["id"] = %id
    run["name"] = options["run"]
    run["created"] = %now()
    run["settings"] = settings
    run["server"] = %server
    run["fast_server"] = %FastServer
    run["transport"] = %"fast-xp"
    run["schedule"] = scheduleGames(
      settings["games"].getInt,
      run["roster"].len,
      settings["format"].getStr,
      settings["seed"].getInt
    )
    saveJson(path, run)
  let records = loadRecords(directory, run)
  publish(directory, run, records,
    if records.allIt(it["state"].getStr == "completed"): "completed"
    else: "paused", dataRoot, controls = controls)
  echo "Report: ", directory / "report.html"
  for player in run["roster"]:
    echo player["league_rank"], ". ", player["name"].getStr,
      " - ", player["version"].getStr
  if prepareOnly or options["report_only"].getBool:
    return 0
  try:
    result = executeFast(directory, run, dataRoot, controls, stopAfter)
  except CatchableError as error:
    publish(directory, run, loadRecords(directory, run), "paused",
      dataRoot, error.msg, controls)
    raise

setControlCHook(stop)
try:
  quit(main())
except CatchableError as error:
  stderr.writeLine("Fast XP tournament error: " & error.msg)
  quit(1)
