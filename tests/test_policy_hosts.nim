## Non-LLM games expose exactly the same optional policy capabilities.
import bassy
import ../games/heartleaf/bots as heartleafBots
import ../games/cac/src/core/bots as cacBots

for host in [heartleafBots.buildVillagerHost(0), cacBots.botSchema()]:
  let program = compile("""
status = ANNOTATE(123, "intent", "test", "{}")
message$ = ANNOTATE_ERROR$()
after = 42
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobal("status") == 1
  doAssert runtime.getGlobal("after") == 42
  doAssert runtime.getString(runtime.getGlobalValue("message$")) ==
    "No annotation destination"
echo "Heartleaf and CaC expose the shared annotation API without an LLM client"
