## Isolated mechanism checks against the real BASIC VM and GotA host.
## These constructed fixtures are not games, scores, or evidence of XP benefit.
## Build: POLYWORLD_DEPS=tmp/coworld/deps nim c -d:headless -d:replayEvents
##   --out:tmp/replay_tools/test_recovery_reset experiments/rowdaboat/tools/test_recovery_reset.nim
## Run: tmp/replay_tools/test_recovery_reset <candidate.bas> [receipt.json]
import std/[os, json, sha1]
import bassy
import polyworld/[cli, tapes]
import ../../../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

if paramCount() notin 1 .. 2:
  quit("Usage: test_recovery_reset <candidate.bas> [receipt.json]", 1)
let policy = absolutePath(paramStr(1))
doAssert fileExists(policy), policy

type Fixture = object
  game: Game
  hero, enemy: Hero
  vm: HeroVm

var
  checks = newJArray()
  cadences = newJArray()
  maximumInstructions, maximumWork: int64
proc passed(name: string) =
  checks.add %name
  echo "PASS ", name

proc reveal(world: World) =
  for cells in world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255

proc findIndex(f: Fixture): int32 =
  for index in 0 ..< f.game.world.worldObjectCount(f.hero.id):
    var value: WorldObject
    doAssert f.game.world.worldObjectAt(f.hero.id, index, value)
    if value.id == f.enemy.id:
      return index.int32
  raise newException(ValueError, "fixture enemy not observed")

proc fixture(class = Warlock, team = RedTeam): Fixture =
  result.game = newGame(generateMap(7), 100_000, 10, false,
    ReplayData(), drafting = false)
  let game = result.game
  game.loadBots([BotGroup(path: policy, count: 10)])
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  result.hero = game.world.heroes[0]
  result.enemy = game.world.heroes[5]
  result.vm = game.heroVms[0]
  for i, hero in game.world.heroes:
    hero.team = if i < 5: team else: Team(1 - team.ord)
    hero.class = class
    hero.refreshHeroStats()
    hero.gold = 0
    hero.hp = 0
    hero.state = Dying
    if i != 0:
      game.heroVms[i] = nil
  for building in game.world.buildings.mitems:
    building.hp = 0
  game.world.syncBuildings()
  game.world.footmen.setLen(0)
  game.world.camps.setLen(0)
  game.world.spawnTimerTicks = 100_000
  let sign = if team == RedTeam: 1'i32 else: -1'i32
  result.hero.place(WorldPoint(x: -570_000 * sign, z: 630_000 * sign))
  result.enemy.place(WorldPoint(x: -510_000 * sign, z: 630_000 * sign))
  result.hero.hp = result.hero.maxHp
  result.hero.state = Fighting
  result.hero.attackObjectId = result.enemy.id
  result.enemy.hp = 100_000
  result.enemy.maxHp = 100_000
  result.enemy.state = Marching
  result.enemy.controls[StunControl].ends = 10_000
  game.world.tick = 100
  game.world.heroTurnTicks = 1
  game.world.reveal()
  result.vm.runtime.setGlobal("initialized", 1)
  result.vm.runtime.setGlobal("nextThink", 1000)
  result.vm.runtime.setGlobal("bestId", result.enemy.id)
  result.vm.runtime.setGlobal("targetIndex", result.findIndex())

proc assertVm(f: Fixture) =
  doAssert not f.vm.failed, f.vm.lastError
  doAssert f.vm.lastInstructions <= f.vm.limits.maxInstructions
  doAssert f.vm.lastWork <= f.vm.limits.maxWorkUnits
  maximumInstructions = max(maximumInstructions, f.vm.lastInstructions)
  maximumWork = max(maximumWork, f.vm.lastWork)

proc decide(f: Fixture) =
  inc f.game.world.tick
  f.game.world.reveal()
  f.game.runBotDecisions()
  f.assertVm()

proc seedHit(f: Fixture) =
  f.hero.attacksLanded = 1
  f.hero.damageLanded = true
  f.hero.swingTicks = f.game.world.heroHitTicks(f.hero)

proc assertNoCommands(f: Fixture, label: string) =
  f.decide()
  doAssert f.game.recorder.data.actions.len == 0, label
  passed(label)

# A real impact precedes the hook. Only a handful of combat ticks are advanced;
# the policy's ordinary six-tick work is held closed by the fixture's nextThink.
for class in HeroClass:
  for team in Team:
    let f = fixture(class, team)
    let windup = f.game.world.heroHitTicks(f.hero)
    f.hero.swingTicks = windup - 1
    f.hero.damageLanded = false
    f.game.tickWorld(nil)
    doAssert f.hero.attacksLanded == 1
    let hitTick = f.game.world.tick
    let before = f.hero.position
    f.game.tickWorld(proc() = f.game.runBotDecisions())
    f.assertVm()
    doAssert f.game.recorder.data.actions.len == 1
    let walk = f.game.recorder.data.actions[0]
    doAssert walk.kind == ActionWalkTo
    doAssert walk.tick.int32 == hitTick + 1
    doAssert f.hero.lastActionError == NoActionError
    doAssert f.hero.swingTicks == -1
    doAssert f.hero.attackObjectId == 0
    doAssert abs(f.hero.position.x - before.x) <= f.hero.heroMoveSpeed()
    doAssert abs(f.hero.position.z - before.z) <= f.hero.heroMoveSpeed()
    f.game.tickWorld(proc() = f.game.runBotDecisions())
    f.assertVm()
    doAssert f.game.recorder.data.actions.len == 2
    let attack = f.game.recorder.data.actions[1]
    doAssert attack.kind == ActionAttackTarget
    doAssert attack.first == f.enemy.id
    doAssert attack.tick == walk.tick + 1
    doAssert f.hero.lastActionError == NoActionError
    doAssert f.hero.attackObjectId == f.enemy.id
    doAssert f.hero.swingTicks == 1
    for tick in 2 .. windup:
      f.game.tickWorld(nil)
    doAssert f.hero.attacksLanded == 2
    doAssert f.game.world.tick - hitTick == windup + 1
    doAssert f.game.world.tick - hitTick < f.game.world.heroAttackTicks(f.hero)
    cadences.add %*{"class": $class, "team": $team,
      "nativeAttackTicks": f.game.world.heroAttackTicks(f.hero),
      "windupTicks": windup,
      "observedHitIntervalTicks": f.game.world.tick - hitTick}
    passed($class & "/" & $team & ": actual hit -> accepted walk -> accepted attack; next hit after windup + 1")

block:
  let f = fixture()
  f.hero.swingTicks = 3
  f.hero.damageLanded = false
  f.assertNoCommands("windup without any hit does not reset")
block:
  let f = fixture()
  f.hero.attacksLanded = 4
  f.vm.runtime.setGlobal("resetSeenHits", 4)
  f.hero.swingTicks = 3
  f.hero.damageLanded = false
  f.assertNoCommands("old hit counter during a new windup does not reset")
block:
  let f = fixture()
  f.seedHit()
  f.vm.runtime.setGlobal("targetIndex", 9999)
  f.decide()
  doAssert f.game.recorder.data.actions.len == 1
  doAssert f.game.recorder.data.actions[0].kind == ActionWalkTo
  doAssert f.vm.runtime.getGlobal("resetTarget") == f.enemy.id
  passed("stale out-of-bounds index resolves the same visible target ID")
block:
  let f = fixture()
  f.seedHit()
  f.vm.runtime.setGlobal("targetIndex", 0)
  f.decide()
  doAssert f.game.recorder.data.actions.len == 1
  doAssert f.game.recorder.data.actions[0].kind == ActionWalkTo
  doAssert f.vm.runtime.getGlobal("resetTarget") == f.enemy.id
  passed("index for a different object resolves the same visible target ID")
block:
  let f = fixture()
  f.seedHit()
  f.enemy.hp = 0
  f.enemy.state = Dying
  f.assertNoCommands("dead target does not reset")
block:
  let f = fixture()
  f.seedHit()
  f.enemy.team = f.hero.team
  f.assertNoCommands("target that became friendly does not reset")
block:
  let f = fixture()
  f.seedHit()
  for cells in f.game.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 0
  inc f.game.world.tick
  f.game.runBotDecisions()
  f.assertVm()
  doAssert f.game.recorder.data.actions.len == 0
  passed("target missing from visible objects does not reset")
block:
  let f = fixture()
  f.seedHit()
  f.hero.attackObjectId = 0
  f.assertNoCommands("hit with no current target does not reset")
block:
  let f = fixture()
  f.seedHit()
  f.vm.runtime.setGlobal("bestId", 0)
  f.assertNoCommands("host-acquired target absent from policy selection does not reset")
block:
  let f = fixture()
  f.seedHit()
  f.vm.runtime.setGlobal("retreating", 1)
  f.assertNoCommands("retreating policy does not reset")

for condition in ["dead", "channel", "stun", "root"]:
  let f = fixture()
  f.seedHit()
  case condition
  of "dead":
    f.hero.hp = 0
    f.hero.state = Dying
  of "channel": f.hero.portalEnds = 200
  of "stun": f.hero.controls[StunControl].ends = 200
  of "root": f.hero.controls[RootControl].ends = 200
  else: discard
  f.assertNoCommands(condition & " prevents reset")
  f.hero.hp = f.hero.maxHp
  f.hero.state = Fighting
  f.hero.portalEnds = 0
  f.hero.controls[StunControl].ends = 0
  f.hero.controls[RootControl].ends = 0
  f.assertNoCommands(condition & " release does not replay the stale hit")

block:
  let f = fixture()
  f.seedHit()
  f.decide()
  doAssert f.game.recorder.data.actions.len == 1
  doAssert f.game.recorder.data.actions[0].kind == ActionWalkTo
  f.enemy.hp = 0
  f.enemy.state = Dying
  f.decide()
  doAssert f.vm.runtime.getGlobal("resetTarget") == 0
  for action in f.game.recorder.data.actions:
    doAssert action.kind != ActionAttackTarget or action.first != f.enemy.id
  passed("target dying after reset walk is not reattacked")

block:
  let f = fixture()
  f.seedHit()
  f.decide()
  let oldIndex = f.vm.runtime.getGlobal("resetTargetIndex")
  let other = f.game.world.heroes[6]
  let oldEnemyPosition = f.enemy.position
  f.enemy.place(other.position)
  other.place(oldEnemyPosition)
  f.game.world.thawObservations()
  doAssert f.findIndex() != oldIndex
  f.decide()
  doAssert f.game.recorder.data.actions.len == 2
  doAssert f.game.recorder.data.actions[1].kind == ActionAttackTarget
  doAssert f.game.recorder.data.actions[1].first == f.enemy.id
  doAssert f.hero.lastActionError == NoActionError
  passed("object reorder after reset walk resolves the same stable target ID")

block:
  let f = fixture()
  f.seedHit()
  f.decide()
  f.hero.controls[StunControl].ends = 200
  f.decide()
  doAssert f.vm.runtime.getGlobal("resetTarget") == 0
  doAssert f.game.recorder.data.actions.len == 1
  passed("stun between reset walk and attack cancels the pending attack")

block:
  let f = fixture()
  f.seedHit()
  f.decide()
  f.hero.controls[RootControl].ends = 200
  f.decide()
  doAssert f.vm.runtime.getGlobal("resetTarget") == 0
  doAssert f.game.recorder.data.actions.len == 2
  doAssert f.game.recorder.data.actions[1].kind == ActionAttackTarget
  doAssert f.game.recorder.data.actions[1].first == f.enemy.id
  doAssert f.hero.lastActionError == NoActionError
  passed("root after accepted walk permits the legal same-target reattack")

block:
  let f = fixture()
  f.seedHit()
  f.vm.runtime.setGlobal("bestId", 99_999)
  f.vm.runtime.setGlobal("targetIndex", -1)
  f.hero.attackObjectId = 99_999
  for index in 0 ..< 500:
    f.game.world.footmen.add Footman(id: 1000 + index.int32,
      team: f.enemy.team, hp: 100, state: Marching,
      position: f.enemy.position)
  f.assertNoCommands("missing target in 500-unit observation stops at bounded lookup")
  doAssert f.vm.runtime.getGlobal("resetProbe") == 192

block:
  let f = fixture()
  f.seedHit()
  f.vm.runtime.setGlobal("bestId", 99_999)
  f.vm.runtime.setGlobal("targetIndex", -1)
  f.vm.runtime.setGlobal("nextThink", 0)
  f.hero.attackObjectId = 99_999
  for index in 0 ..< 500:
    f.game.world.footmen.add Footman(id: 1000 + index.int32,
      team: f.enemy.team, hp: 100, state: Marching,
      position: f.enemy.position)
  f.decide()
  doAssert f.vm.runtime.getGlobal("resetProbe") == 192
  doAssert f.vm.runtime.getGlobal("nextThink") == f.game.world.tick + 6
  passed("bounded missing-target lookup plus full ordinary turn stays within VM budgets")

let receipt = %*{
  "policy": policy,
  "policySha1": $secureHashFile(policy),
  "purpose": "Isolated VM/host mechanism evidence only; no local game scores or XP comparison",
  "checksPassed": checks.len,
  "checks": checks,
  "cadences": cadences,
  "maximumInstructionsObserved": maximumInstructions,
  "maximumWorkObserved": maximumWork
}
if paramCount() == 2:
  writeFile(paramStr(2), receipt.pretty & "\n")
echo "Mechanism checks passed: ", checks.len, "; no score measured."
