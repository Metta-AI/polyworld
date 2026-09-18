import
  std/[os, strutils, tempfiles],
  tooling

const WorkerCount = 8

var outcomes: Channel[string]

proc worker(index: int) {.thread.} =
  ## Repeats concurrent subprocess creation to catch shared pipe close races.
  var failure = ""
  try:
    for i in 0 ..< 25:
      let directory = command(["git", "rev-parse", "--show-toplevel"])
      require(directory == Root, "Incorrect child working directory")
  except CatchableError as error:
    failure = "Worker " & $index & ": " & error.msg
  outcomes.send(failure)

proc main() =
  ## Checks concurrent pipe ownership, cwd restoration, and failure logging.
  let
    previous = getCurrentDir()
    directory = createTempDir("polyworld-tools-", "")
  defer:
    setCurrentDir(previous)
    removeDir(directory)
  setCurrentDir(directory)
  let expectedDirectory = getCurrentDir()
  outcomes.open(WorkerCount)
  defer:
    outcomes.close()
  var threads: array[WorkerCount, Thread[int]]
  for i in 0 ..< WorkerCount:
    createThread(threads[i], worker, i)
  for i in 0 ..< WorkerCount:
    threads[i].joinThread()
  for i in 0 ..< WorkerCount:
    let failure = outcomes.recv()
    doAssert failure.len == 0, failure
  doAssert getCurrentDir() == expectedDirectory
  let log = directory / "command.log"
  run(["git", "rev-parse", "--show-toplevel"], log)
  doAssert readFile(log).strip() == Root
  var failed = false
  try:
    run(["git", "rev-parse", "--verify", "refs/polyworld-tools-missing"], log)
  except PolyworldToolsError as error:
    failed = true
    doAssert log in error.msg
  doAssert failed
  doAssert readFile(log).len > 0
  echo "Concurrent processes, working directories and failure logs passed."

runTool(main)
