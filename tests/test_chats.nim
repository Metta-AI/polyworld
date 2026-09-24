import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/[cli, mailboxes]

when defined(mailboxCta):
  import ../examples/call_to_adventure/[bots, content, sim]
elif defined(mailboxLvd):
  import ../examples/light_vs_dark/[bots, content, maps, sim]
else:
  import ../examples/gods_of_the_arena/[bots, maps, replays, sim]

const Program = """
sent = sendChat(mailboxSelf(), "private hello")
message$ = pullMailbox$()
from = mailboxId()
"""

echo "Testing mailbox functions through the game's actual BASIC hosts and loaders"
block:
  let
    directory = createTempDir("polyworld-mailboxes-", "")
    path = directory / "player.bas"
  defer:
    removeDir(directory)
  writeFile(path, Program)
  when defined(mailboxCta):
    let game = newGame(2026)
  elif defined(mailboxLvd):
    let game = newGame(generateMap(DefaultSeed), 240)
  else:
    let game = newGame(generateMap(54), 240, 10, false, ReplayData(),
      drafting = false)

  when defined(mailboxLvd):
    game.loadBots([Program, Program])
  elif defined(mailboxCta):
    game.loadBots([BotGroup(path: path, count: PartySize)])
  else:
    game.loadBots([BotGroup(path: path, count: 10)])
  doAssert game.mailboxes != nil
  let teamCount =
    when defined(mailboxCta): PartySize
    elif defined(mailboxLvd): 1
    else: 5
  doAssert game.mailboxes.send(0, TeamMailboxId, "team") == teamCount
  for slot in 0 ..< game.mailboxes.players:
    let message = game.mailboxes.pull(slot)
    doAssert (message.text == "team") ==
      (game.mailboxes.teams[slot] == game.mailboxes.teams[0])
  for tick in 1 .. 2:
    game.world.tick = int32(tick)
    when defined(mailboxCta):
      for slot in 0'i32 ..< PartySize:
        game.runBotDecisions(slot)
    else:
      game.runBotDecisions()
    when defined(mailboxLvd):
      let vms = game.brains
    else:
      let vms = game.heroVms
    for index, vm in vms:
      doAssert vm != nil and not vm.failed, vm.lastError
      doAssert vm.runtime.getGlobal("sent") == 1
      doAssert vm.runtime.getGlobal("from") == index
      doAssert vm.runtime.getString(vm.runtime.getGlobalValue("message$")) ==
        "private hello"
      let large = vm.runtime.putString(repeat('x', 1024))
      doAssert vm.runtime.getString(large).len == 1024
