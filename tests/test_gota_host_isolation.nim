include ../examples/gods_of_the_arena/bots

let config = loadConfig("examples/gods_of_the_arena/presets/saved.json")
let bot = "examples/gods_of_the_arena/players/base.bas"

proc newMatch(seed: int32): Game =
  let map = generateMap(seed, config.mapPreset)
  result = newGame(map, config.spawnIntervalTicks, 10, false, ReplayData())
  loadBots(result, @[BotGroup(path: bot, count: 10)])
  result.recorder = initReplayRecorder(currentSetup(result, 120), map.preset)

let first = newMatch(10)
let firstHost = initHeroHost(first, first.world.heroes[0].id)
let source = "charges = abilityCharges(0)\nattackMove(10, 10)"
let program = compile(source, firstHost, heroVmLimits())
var firstRuntime = initRuntime(program, firstHost, heroVmLimits())
let second = newMatch(11)
let secondHost = initHeroHost(second, second.world.heroes[0].id)
var secondRuntime = initRuntime(program, secondHost, heroVmLimits())
first.world.heroes[0].charges[HeroAbilitySlot(0)] = 1
second.world.heroes[0].charges[HeroAbilitySlot(0)] = 3
first.world.phase = Playing
second.world.phase = Playing
first.world.tick = 1
second.world.tick = 1

let untouchedSecond = second.stateHash()
discard firstRuntime.run()
doAssert firstRuntime.getGlobal("charges") == 1
doAssert second.stateHash() == untouchedSecond
doAssert first.recorder.data.actions.len == 1
doAssert second.recorder.data.actions.len == 0
doAssert first.recorder.data.actions[0].kind == ActionAttackMove
doAssert first.metrics.read(0, 0).commands == 1
doAssert second.metrics.read(0, 0).commands == 0

let untouchedFirst = first.stateHash()
discard secondRuntime.run()
doAssert secondRuntime.getGlobal("charges") == 3
doAssert first.stateHash() == untouchedFirst
doAssert first.recorder.data.actions.len == 1
doAssert second.recorder.data.actions.len == 1
doAssert second.metrics.read(0, 0).commands == 1
firstRuntime.restart()
discard firstRuntime.run()
doAssert firstRuntime.getGlobal("charges") == 1
doAssert first.recorder.data.actions.len == 2
doAssert second.recorder.data.actions.len == 1

var released = 0
type LifetimeProbe = object
  marker: int
proc `=destroy`(probe: LifetimeProbe) =
  if probe.marker == 42:
    inc released

proc checkLifetime() =
  let game = newMatch(12)
  let probe = (ref LifetimeProbe)(marker: 42)
  var host = initHeroHost(game, game.world.heroes[0].id)
  discard host.addFunction("probe", 0, proc(values: openArray[int32]): int32 =
    int32(probe.marker), 1)
  let code = compile("value = probe()\ncharges = abilityCharges(0)", host, heroVmLimits())
  game.heroVms[0] = HeroVm(runtime: initRuntime(code, host, heroVmLimits()))
  discard game.heroVms[0].runtime.run()

checkLifetime()
GC_fullCollect()
doAssert released == 1, "Unreachable game/VM/host cycles must release captured references"
first.heroVms.setLen(0)
second.heroVms.setLen(0)
echo "Game-bound host queries, actions, replays, metrics, and captured lifetimes passed"
