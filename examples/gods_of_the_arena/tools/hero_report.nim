import
  std/[json, os],
  jsony,
  heropages, herosites

const Root = currentSourcePath().parentDir.parentDir.parentDir.parentDir

type HeroReportError = object of CatchableError

proc readDocument(path: string): JsonNode =
  ## Reads report data and describes file or JSON failures consistently.
  try:
    result = readFile(path).fromJson(JsonNode)
  except IOError, jsony.JsonError:
    raise newException(HeroReportError, path & ": " & getCurrentExceptionMsg())

proc main() =
  ## Rebuilds HTML from saved statistics without compiling the simulator.
  var
    arguments: seq[string]
    site = defaultHeroSite()
    i = 0
  let values = commandLineParams()
  while i < values.len:
    case values[i]
    of "--no-site":
      site = ""
    of "--site":
      inc i
      if i >= values.len:
        raise newException(HeroReportError, "Missing value for --site")
      site = absolutePath(values[i])
    else:
      arguments.add(values[i])
    inc i
  if arguments.len notin 1 .. 2:
    echo "Usage: hero_report ANALYSIS_DIRECTORY [REPORT_HTML] " &
      "[--site CHECKOUT | --no-site]"
    quit(1)
  checkHeroSite(site)
  let
    directory = absolutePath(arguments[0])
    summary = readDocument(directory / "summary.json")
    manifest = readDocument(directory / "manifest.json")
    appearances = newJArray()
  for match in manifest["matches"]:
    let id = match["id"].getStr
    if id.extractFilename != id:
      raise newException(HeroReportError, "Invalid match identifier")
    let path = directory / "stats" / (id & ".json")
    if not fileExists(path):
      continue
    let record = readDocument(path)
    if not record{"verified"}.getBool:
      continue
    for hero in record["heroes"]:
      let row = %*{"hero": hero["hero"], "level": hero["level"]}
      for field in ["id", "game_version", "minutes"]:
        row[field] = record[field]
      appearances.add(row)
  if appearances.len != summary["hero_appearances"].getInt:
    raise newException(HeroReportError, "Rebuild the statistics summary first")
  let path =
    if arguments.len == 2:
      absolutePath(arguments[1])
    else:
      directory / "report.html"
  writeHeroStats(
    path,
    summary,
    appearances,
    getEnv("POLYWORLD_DATA", Root.parentDir / "polyworld_data")
  )
  updateHeroSite(path, site)
  echo "Report: ", path

try:
  main()
except CatchableError as error:
  stderr.writeLine("Hero report error: " & error.msg)
  quit(1)
