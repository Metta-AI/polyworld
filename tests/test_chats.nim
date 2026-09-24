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
  doAssert game.mailboxes != nil
  doAssert game.mailboxes.send(0, TeamMailboxId, "team") == teamCount
  for slot in 0 ..< game.mailboxes.players:
    let message = game.mailboxes.pull(slot)
    doAssert (message.text == "team") ==
      (game.mailboxes.teams[slot] == game.mailboxes.teams[0])
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
  gota.checkMailboxes(5)

  let cta = ctaSim.newGame(2026)
  ctaBots.loadBots(cta, [BotGroup(path: path, count: ctaContent.PartySize)])
  cta.checkMailboxes(ctaContent.PartySize)

  let lvd = lvdSim.newGame(lvdMaps.generateMap(lvdContent.DefaultSeed), 240)
  lvdBots.loadBots(lvd, [Program, Program])
  lvd.checkMailboxes(1)
