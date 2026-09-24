import
  bassy,
  polyworld/scripts

echo "Testing string reclamation preserves globals, arrays, and host data"
block:
  var host = initHost()
  discard host.addData("incoming$", "host value")
  let program = compile("""
dim saved$(2)
if turns = 0 then
  saved$(0) = "persistent text"
  saved$(1) = mid$(saved$(0), 2, 4)
end if
turns = turns + 1
message$ = "turn " + str$(turns) + incoming$
saved$(2) = message$
""", host)
  var runtime = initRuntime(program, host)
  for i in 1 .. 1000:
    runtime.restartScript()
    discard runtime.run()
    doAssert runtime.getGlobal("turns") == i
    doAssert runtime.getStringArray("saved$", 0) == "persistent text"
    doAssert runtime.getStringArray("saved$", 1) == "ersi"
    doAssert runtime.getStringArray("saved$", 2) ==
      "turn  " & $i & "host value"
    doAssert runtime.getStringData("incoming$") == "host value"
    doAssert runtime.stringCount < 32
    doAssert runtime.stringBytes < 256
