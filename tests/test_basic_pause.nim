import polyworld/basic

let source = """
dim results(4)
i = 0
while i < 4
  results(i) = choose(i) + 7
  i = i + 1
wend
"""
var paused: Runtime
var host = initHost()
var arguments: seq[int32]
discard host.addFunction("choose", 1, proc(values: openArray[int32]): int32 =
  arguments.add values[0]
  paused.pauseHostCall()
  0'i32, 1)
let program = compile(source, host)
paused = initRuntime(program, host)
for action in 0 ..< 4:
  discard paused.run()
  doAssert paused.hostCallPaused
  doAssert arguments == @[0'i32, 1, 2, 3][0 .. action]
  paused.resumeHostCall(int32(action * 3))
discard paused.run()
doAssert not paused.hostCallPaused
for index in 0 ..< 4:
  doAssert paused.getArray("results", int32(index)) == int32(index * 3 + 7)

var directHost = initHost()
discard directHost.addFunction("choose", 1, proc(values: openArray[int32]): int32 =
  values[0] * 3, 1)
var direct = initRuntime(program, directHost)
discard direct.run()
doAssert paused.workUsed == direct.workUsed
doAssert paused.instructionsUsed == direct.instructionsUsed
paused.restart()
discard paused.run()
doAssert paused.hostCallPaused
paused.reset()
doAssert not paused.hostCallPaused
echo "Paused host calls preserve arrays, order, metering, and reset semantics"

block:
  var runtime: Runtime
  var nestedHost = initHost()
  var calls: seq[int32]
  discard nestedHost.addFunction("choose", 1, proc(values: openArray[int32]): int32 =
    calls.add values[0]
    runtime.pauseHostCall()
    0'i32, 1)
  let nested = compile("""
sub inner(value)
  local = choose(value)
  total = local + value
end sub
sub outer(value)
  inner(value + 2)
end sub
outer(5)
choose(99)
finished = 1
""", nestedHost)
  runtime = initRuntime(nested, nestedHost)
  discard runtime.run()
  doAssert calls == @[7'i32]
  runtime.resumeHostCall(11)
  discard runtime.run()
  doAssert runtime.getGlobal("total") == 18
  doAssert calls == @[7'i32, 99]
  runtime.resumeHostCall(123)
  discard runtime.run()
  doAssert runtime.getGlobal("finished") == 1
  runtime.restart()
  discard runtime.run()
  doAssert runtime.hostCallPaused
  runtime.restart()
  doAssert not runtime.hostCallPaused
  discard runtime.run()
  doAssert calls == @[7'i32, 99, 7, 7]

block:
  var runtime: Runtime
  var budgetHost = initHost()
  discard budgetHost.addFunction("choose", 0, proc(values: openArray[int32]): int32 =
    runtime.pauseHostCall()
    0'i32, 1)
  let bounded = compile("value = choose()\nvalue = value + 1", budgetHost)
  runtime = initRuntime(bounded, budgetHost)
  discard runtime.run()
  let work = runtime.workUsed
  let instructions = runtime.instructionsUsed
  for restrictWork in [true, false]:
    var limits = defaultLimits()
    if restrictWork:
      limits.maxWorkUnits = work
    else:
      limits.maxInstructions = instructions
    runtime = initRuntime(bounded, budgetHost, limits)
    discard runtime.run()
    doAssert runtime.hostCallPaused
    runtime.resumeHostCall(10)
    doAssertRaises(BasicError):
      discard runtime.run()
echo "Nested return registers, discarded results, restart, and budget exhaustion passed"
