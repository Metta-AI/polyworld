## The shared LLM host supplies schema and seat bindings without VM changes.
import std/[os, strutils, tempfiles]
import bassy, polyworld/[coworld, llms]

block:
  let directory = createTempDir("annotation-bindings-", "")
  defer: removeDir(directory)
  let first = directory / "first.jsonl"
  let second = directory / "second.jsonl"
  seats = CoworldSeats(seats: @[
    CoworldSeat(annotationsUri: "file://" & first),
    CoworldSeat(annotationsUri: "file://" & second)
  ])
  var schema = initHost()
  newLlmClient(0, LlmConfig()).addFunctions(schema)
  let program = compile("""
  ANNOTATE(123, "intent", "selectTarget", "{""target"":7}")
  """, schema)
  var fallback = initRuntime(program, schema)
  discard fallback.run()
  doAssert not fileExists(first)
  for slot in 0 .. 1:
    var host = initHost()
    newLlmClient(slot).addFunctions(host)
    var runtime = initRuntime(program, host)
    discard runtime.run()
    runtime.restart()
    discard runtime.run()
  doAssert readFile(first) == readFile(second)
  doAssert readFile(first).count('\n') == 2
  echo "Schema cannot emit; shared program uses independent runtime destinations"
