import
  std/[os, strutils, tempfiles],
  bassy,
  polyworld/[cli, mailboxes]
import ../examples/call_to_adventure/bots as ctaBots
import ../examples/call_to_adventure/content as ctaContent
import ../examples/call_to_adventure/sim as ctaSim
import ../examples/gods_of_the_arena/bots as gotaBots
import ../examples/gods_of_the_arena/maps as gotaMaps
import ../examples/gods_of_the_arena/replays as gotaReplays
import ../examples/gods_of_the_arena/sim as gotaSim
import ../examples/light_vs_dark/bots as lvdBots
import ../examples/light_vs_dark/content as lvdContent
import ../examples/light_vs_dark/maps as lvdMaps
import ../examples/light_vs_dark/sim as lvdSim

const Program = """
sent = sendChat(mailboxSelf(), "private hello")
message$ = pullMailbox$()
from = mailboxId()
"""

proc checkMailboxes[T](game: T, teamCount: int) =
  ## Checks default chat routing and repeated reads through a game's hosts.
  template send(sender, target, text: untyped): untyped =
    ## Uses the game's own routing implementation.
    when T is ctaSim.Game:
      ctaBots.sendChat(game, sender, target, text)
    elif T is gotaSim.Game:
      gotaBots.sendChat(game, sender, target, text)
    else:
      lvdBots.sendChat(game, sender, target, text)
  doAssert send(0, -1, "team") == teamCount
  var received = 0
  for slot, inbox in game.inboxes:
    when T is ctaSim.Game:
      let teammate = true
    elif T is gotaSim.Game:
      let teammate = game.world.heroes[slot].team == game.world.heroes[0].team
    else:
      let teammate = slot == 0
    doAssert inbox.count == int(teammate)
    if inbox.count > 0:
      inc received
      doAssert inbox.messages[inbox.first] == "team"
      doAssert inbox.pop() == -1
  doAssert received == teamCount
  doAssert send(0, -2, "global") == game.inboxes.len
  for inbox in game.inboxes:
    doAssert inbox.pop() == -2
  doAssert send(0, 1, "direct") == 1
  doAssert game.inboxes[1].messages[game.inboxes[1].first] == "direct"
  doAssert game.inboxes[1].pop() == 0
  doAssert send(0, game.inboxes.len, "invalid") == 0
  for i in 0 ..< MaxMailboxMessages:
    doAssert send(0, 0, "full") == 1
  doAssert send(0, -2, "partial") == game.inboxes.len - 1
  doAssert game.inboxes[0].count == MaxMailboxMessages
  for inbox in game.inboxes:
    while inbox.count > 0:
      discard inbox.pop()
  for tick in 1 .. 300:
    game.world.tick = int32(tick)
    when T is ctaSim.Game:
      for slot in 0'i32 ..< ctaContent.PartySize:
        ctaBots.runBotDecisions(game, slot)
    elif T is gotaSim.Game:
      gotaBots.runBotDecisions(game)
    else:
      lvdBots.runBotDecisions(game)
    when T is lvdSim.Game:
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
  when defined(nimAllocStats) and T is gotaSim.Game:
    # The GotA decision runner leaves its active game bound for host calls.
    # Isolate mailbox callbacks and restart from unrelated world preparation.
    let before = getAllocStats()
    for decision in 0 ..< 1000:
      for vm in game.heroVms:
        vm.runtime.restart()
        discard vm.runtime.run()
    let after = getAllocStats()
    doAssert after == before, $(after - before)

echo "Testing default mailboxes through all three games' BASIC hosts"
block:
  let
    directory = createTempDir("polyworld-mailboxes-", "")
    path = directory / "player.bas"
  defer:
    removeDir(directory)
  writeFile(path, Program)

  let gota = gotaSim.newGame(
    gotaMaps.generateMap(54),
    240,
    10,
    false,
    gotaReplays.ReplayData(),
    drafting = false
  )
  gotaBots.loadBots(gota, [BotGroup(path: path, count: 10)])
  echo "Checking GotA"
  gota.checkMailboxes(5)
  echo "GotA passed"

  let cta = ctaSim.newGame(2026)
  ctaBots.loadBots(cta, [BotGroup(path: path, count: ctaContent.PartySize)])
  echo "Checking CTA"
  cta.checkMailboxes(ctaContent.PartySize)
  echo "CTA passed"

  let lvd = lvdSim.newGame(lvdMaps.generateMap(lvdContent.DefaultSeed), 240)
  lvdBots.loadBots(lvd, [Program, Program])
  echo "Checking LVD"
  lvd.checkMailboxes(1)
  echo "LVD passed"
