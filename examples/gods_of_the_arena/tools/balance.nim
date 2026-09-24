import
  std/[json, monotimes, os, osproc, streams, strutils, times],
  balances, balance_reviews

const
  Root = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  ToolsPath = "examples/gods_of_the_arena/tools"
  ContentPath = "examples/gods_of_the_arena/content.nim"
  SnapshotPaths = @["src", "examples/gods_of_the_arena", "tests",
    "config.nims", "coworld/dependencies.lock"]
  ExclusiveNonblockingLock = 6.cint

type
  Job = object
    process: Process
    index: int
    started: MonoTime

var stopping {.volatile.} = false

proc flock(descriptor, operation: cint): cint
    {.importc, header: "<sys/file.h>".}
  ## Acquires a process-owned filesystem lock released when its file closes.

proc stop() {.noconv.} =
  ## Lets the scheduler close its workers after a console interrupt.
  stopping = true

proc command(executable: string, arguments: seq[string],
    directory: string): string =
  ## Runs a setup command and checks its exit status.
  let process = startProcess(
    executable, workingDir = directory, args = arguments,
    options = {poUsePath, poStdErrToStdOut}
  )
  defer: process.close()
  result = process.outputStream.readAll()
  require(process.waitForExit() == 0,
    executable & " failed:\n" & result)

proc arguments(): JsonNode =
  ## Parses explicit run settings and paths without interpreting shell syntax.
  result = %*{"games": 100, "rounds": 10, "jobs": 14, "step": 5,
    "seed": 20260923, "policy_label": "local policy", "timeout": 600,
    "method": "band", "initial_content": "", "draft": "random",
    "snapshot": "head"}
  let args = commandLineParams()
  if args.len == 0 or "--help" in args:
    echo "balance --run NAME --policy FILE --config FILE [--policy-label TEXT]"
    echo "  --games 100 --rounds 10 --jobs 14 --step 5 --seed 20260923"
    echo "  --method sequential --seed 1988 --step 50 --initial-content FILE"
    echo "  --method farthest --draft roles --rounds 10"
    echo "  --method evaluate --draft roles --rounds 1 (no stat adjustments)"
    echo "  --snapshot working (freeze tracked local edits with their patch)"
    echo "  Resume by repeating the same arguments. Outputs stay in tmp/gota."
    quit(0)
  var index = 0
  while index < args.len:
    let key = args[index].replace("--", "").replace('-', '_')
    require(args[index].startsWith("--") and key in ["run", "policy",
      "config", "policy_label", "games", "rounds", "jobs", "step",
      "seed", "timeout", "method", "initial_content", "draft", "snapshot"],
      "Unknown option: " & args[index])
    inc index
    require(index < args.len, "Missing value for " & key)
    if key in ["games", "rounds", "jobs", "step", "seed", "timeout"]:
      try:
        result[key] = %args[index].parseInt
      except ValueError:
        raise newException(BalanceError, key & " needs an integer")
    else:
      result[key] = %args[index]
    inc index
  for key in ["run", "policy", "config"]:
    require(result{key}.getStr.len > 0, "Missing --" & key)
  require(result["run"].getStr.allCharsInSet(Letters + Digits + {'-', '_'}),
    "Run name may only contain letters, digits, dashes and underscores")
  require(result["games"].getInt >= 4 and result["games"].getInt mod 2 == 0,
    "Games must be even and at least four")
  require(result["rounds"].getInt in 1 .. 100, "Rounds must be 1 to 100")
  require(result["jobs"].getInt in 1 .. 64, "Jobs must be 1 to 64")
  require(result["step"].getInt in 1 .. 50, "Step must be 1 to 50 percent")
  require(result["timeout"].getInt > 0, "Timeout must be positive")
  require(result["method"].getStr in
    ["band", "sequential", "farthest", "paired", "evaluate"],
    "Method must be band, sequential, farthest, paired, or evaluate")
  if result["method"].getStr == "evaluate":
    require(result["rounds"].getInt == 1 and
      result["draft"].getStr == "roles",
      "Evaluation requires one frozen batch and role drafting")
  require(result["draft"].getStr in ["random", "roles"],
    "Draft must be random or roles")
  require(result["snapshot"].getStr in ["head", "working"],
    "Snapshot must be head or working")
  if result["method"].getStr in ["farthest", "paired"]:
    require(result["rounds"].getInt <= 10,
      "Reviewed experiments have a hard limit of ten batches")
  if result["method"].getStr == "paired":
    require(result["rounds"].getInt == 10 and
      result["games"].getInt == 100 and result["draft"].getStr == "roles",
      "Paired reviews require ten batches, 100 games, and role drafting")
  for key in ["policy", "config"]:
    result[key] = %absolutePath(result[key].getStr)
    require(fileExists(result[key].getStr), "Missing " & key & " file")
  if result["initial_content"].getStr.len > 0:
    result["initial_content"] = %absolutePath(result["initial_content"].getStr)
    require(fileExists(result["initial_content"].getStr),
      "Missing initial content file")

proc prepare(directory: string, options: JsonNode): JsonNode =
  ## Freezes source, policy, configuration, dependencies, and scheduling inputs.
  let path = directory / "run.json"
  if fileExists(path):
    result = readJson(path)
    for key in ["method", "initial_content", "draft", "snapshot"]:
      if not result.hasKey(key):
        result[key] = %(case key
          of "method": "band"
          of "draft": "random"
          of "snapshot": "head"
          else: "")
    for key in ["games", "rounds", "step", "seed", "policy_label",
        "method", "initial_content", "draft", "snapshot"]:
      require(
        result[key] == options[key],
        "Cannot change " & key & " on resume"
      )
    for key in ["policy", "config"]:
      let frozen =
        if key == "policy" and fileExists(directory / "original-policy.bas"):
          directory / "original-policy.bas"
        else:
          result[key].getStr
      require(readFile(frozen) == readFile(options[key].getStr),
        "Cannot change " & key & " on resume")
    if options["initial_content"].getStr.len > 0:
      require(readFile(options["initial_content"].getStr) ==
        readFile(directory / "baseline-content.nim"),
        "Cannot change initial content on resume")
    if result["snapshot"].getStr == "working":
      require(command("git", @["diff", "--binary", "HEAD", "--"] &
        SnapshotPaths, Root) == readFile(directory / "source.patch"),
        "Tracked source changed since this working snapshot was frozen")
    result["jobs"] = options["jobs"]
    result["timeout"] = options["timeout"]
    saveJson(path, result)
    return
  createDir(directory)
  let sourcePatch = command("git", @["diff", "--binary", "HEAD", "--"] &
    SnapshotPaths, Root)
  require(options["snapshot"].getStr == "working" or sourcePatch.len == 0,
    "Use --snapshot working to freeze tracked local edits explicitly")
  let
    source = directory / "source"
    commit = command("git", @["rev-parse", "HEAD"], Root).strip
    archive = directory / "source.tar"
  createDir(source)
  discard command(
    "git",
    @["archive", "--format=tar", "-o", archive, commit],
    Root
  )
  discard command("tar", @["-xf", archive, "-C", source], Root)
  removeFile(archive)
  if options["snapshot"].getStr == "working":
    writeFile(directory / "source.patch", sourcePatch)
    let paths = command("git", @["diff", "--name-only", "--no-renames",
      "-z", "HEAD", "--"] & SnapshotPaths, Root)
    for path in paths.split('\0'):
      if path.len == 0:
        continue
      require(not dirExists(Root / path),
        "Cannot snapshot a changed submodule: " & path)
      if fileExists(Root / path):
        createDir((source / path).parentDir)
        copyFile(Root / path, source / path)
      elif fileExists(source / path):
        removeFile(source / path)
    require(command("git", @["diff", "--binary", "HEAD", "--"] &
      SnapshotPaths, Root) == sourcePatch,
      "Tracked source changed while copying the working snapshot")
  for name in ["balance.nim", "balance_worker.nim", "balance_verify.nim",
      "balance_report.nim", "balances.nim", "confidences.nim",
      "balance_diagnostics.nim", "balance_reviews.nim"]:
    copyFile(Root / ToolsPath / name, source / ToolsPath / name)
  copyFile(options["policy"].getStr, directory / "policy.bas")
  copyFile(options["policy"].getStr, directory / "original-policy.bas")
  if options["draft"].getStr == "roles":
    writeFile(directory / "policy.bas", rolePolicy(readFile(
      directory / "original-policy.bas"
    )))
  copyFile(options["config"].getStr, directory / "config.json")
  copyFile(source / ContentPath, directory / "baseline-content.nim")
  copyFile(source / ContentPath, directory / "original-content.nim")
  if options["initial_content"].getStr.len > 0:
    copyFile(options["initial_content"].getStr,
      directory / "baseline-content.nim")
  result = options.copy
  result["schema"] = %2
  result["commit"] = %commit
  result["source"] = %source
  result["policy"] = %(directory / "policy.bas")
  result["config"] = %(directory / "config.json")
  result["dependencies"] = %getEnv("POLYWORLD_DEPS")
  result["nim_version"] = %NimVersion
  result["policy_sha256"] = %command(
    "openssl", @["dgst", "-sha256", directory / "policy.bas"], Root
  ).splitWhitespace[^1]
  result["original_policy_sha256"] = %command(
    "openssl", @["dgst", "-sha256", directory / "original-policy.bas"], Root
  ).splitWhitespace[^1]
  result["created_at"] = %getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  if options["snapshot"].getStr == "working":
    result["source_patch_sha256"] = %command("openssl",
      @["dgst", "-sha256", directory / "source.patch"], Root).
      splitWhitespace[^1]
  saveJson(path, result)

proc executeBatch(directory: string, run: JsonNode, schedule: JsonNode,
    worker: string): JsonNode =
  ## Keeps at most the requested number of isolated osproc workers running.
  result = newJArray()
  for entry in schedule:
    let output = directory / ($entry["index"].getInt & ".json")
    if fileExists(output):
      let existing = readJson(output)
      require(existing["job"] == entry, "Saved result belongs to another job")
      result.add(existing)
    else:
      result.add(newJNull())
  var
    active: seq[Job]
    next = 0
    completed = 0
  for value in result:
    if value.kind != JNull:
      inc completed
  try:
    while completed < schedule.len:
      require(not stopping, "Interrupted; repeat the command to resume")
      while next < schedule.len and active.len < run["jobs"].getInt:
        if result[next].kind == JNull:
          let jobPath = directory / ($next & ".job.json")
          saveJson(jobPath, schedule[next])
          active.add Job(
            process: startProcess(worker, args = @[jobPath],
              options = {poParentStreams}),
            index: next, started: getMonoTime()
          )
        inc next
      var index = active.high
      while index >= 0:
        let job = active[index]
        require((getMonoTime() - job.started).inSeconds <
          run["timeout"].getInt, "Game timed out: " & $job.index)
        let code = job.process.peekExitCode()
        if code != -1:
          job.process.close()
          active.delete(index)
          require(code == 0, "Game failed: " & $job.index & " (" & $code & ")")
          let record = readJson(schedule[job.index]["output"].getStr)
          require(record["job"] == schedule[job.index], "Result job mismatch")
          result.elems[job.index] = record
          inc completed
          if completed mod 10 == 0 or completed == schedule.len:
            echo directory.extractFilename, ": ", completed, "/", schedule.len
        dec index
      sleep(50)
  finally:
    for job in active:
      if job.process.running:
        job.process.terminate()
        if job.process.waitForExit(5000) == -1:
          job.process.kill()
          discard job.process.waitForExit()
      job.process.close()

proc main() =
  ## Runs sequential balance batches and exports the last tested tuning patch.
  let
    options = arguments()
    directory = Root / "tmp/gota/balance" / options["run"].getStr
  createDir(directory)
  let lock = open(directory / "run.lock", fmAppend)
  defer: lock.close()
  require(flock(lock.getFileHandle(), ExclusiveNonblockingLock) == 0,
    "Another process is already running this experiment")
  setControlCHook(stop)
  let
    run = prepare(directory, options)
    source = run["source"].getStr
    baseline = readFile(directory / "baseline-content.nim")
    rounds = newJArray()
    sequential = run["method"].getStr in ["sequential", "farthest"]
    paired = run["method"].getStr == "paired"
    evaluate = run["method"].getStr == "evaluate"
    diagnostics = paired or evaluate
  require(run["dependencies"].getStr.len > 0,
    "Set POLYWORLD_DEPS to the pinned dependency checkout")
  putEnv("POLYWORLD_DEPS", run["dependencies"].getStr)
  if not fileExists(directory / "report.html"):
    report(directory, run, rounds)
  for round in 1 .. run["rounds"].getInt:
    require(not stopping, "Interrupted; repeat the command to resume")
    let
      batch = directory / ("round-" & align($round, 2, '0'))
      summaryPath = batch / "summary.json"
    if fileExists(summaryPath):
      let
        saved = readJson(summaryPath)
        games = newJArray()
      for index in 0 ..< run["games"].getInt:
        games.add(readJson(batch / ($index & ".json")))
      let refreshed = summarize(games)
      for key in ["round", "wall_seconds", "changes"]:
        refreshed[key] = saved[key]
      if saved.hasKey("decision"):
        refreshed["decision"] = saved["decision"]
      refreshed["tuning"] = tuning(readFile(batch / "content.nim"))
      saveJson(summaryPath, refreshed)
      rounds.add(refreshed)
      if paired and round < 10:
        if not reviewBatch(directory, rounds):
          saveJson(directory / "results.json", rounds)
          report(directory, run, rounds)
          echo "Awaiting replay review for batch ", round
          return
        saveJson(directory / "results.json", rounds)
        report(directory, run, rounds)
      if sequential and (refreshed.allBalanced or saved["changes"].len == 0):
        break
      continue
    createDir(batch)
    let
      previous = directory / ("round-" & align($(round - 1), 2, '0'))
      current =
        if round == 1:
          baseline
        else:
          readFile(previous / "next-content.nim")
    writeFile(batch / "content.nim", current)
    writeFile(source / ContentPath, current)
    saveJson(batch / "tuning.json", tuning(current))
    echo "Compiling batch ", round
    let worker = batch / "worker"
    writeFile(batch / "build.log", command("nim", @[
      "c", "-d:release", "-d:headless",
      (if diagnostics: "-d:replayEvents" else: "--hints:off"), "--hints:off",
      "--nimcache:" & directory / "nimcache", "-o:" & worker,
      source / ToolsPath / "balance_worker.nim"
    ], source))
    let
      validationStart =
        if paired and fileExists(directory / "validation.json"):
          readJson(directory / "validation.json")["start_batch"].getInt
        else:
          9
      jobs =
        if run["draft"].getStr == "roles":
          roleSchedule(run["games"].getInt, run["seed"].getInt +
            (if paired and round >= validationStart:
              (round - validationStart + 1) * 10000 else: 0))
        elif sequential:
          fixedSchedule(run["games"].getInt, run["seed"].getInt)
        else:
          schedule(run["games"].getInt, run["seed"].getInt + round)
    for job in jobs:
      job["config"] = run["config"]
      job["policy"] = run["policy"]
      job["output"] = %(batch / ($job["index"].getInt & ".json"))
      if diagnostics:
        job["diagnostics"] = %true
        job["replay"] = %(batch / ($job["index"].getInt & ".replay"))
      if job["index"].getInt == 0:
        job["replay"] = %(batch / "sample.replay")
    saveJson(batch / "schedule.json", jobs)
    let
      started = getMonoTime()
      games = executeBatch(batch, run, jobs, worker)
      summary = summarize(games)
    summary["wall_seconds"] = %(
      (getMonoTime() - started).inMilliseconds.float / 1000
    )
    let verifier = batch / "verify"
    writeFile(batch / "verify-build.log", command("nim", @[
      "c", "-d:release", "-d:headless",
      (if diagnostics: "-d:replayEvents" else: "--hints:off"), "--hints:off",
      "--nimcache:" & directory / "verify-cache", "-o:" & verifier,
      source / ToolsPath / "balance_verify.nim"
    ], source))
    writeFile(batch / "verify.log", command(
      verifier, @[batch / "sample.replay"], source
    ))
    summary["round"] = %round
    summary["tuning"] = tuning(current)
    var next = current
    rounds.add(summary)
    summary["changes"] =
      if paired or evaluate:
        newJArray()
      elif sequential:
        adjustOne(next, baseline, rounds, run["step"].getInt,
          run["method"].getStr == "farthest")
      else:
        adjust(next, baseline, summary, run["step"].getInt)
    writeFile(batch / "next-content.nim", next)
    saveJson(summaryPath, summary)
    saveJson(directory / "results.json", rounds)
    report(directory, run, rounds)
    echo "Batch ", round, ": Red ", summary["red_wins"],
      ", Blue ", summary["blue_wins"], ", draws ", summary["draws"]
    for hero in summary["heroes"]:
      echo "  ", hero["hero"].getStr, ": ",
        (if hero["win_rate"].kind == JNull: "no decisive games" else:
          (hero["win_rate"].getFloat * 100).formatFloat(ffDecimal, 1) & "%")
    for change in summary["changes"]:
      echo "  ", change["kind"].getStr, " ", change["hero"].getStr,
        " ", change["field"].getStr, " ", change["before"],
        " -> ", change["after"]
    if paired and round < 10:
      echo "Awaiting replay review for batch ", round
      return
    if sequential and (summary.allBalanced or summary["changes"].len == 0):
      break
  let last = directory / ("round-" & align($rounds.len, 2, '0'))
  copyFile(last / "content.nim", directory / "final-content.nim")
  copyFile(last / "next-content.nim", directory / "suggested-content.nim")
  saveJson(directory / "results.json", rounds)
  if paired:
    report(directory, run, rounds)
  let assessment =
    if paired:
      readJson(directory / "validation-summary.json")
    else:
      rounds[rounds.len - 1]
  saveJson(directory / "completion.json", %*{
    "batches": rounds.len, "converged": assessment.allBalanced,
    "reason":
      (if evaluate: "Frozen evaluation complete; no stat adjustments"
      elif sequential and rounds[rounds.len - 1].allBalanced:
        "Every hero's 95% interval includes 50%"
      elif rounds.len == run["rounds"].getInt: "Batch limit reached"
      else: "No further integer step in the current search")
  })
  report(directory, run, rounds)
  let original =
    if fileExists(directory / "original-content.nim"):
      directory / "original-content.nim"
    else:
      directory / "baseline-content.nim"
  let diff = startProcess("git", workingDir = source,
    args = @["diff", "--no-index", "--", original,
      directory / "final-content.nim"], options = {poUsePath, poStdErrToStdOut})
  var patch = diff.outputStream.readAll()
  let code = diff.waitForExit()
  diff.close()
  require(code in [0, 1], "Cannot create final tuning patch")
  patch = patch.replace(
    "a" & original,
    "a/" & ContentPath
  )
  patch = patch.replace(
    "b" & directory / "final-content.nim",
    "b/" & ContentPath
  )
  writeFile(directory / "final.patch", patch)
  echo "Completed ", rounds.len, " batches. Report: ",
    directory / "report.html"

try:
  main()
except CatchableError as error:
  stderr.writeLine("Balance experiment: " & error.msg)
  quit(1)
