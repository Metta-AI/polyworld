import
  std/[json, os, osproc, sha1, streams, strutils, times],
  curly,
  herostats, herosites

type
  Options = object
    directory, ending, site: string
    hours, jobs: int
    offline, help: bool
  Worker = object
    process: Process
    id: string

var interrupted: bool

proc stop() {.noconv.} =
  ## Stops scheduling new local work and lets the process queue clean up.
  interrupted = true

proc arguments(values: seq[string]): Options =
  ## Parses download window and local concurrency without hidden defaults.
  result = Options(hours: 24, jobs: 4, site: defaultHeroSite())
  var i = 0
  while i < values.len:
    let parts = values[i].split('=', maxsplit = 1)
    case parts[0]
    of "--help", "-h":
      result.help = true
    of "--offline":
      result.offline = true
    of "--no-site":
      result.site = ""
    of "--out", "--end", "--hours", "--jobs", "--site":
      var value: string
      if parts.len == 2:
        value = parts[1]
      else:
        inc i
        requireStats(i < values.len, "Missing value for " & parts[0])
        value = values[i]
      case parts[0]
      of "--out":
        result.directory = absolutePath(value)
      of "--end":
        result.ending = value
      of "--site":
        result.site = absolutePath(value)
      else:
        var number: int
        try:
          number = parseInt(value)
        except ValueError:
          raise newException(HeroStatsError, "Expected a positive integer")
        requireStats(number > 0, "Expected a positive integer")
        if parts[0] == "--hours":
          requireStats(number <= 8760, "--hours cannot exceed 8760")
          result.hours = number
        else:
          requireStats(number <= 32, "--jobs cannot exceed 32")
          result.jobs = number
    else:
      raise newException(HeroStatsError, "Unknown option: " & parts[0])
    inc i

proc worker(directory, id: string): int =
  ## Downloads and verifies one replay in a process with isolated game globals.
  let
    metadata = readStats(directory / "matches" / (safeId(id) & ".json"))
    replayPath = directory / "replays" / (id & ".replay")
    statsPath = directory / "stats" / (id & ".json")
  try:
    if not fileExists(replayPath):
      let http = newCurly()
      try:
        saveStats(replayPath, download(http, metadata["replay_url"].getStr))
      finally:
        http.close()
    let
      replayHash = $secureHashFile(replayPath)
      analyzerHash = $secureHashFile(getAppFilename())
    if fileExists(statsPath):
      let saved = readStats(statsPath)
      if saved{"verified"}.getBool and
        saved{"replay_sha1"}.getStr == replayHash and
        saved{"analyzer_sha1"}.getStr == analyzerHash:
          return 0
    let record = inspectReplay(replayPath, metadata)
    record["replay_sha1"] = %replayHash
    record["replay_bytes"] = %getFileSize(replayPath)
    record["analyzer_sha1"] = %analyzerHash
    saveStats(statsPath, record)
  except CatchableError as error:
    saveStats(statsPath, %*{"id": id, "verified": false,
      "reason": "replay_analysis_failed", "error": error.msg})
    stderr.writeLine(id & ": " & error.msg)
    return 1

proc analyze(directory: string, manifest: JsonNode, jobs: int) =
  ## Runs a bounded process queue because the simulation has shared globals.
  var
    queue: seq[string]
    active: seq[Worker]
    next, finished, failed = 0
  for match in manifest["matches"]:
    let id = safeId(match["id"].getStr)
    saveStats(directory / "matches" / (id & ".json"), match)
    if match["status"].getStr == "completed" and
      match{"replay_url"}.getStr.len > 0:
        queue.add(id)
  try:
    while not interrupted and (next < queue.len or active.len > 0):
      while not interrupted and next < queue.len and active.len < jobs:
        let id = queue[next]
        active.add Worker(
          id: id,
          process: startProcess(
            getAppFilename(),
            args = ["--worker", directory, id],
            options = {poStdErrToStdOut}
          )
        )
        inc next
      var i = 0
      while i < active.len:
        let child = active[i]
        if child.process.running:
          inc i
          continue
        let
          code = child.process.waitForExit()
          output = child.process.outputStream.readAll()
        child.process.close()
        active.delete(i)
        inc finished
        if code != 0:
          inc failed
          saveStats(directory / "stats" / (child.id & ".json"),
            %*{"id": child.id, "verified": false,
              "reason": "replay_analysis_failed", "error": output.strip,
              "exit_code": code})
          stderr.writeLine(output.strip)
        if finished mod 10 == 0 or finished == queue.len:
          echo "Analyzed ", finished, "/", queue.len,
            " replays; ", failed, " failed"
      if active.len > 0:
        sleep(100)
  finally:
    for child in active:
      if child.process.running:
        child.process.terminate()
        discard child.process.waitForExit()
      child.process.close()

proc main(): int =
  ## Freezes a 24-hour league snapshot and exports fully checked hero stats.
  let values = commandLineParams()
  if values.len == 3 and values[0] == "--worker":
    return worker(values[1], values[2])
  var options = arguments(values)
  if options.help:
    echo """GOTA league hero statistics, using public read-only APIs.

Build from the repository root:
  nim c -d:headless -o:tmp/gota/hero_stats \
    examples/gods_of_the_arena/tools/hero_stats.nim
Run:
  tmp/gota/hero_stats --hours 24 --jobs 4

  --hours N     Lookback duration (default 24).
  --end UTC     Exclusive RFC 3339 end (default now).
  --out PATH    Output directory; reuse it to resume the frozen window.
  --jobs N      Concurrent local replay processes (default 4, max 32).
  --offline     Rebuild reports from saved evidence without network access.
  --site PATH   Website checkout (default POLYWORLD_BUFF or sibling checkout).
  --no-site     Generate local reports only.

Writes manifest.json, replay files, per-game JSON, report.html, heroes.csv,
heroes_by_version.csv, appearances.csv, and summary.json. Reusing --out
resumes its original window. Use a new directory for a fresh last 24 hours.
All recorded hashes and league seat scores must match. Incomplete coverage
is listed in the report and returns exit status 2. No games are submitted.
When the website checkout is present, also updates GOTA/heros/index.html
and hero_assets using its shared styling. Git commit/push remains manual."""
    return 0
  checkHeroSite(options.site)
  let ending = if options.ending.len > 0: timestamp(options.ending)
    else: getTime()
  if options.directory.len == 0:
    requireStats(not options.offline, "--offline requires --out")
    options.directory = StatsRoot / "tmp/gota/hero-stats" /
      ending.utc.format("yyyyMMdd'T'HHmmss'Z'")
  let path = options.directory / "manifest.json"
  var manifest: JsonNode
  if fileExists(path):
    manifest = readStats(path)
    requireStats(manifest{"schema"}.getInt == StatsSchema,
      "Unsupported saved statistics schema")
    requireStats(manifest{"league"}.getStr == StatsLeague,
      "Saved snapshot belongs to another league")
    if options.ending.len > 0:
      requireStats(timestamp(manifest["end"].getStr) == ending,
        "Cannot change the end of a saved window")
    for value in values:
      if value == "--hours" or value.startsWith("--hours="):
        requireStats(timestamp(manifest["end"].getStr) -
          timestamp(manifest["start"].getStr) ==
          initDuration(hours = options.hours),
          "Cannot change the duration of a saved window")
    echo "Resuming frozen window ", manifest["start"].getStr,
      " to ", manifest["end"].getStr
  else:
    requireStats(not options.offline, "No saved manifest for --offline")
    let http = newCurly()
    try:
      let fetch: FetchPage = proc(path: string): JsonNode =
        ## Retrieves public league metadata without a privileged session.
        jsonStats(download(http, StatsApi & path))
      manifest = collect(
        fetch,
        StatsLeague,
        ending - initDuration(hours = options.hours),
        ending
      )
      manifest["api"] = %StatsApi
      saveStats(path, manifest)
    finally:
      http.close()
  if not options.offline:
    analyze(options.directory, manifest, options.jobs)
  let summary = publishStats(options.directory, manifest)
  updateHeroSite(options.directory / "report.html", options.site)
  echo "Report: ", options.directory / "report.html"
  echo summary["verified_games"].getInt, " verified games, ",
    summary["excluded"].len, " excluded requests"
  if interrupted:
    return 130
  if summary["excluded"].len > 0:
    return 2

setControlCHook(stop)
try:
  quit(main())
except CatchableError as error:
  stderr.writeLine("Hero stats error: " & error.msg)
  quit(1)
