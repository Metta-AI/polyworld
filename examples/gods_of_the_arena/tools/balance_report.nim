import std/[json, os, strutils]
import balances

proc main() =
  ## Rebuilds a static report from completed batches, optionally while running.
  require(paramCount() in 1 .. 2,
    "Usage: balance_report RUN_DIRECTORY [--watch]")
  let
    directory = absolutePath(paramStr(1))
    watching = paramCount() == 2 and paramStr(2) == "--watch"
    run = readJson(directory / "run.json")
  require(paramCount() == 1 or watching, "Unknown report option")
  var previous = -1
  while true:
    let rounds = newJArray()
    for index in 1 .. run["rounds"].getInt:
      let batch = directory / ("round-" & align($index, 2, '0'))
      if not fileExists(batch / "summary.json"):
        break
      rounds.add(readJson(batch / "summary.json"))
    let
      path = directory / "report.html"
      current = if fileExists(path): readFile(path) else: ""
      complete = fileExists(directory / "completion.json") or
        (rounds.len == run["rounds"].getInt and
        fileExists(directory / "final.patch"))
    if rounds.len != previous or "id=\"balance-progress\"" notin current or
      complete:
        for index, saved in rounds.elems:
          let
            batch = directory / ("round-" & align($(index + 1), 2, '0'))
            games = newJArray()
          for game in 0 ..< run["games"].getInt:
            games.add(readJson(batch / ($game & ".json")))
          let refreshed = summarize(games)
          for key in ["round", "wall_seconds", "changes"]:
            refreshed[key] = saved[key]
          if saved.hasKey("decision"):
            refreshed["decision"] = saved["decision"]
          refreshed["tuning"] = tuning(readFile(batch / "content.nim"))
          rounds.elems[index] = refreshed
        report(directory, run, rounds)
        echo "Report: ", rounds.len, "/", run["rounds"], " completed batches"
        previous = rounds.len
    if not watching or complete:
      return
    sleep(2000)

try:
  main()
except CatchableError as error:
  stderr.writeLine("Balance report: " & error.msg)
  quit(1)
