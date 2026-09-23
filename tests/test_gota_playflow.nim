## No window is opened: verify the graphical client's default setup and rematch.
import polyworld/cli,
  ../examples/gods_of_the_arena/[game, sim, replays, controls, bots, content]

echo "Testing no-argument play fills nine bots and pauses at hero selection"
doAssert options.playerSlot == 2 and setupOpen and practiceMode
doAssert options.botGroups.len == 1 and options.botGroups[0].path == "@baseline"

echo "Testing hero selection applies practice to the opposing team only"
restartHumanGame(7)
let hero = run.world.heroes[6]
doAssert hero.manualSpells and run.heroVms[6] == nil
doAssert practiceEnemyTeam == RedTeam.ord
var draftTicks = 0
while run.world.phase == Drafting and draftTicks < 3000:
  if run.world.draftHeroId() == hero.id:
    for class in HeroClass:
      if run.world.heroAvailable(class.ord.int32):
        queueDraft(hero.id, class.ord.int32)
        break
  advanceGame()
  inc draftTicks
doAssert run.world.phase == Playing
var decisionsBefore: array[10, int]
for i, vm in run.heroVms:
  if vm != nil:
    decisionsBefore[i] = vm.decisions
for tick in 0 ..< 120:
  if tick mod 24 == 0:
    queueCastPoint(hero.id, PrimaryAbility.ord, mapCoordinate(hero.position.x),
      mapCoordinate(hero.position.z) - 3)
  advanceGame()
for i, vm in run.heroVms:
  if i == 6: continue
  doAssert not vm.failed, vm.lastError
  if run.world.heroes[i].team == RedTeam:
    doAssert vm.decisions - decisionsBefore[i] == 10,
      "every practice opponent must get a decision"
    doAssert run.world.heroes[i].manualSpells
  else:
    doAssert vm.decisions - decisionsBefore[i] == 120 and
      not run.world.heroes[i].manualSpells

echo "Testing practice decisions and casts replay with identical hashes"
let tape = decodeReplay(run.recorder.data.encodeReplay())
let replay = newGame(run.map, options.spawnIntervalTicks, 10, true, tape)
replay.historyPlayback = true
replay.replayPlayer = initReplayPlayer(tape)
for tick in 0 ..< tape.hashes.len: replay.tickWorld(nil)
doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
doAssert replay.stateHash == run.stateHash

echo "Testing rematch clears input, restores the camera, and changes difficulty"
queueWalkTo(hero.id, 64, 64)
armedAbility = 2
followPlayer = false
historyOpen = true
practiceMode = false
restartHumanGame(2)
doAssert run.world.tick == 0 and options.playerSlot == 2
doAssert followPlayer and focusPlayerRequested and not historyOpen and armedAbility == -1
doAssert practiceEnemyTeam == -1
for i, other in run.world.heroes:
  doAssert other.manualSpells == (i == 1)
flushPlayerCommands(run)
doAssert run.recorder.data.actions.len == 0
echo "Human play flow tests passed"
