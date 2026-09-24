import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/cli

when defined(llmCta):
  import ../examples/call_to_adventure/[bots, content, sim]
elif defined(llmLvd):
  import ../examples/light_vs_dark/[bots, content, maps, sim]
else:
  import ../examples/gods_of_the_arena/[bots, maps, replays, sim]

const Program = """
remoteAvailable = llmAvailable()
quoted$ = jsonQuote$("hello")
text$ = jsonGet$(quoted$, "")
sent = sendChat(-2, "global hello")
message$ = pullMailbox$()
from = mailboxId()
while mailboxCount() > 0
  ignored$ = pullMailbox$()
wend
"""

echo "Testing LLM and mailbox functions through the game's actual BASIC hosts and loaders"
block:
  let
    directory = createTempDir("polyworld-llm-hosts-", "")
    path = directory / "player.bas"
    hadSetting = existsEnv("COGAME_LLM")
    setting = getEnv("COGAME_LLM")
  putEnv("COGAME_LLM", "off")
  defer:
    removeDir(directory)
    if hadSetting:
      putEnv("COGAME_LLM", setting)
    else:
      delEnv("COGAME_LLM")
  writeFile(path, Program)
  when defined(llmCta):
    let game = newGame(2026)
  elif defined(llmLvd):
    let game = newGame(generateMap(DefaultSeed), 240)
  else:
    let game = newGame(generateMap(54), 240, 10, false, ReplayData(),
      drafting = false)

  when defined(llmLvd):
    game.loadBots([Program, Program])
  elif defined(llmCta):
    game.loadBots([BotGroup(path: path, count: PartySize)])
  else:
    game.loadBots([BotGroup(path: path, count: 10)])
  for tick in 1 .. 2:
    game.world.tick = int32(tick)
    when defined(llmCta):
      for slot in 0'i32 ..< PartySize:
        game.runBotDecisions(slot)
    else:
      game.runBotDecisions()
    when defined(llmLvd):
      let vms = game.brains
    else:
      let vms = game.heroVms
    for vm in vms:
      doAssert vm != nil and not vm.failed, vm.lastError
      doAssert vm.runtime.getGlobal("remoteAvailable") == 0
      doAssert vm.runtime.getGlobal("sent") == vms.len
      doAssert vm.runtime.getGlobal("from") == -2
      doAssert vm.runtime.getString(vm.runtime.getGlobalValue("message$")) ==
        "global hello"
      doAssert vm.runtime.getString(vm.runtime.getGlobalValue("text$")) == "hello"
      doAssert vm.pollRequests != nil and not vm.pollRequests()
      let large = vm.runtime.putString(repeat('x', 64 * 1024))
      doAssert vm.runtime.getString(large).len == 64 * 1024
