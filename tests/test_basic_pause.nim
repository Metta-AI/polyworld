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
