import std/[os, json, strutils]
import examples/gods_of_the_arena/[replays, sim, maps, bots, content]
import polyworld/cli

# Exact prefix, then one fresh-VM decision and at most 24 held-order ticks.
# This is a bounded counterfactual diagnostic, never a hosted match result.
# Args: source replay tick heroId [intact-fort|distant]
let data = loadReplay(paramStr(2))
let stopTick = parseInt(paramStr(3))
let game = newGame(generateMap(data.config.seed, data.config.mapPreset),
  data.header.setup.spawnIntervalTicks.int32, data.header.setup.heroes.len, true, data)
game.historyPlayback = true
game.replayPlayer = initReplayPlayer(data)
for tick in 1 .. stopTick:
  game.tickWorld(proc() = discard)
doAssert game.hashCheck.mismatches == 0
let index = game.world.heroIndex(parseInt(paramStr(4)).int32)
doAssert index >= 0
let hero = game.world.heroes[index]
let enemyTeam = if hero.team == RedTeam: BlueTeam else: RedTeam
let fortIndex = enemyTeam.ord
let mode = if paramCount() >= 5: paramStr(5) else: "unchanged-state"
if mode == "intact-fort":
  game.world.forts[fortIndex].hp = 400
elif mode == "distant":
  hero.place(game.world.forts[hero.team.ord].center)
else:
  doAssert mode == "unchanged-state"
let fortBefore = game.world.forts[fortIndex].hp
let hpBefore = hero.hp
game.historyPlayback = false
game.loadBots([BotGroup(count: game.world.heroes.len, path: paramStr(1))])
for i in 0 ..< game.heroVms.len:
  if i != index: game.heroVms[i] = nil
game.runBotDecisions()
doAssert not game.heroVms[index].failed
let target = hero.attackObjectId
let decisionMove = [hero.moveTileX, hero.moveTileY]
var advanced = 0
while advanced < 24 and not game.world.gameOver:
  game.tickWorld(proc() = discard)
  inc advanced
echo $(%*{"scope": "fresh-VM decision then at most 24 ticks with held orders",
  "mode": mode, "prefixTicks": stopTick, "prefixHashMismatches": 0,
  "heroId": hero.id, "hpBefore": hpBefore, "hpAfter": hero.hp,
  "selectedTarget": target, "decisionMove": decisionMove,
  "fortHpBefore": fortBefore, "fortHpAfter": game.world.forts[fortIndex].hp,
  "advancedTicks": advanced, "gameOver": game.world.gameOver})
