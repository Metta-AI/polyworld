## T002 isolated BASIC/host fixtures. No complete games or local scores.
## Build with pinned POLYWORLD_DEPS, -d:headless and -d:replayEvents.
## Usage: test_camp_route <candidate.bas> [receipt.json]
import std/[os, json, sha1]
import bassy
import polyworld/[cli, tapes]
import ../../../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

if paramCount() notin 1 .. 2:
  quit("Usage: test_camp_route <candidate.bas> [receipt.json]", 1)
let policy = absolutePath(paramStr(1))
doAssert fileExists(policy)

type Fixture = object
  game: Game
  hero: Hero
  vm: HeroVm

var
  checks = newJArray()
  maximumInstructions, maximumWork: int64

proc passed(name: string) =
  checks.add %name
  echo "PASS ", name

proc value(f: Fixture, name: string): int32 = f.vm.runtime.getGlobal(name)
proc set(f: Fixture, name: string, value: int32) =
  f.vm.runtime.setGlobal(name, value)

proc fixture(team = RedTeam, seed = 54): Fixture =
  result.game = newGame(generateMap(seed.int32), 100_000, 10, false,
    ReplayData(), drafting = false)
  let game = result.game
  game.loadBots([BotGroup(path: policy, count: 10)])
  let index = team.ord * 5
  result.hero = game.world.heroes[index]
  result.vm = game.heroVms[index]
  for i, hero in game.world.heroes:
    hero.gold = 0
    if i != index:
      game.heroVms[i] = nil
      hero.hp = 0
      hero.state = Dying
  for building in game.world.buildings.mitems:
    if building.team != team:
      building.hp = 0
  game.world.syncBuildings()
  game.world.footmen.setLen(0)
  game.world.spawnTimerTicks = 100_000
  game.world.tick = 100
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  for cells in game.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255

proc decide(f: Fixture, advance = 6'i32): seq[ReplayAction] =
  f.game.world.tick += advance
  let before = f.game.recorder.data.actions.len
  f.game.runBotDecisions()
  doAssert not f.vm.failed, f.vm.lastError
  doAssert f.vm.lastInstructions <= f.vm.limits.maxInstructions
  doAssert f.vm.lastWork <= f.vm.limits.maxWorkUnits
  maximumInstructions = max(maximumInstructions, f.vm.lastInstructions)
  maximumWork = max(maximumWork, f.vm.lastWork)
  f.game.recorder.data.actions[before ..< f.game.recorder.data.actions.len]

proc contains(actions: seq[ReplayAction], kind: uint8, target = -1'i32): bool =
  for action in actions:
    if action.kind == kind and (target < 0 or action.first == target):
      return true

proc squared(a, b: WorldPoint): int64 =
  let dx = int64(a.x) - b.x
  let dz = int64(a.z) - b.z
  dx * dx + dz * dz

proc campMember(f: Fixture, camp: int, id = 9999'i32) =
  let world = f.game.world
  world.camps[camp].started = true
  world.camps[camp].state = RestingCamp
  var unit = Footman(id: id, team: f.hero.team, hp: 100,
    camp: camp.int32 + 1, campTier: 1, state: Marching, swingTicks: -1)
  unit.place(world.camps[camp].center)
  unit.home = unit.position
  world.footmen.add unit

proc placeAtCamp(f: Fixture, camp: int) =
  f.hero.place(f.game.world.camps[camp].center)
  f.hero.attackObjectId = 0
  f.hero.hasMoveTarget = false
  f.set("orderTick", 0)

for seed in [7, 54]:
  for team in Team:
    let f = fixture(team, seed)
    let actions = f.decide()
    let first = f.value("farmGoal")
    doAssert first >= 0 and first < f.game.world.camps.len
    let selected = f.game.world.camps[first]
    doAssert selected.tier == 1
    doAssert squared(selected.center, f.game.world.forts[team.ord].center) <
      squared(selected.center, f.game.world.forts[1 - team.ord].center)
    doAssert actions.contains(ActionAttackMove)
    doAssert f.hero.lastActionError == NoActionError
    doAssert abs(f.hero.moveTileX - mapCoordinate(selected.center.x, team)) <= 1
    doAssert abs(f.hero.moveTileY - mapCoordinate(selected.center.z, team)) <= 1
    doAssert f.value("farmTripLeft") == 2
    passed("seed " & $seed & "/" & $team & ": accepted departure to home-side tier1 camp")

    # The same accepted navigation order is cached, without treating it as failure.
    let cached = f.decide()
    doAssert not cached.contains(ActionAttackMove)
    doAssert f.value("farmGoal") == first and f.value("farmMoving") == 1
    passed("seed " & $seed & "/" & $team & ": cached camp order remains active")

    f.placeAtCamp(first)
    f.campMember(first)
    let combat = f.decide()
    doAssert f.value("bestId") == 9999 and f.value("bestKind") == 6
    doAssert combat.contains(ActionAttackTarget, 9999)
    doAssert f.hero.attackObjectId == 9999
    doAssert f.hero.lastActionError == NoActionError
    passed("seed " & $seed & "/" & $team & ": visible member acquired through normal combat")

    f.game.world.footmen[0].hp = 0
    f.game.world.footmen[0].state = Dying
    let departure = f.decide()
    let second = f.value("farmGoal")
    doAssert second >= 0 and second != first
    doAssert f.value("farmDeferred") == 1
    doAssert f.vm.runtime.getArray("farmRetry", first) == f.game.world.tick + 60 * TickRate
    doAssert departure.contains(ActionAttackMove)
    doAssert squared(f.game.world.camps[first].center,
      f.game.world.camps[second].center) > int64(12 * WorldScale) * (12 * WorldScale)
    passed("seed " & $seed & "/" & $team & ": no visible opportunity departs for another camp")

    f.placeAtCamp(second)
    let lane = f.decide()
    doAssert f.value("farmGoal") == -1 and f.value("farmTripLeft") == 0
    doAssert f.value("farmLaneUntil") > f.game.world.tick
    doAssert lane.contains(ActionAttackMove)
    let goal = WorldPoint(x: (f.hero.moveTileX.int32 - mapTiles().int32 div 2) * WorldScale,
      z: (f.hero.moveTileY.int32 - mapTiles().int32 div 2) * WorldScale)
    doAssert squared(goal, f.game.world.camps[second].center) >
      int64(10 * WorldScale) * (10 * WorldScale)
    passed("seed " & $seed & "/" & $team & ": second unavailable visit immediately yields to lane")

    # Preserve observation-based deferrals across death and restart the departure route.
    let retry = f.vm.runtime.getArray("farmRetry", first)
    f.hero.hp = 0
    f.hero.state = Dying
    discard f.decide()
    f.hero.hp = f.hero.maxHp
    f.hero.mana = f.hero.maxMana
    f.hero.state = Marching
    f.hero.place(f.game.world.heroSpawns[team.ord])
    discard f.decide()
    doAssert f.vm.runtime.getArray("farmRetry", first) == retry
    doAssert f.value("farmGoal") != first
    doAssert f.value("farmDeparture") == 1 or f.value("farmGoal") == -1
    passed("seed " & $seed & "/" & $team & ": respawn preserves retry history and restarts route")

block:
  let f = fixture()
  discard f.decide()
  let camp = f.value("farmGoal")
  f.placeAtCamp(camp)
  # Put the camp member past the ordinary first96 objects but inside the
  # dedicated192 bound; all filler creeps are harmless allies.
  for index in 0 ..< 100:
    f.game.world.footmen.add Footman(id: 2000 + index.int32, team: f.hero.team,
      hp: 100, state: Marching, position: f.hero.position)
  f.campMember(camp)
  f.set("scanOffset", 0)
  f.hero.abilityLevels[PrimaryAbility] = 1
  f.hero.charges[PrimaryAbility] = 1
  f.hero.cooldowns[PrimaryAbility] = 0
  f.hero.mana = f.hero.maxMana
  let actions = f.decide()
  doAssert f.value("targetIndex") >= 96
  doAssert f.value("bestId") == 9999 and f.value("bestKind") == 6
  doAssert actions.contains(ActionAttackTarget, 9999)
  var spell = false
  for action in actions:
    if action.kind == ActionCastTarget and action.first == 9999:
      spell = true
  doAssert spell, "camp rescan must publish target fields before spells"
  passed("active camp beyond ordinary scan is acquired before normal spell selection")

block:
  let f = fixture()
  discard f.decide()
  let camp = f.value("farmGoal")
  f.placeAtCamp(camp)
  f.campMember(camp)
  f.game.world.camps[camp].state = ReturningCamp
  let actions = f.decide()
  doAssert not actions.contains(ActionAttackTarget, 9999)
  doAssert f.value("farmGoal") != camp
  doAssert f.value("farmDeferred") == 2
  passed("returning-only camp is deferred without attacking or claiming a clear")

block:
  let f = fixture()
  discard f.decide()
  let camp = f.value("farmGoal")
  f.placeAtCamp(camp)
  f.hero.hp = f.hero.maxHp * 6 div 10
  discard f.decide()
  doAssert f.value("farmGoal") == -1 and f.value("farmMoving") == 0
  doAssert f.value("retreating") == 0
  doAssert f.value("farmDeferred") == 4
  doAssert f.vm.runtime.getArray("farmRetry", camp) > f.game.world.tick
  passed("insufficient neutral-start health yields to baseline lane without new retreat threshold")

block:
  let f = fixture()
  f.hero.inventory[0] = PortalScroll
  f.hero.itemCounts[0] = 1
  let actions = f.decide()
  doAssert f.hero.canShop
  doAssert f.value("forwardDistance") < 1000000
  doAssert actions.contains(ActionAttackMove)
  doAssert not actions.contains(ActionUseItemAt)
  doAssert f.value("farmGoal") >= 0
  passed("camp departure runs before existing forward portal can bypass it")

block:
  let f = fixture()
  discard f.decide()
  let camp = f.value("farmGoal")
  f.placeAtCamp(camp)
  for index in 0 ..< 500:
    f.game.world.footmen.add Footman(id: 2000 + index.int32,
      team: f.hero.team, hp: 100, state: Marching, position: f.hero.position)
  discard f.decide()
  doAssert f.value("farmScanComplete") == 0 and f.value("farmGoal") == camp
  discard f.decide(2 * TickRate)
  doAssert f.value("farmDeferred") == 3 and f.value("farmGoal") != camp
  passed("500-object partial scan defers within two seconds, without false absence proof or VM overflow")

block:
  let f = fixture()
  discard f.decide()
  let camp = f.value("farmGoal")
  let deadline = f.value("farmDeadline")
  discard f.decide(deadline - f.game.world.tick)
  doAssert f.value("farmGoal") != camp and f.value("farmDeferred") == 5
  doAssert f.vm.runtime.getArray("farmRetry", camp) > f.game.world.tick
  passed("unreached camp objective expires after bounded travel time")

block:
  let f = fixture()
  discard f.decide()
  let camp = f.value("farmGoal")
  f.hero.place(WorldPoint(x: 1000 * WorldScale, z: 1000 * WorldScale))
  f.hero.hasMoveTarget = false
  f.hero.moveRevision = -1
  f.set("orderTick", 0)
  discard f.decide()
  doAssert f.value("farmGoal") == -1 and f.value("farmDeferred") == 6
  doAssert f.vm.runtime.getArray("farmRetry", camp) > f.game.world.tick
  discard f.decide()
  doAssert f.value("farmGoal") != camp
  passed("rejected route defers the unreachable camp and does not repeat that objective")

block:
  let f = fixture()
  discard f.decide()
  let camp = f.value("farmGoal")
  f.placeAtCamp(camp)
  discard f.decide()
  let retry = f.vm.runtime.getArray("farmRetry", camp)
  # Make this the only later eligible low camp; eligibility still comes from
  # public geometry and the same persistent observation-based retry array.
  for other in 0 ..< f.game.world.camps.len:
    if other != camp:
      f.vm.runtime.setArray("farmRetry", other.int32, retry + 10_000)
  let center = f.game.world.camps[camp].center
  f.hero.place(WorldPoint(x: center.x + 15 * WorldScale, y: center.y, z: center.z))
  f.set("farmGoal", -1)
  f.set("farmTripLeft", 0)
  f.set("farmDeparture", 0)
  f.set("farmLaneUntil", 0)
  discard f.decide()
  doAssert f.value("farmGoal") == -1
  discard f.decide(retry - f.game.world.tick + 16 * TickRate)
  doAssert f.value("farmGoal") == camp
  passed("nearby camp is skipped during observed retry window and revisited after lane interval")

let receipt = %*{"policy": policy, "policySha1": $secureHashFile(policy),
  "purpose": "Isolated VM/host route mechanism only; no local games or scores",
  "checksPassed": checks.len, "checks": checks,
  "maximumInstructionsObserved": maximumInstructions,
  "maximumWorkObserved": maximumWork}
if paramCount() == 2:
  writeFile(paramStr(2), receipt.pretty & "\n")
echo "Mechanism checks passed: ", checks.len, "; no score measured."
