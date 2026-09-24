import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/cli

when defined(advisorCta):
  import ../examples/call_to_adventure/[bots, content, sim]
elif defined(advisorLvd):
  import ../examples/light_vs_dark/[bots, content, maps, sim]
else:
  import ../examples/gods_of_the_arena/[bots, maps, replays, sim]

const Program = """
remoteAvailable = llmAvailable()
quoted$ = jsonQuote$("hello")
text$ = jsonGet$(quoted$, "")
sent = sendChat(mailboxSelf(), "private hello")
message$ = pullMailbox$()
from = mailboxId()
"""

echo "Testing LLM and mailbox functions through the game's actual BASIC hosts and loaders"
block:
  let
    directory = createTempDir("polyworld-advisors-", "")
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
  when defined(advisorCta):
    let game = newGame(2026)
  elif defined(advisorLvd):
    let game = newGame(generateMap(DefaultSeed), 240)
  else:
    let game = newGame(generateMap(54), 240, 10, false, ReplayData(),
      drafting = false)

  when defined(advisorLvd):
    game.loadBots([Program, Program])
  elif defined(advisorCta):
    game.loadBots([BotGroup(path: path, count: PartySize)])
  else:
    game.loadBots([BotGroup(path: path, count: 10)])
  for tick in 1 .. 2:
    game.world.tick = int32(tick)
    when defined(advisorCta):
      for slot in 0'i32 ..< PartySize:
        game.runBotDecisions(slot)
    else:
      game.runBotDecisions()
    when defined(advisorLvd):
      let vms = game.brains
    else:
      let vms = game.heroVms
    for index, vm in vms:
      doAssert vm != nil and not vm.failed, vm.lastError
      doAssert vm.runtime.getGlobal("remoteAvailable") == 0
      doAssert vm.runtime.getGlobal("sent") == 1
      doAssert vm.runtime.getGlobal("from") == index
      doAssert vm.runtime.getString(vm.runtime.getGlobalValue("message$")) ==
        "private hello"
      doAssert vm.runtime.getString(vm.runtime.getGlobalValue("text$")) == "hello"
      doAssert vm.pollRequests != nil and not vm.pollRequests()
      let large = vm.runtime.putString(repeat('x', 64 * 1024))
      doAssert vm.runtime.getString(large).len == 64 * 1024
