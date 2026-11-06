## Deterministic player-wide research, through the authoritative action path.
import polyworld/tapes, ../[content, maps, replays, sim, controls, multiplayer]

let researchMap = generateMap(DefaultSeed)
proc run(w: World, ticks: int32) =
  for _ in 0 ..< ticks: w.tickWorld(nil)

proc laboratory(): World =
  result = newWorld(researchMap, TickRate * 600)
  result.players[0].gold = 20000
  result.players[0].wood = 20000
  # Reuse registered structures for an isolated research fixture.
  for building in result.buildings.mitems:
    if building.owner == 0: building.kind = BlacksmithBuilding
    elif building.owner == 1: building.kind = BarracksBuilding
  # A completed prerequisite owned by player zero, away from combat.
  var site = NoTile
  for y in 1'i32 ..< researchMap.side - 4:
    for x in 1'i32 ..< researchMap.side - 4:
      if result.canPlace(BarracksBuilding, x, y):
        site = tile2(x, y)
        break
    if site != NoTile: break
  doAssert result.applyBuild(0, result.units[0].id,
    BarracksBuilding.ord.int32, site.x.int32, site.y.int32)
  result.buildings[^1].state = BuildingComplete
  result.buildings[^1].hp = result.buildings[^1].maxHp
  doAssert result.applyCancel(0, result.units[0].id)

proc smith(w: World): int32 =
  for b in w.buildings:
    if b.owner == 0 and b.kind == BlacksmithBuilding: return b.id

block authoritativeResearchStarts:
  let w = laboratory()
  doAssert w.applyReplayAction(ReplayAction(kind: ActionResearch, playerId: 0,
    entityId: w.smith(), first: TemperedEdges.ord.int32)),
    "Research action must start at the owned completed Blacksmith"

block sequentialCompletion:
  let w = laboratory()
  let id = w.smith()
  for level in 1'i32 .. MaxResearchLevel:
    let beforeGold = w.players[0].gold
    let beforeWood = w.players[0].wood
    let cost = researchStats(TemperedEdges, level)
    doAssert w.applyResearch(0, id, TemperedEdges.ord.int32)
    doAssert w.players[0].gold == beforeGold - cost.gold
    doAssert w.players[0].wood == beforeWood - cost.wood
    doAssert not w.applyResearch(0, id, RunedPlating.ord.int32)
    w.run(cost.ticks - 1)
    doAssert w.researchLevel(0, TemperedEdges) == level - 1
    doAssert w.researchInProgress(0, TemperedEdges)
    w.run(1)
    doAssert w.researchLevel(0, TemperedEdges) == level
    doAssert not w.researchInProgress(0, TemperedEdges)
  doAssert not w.canResearch(0, id, TemperedEdges)

block cancellationAndDestruction:
  let w = laboratory()
  let id = w.smith()
  doAssert w.applyResearch(0, id, RunedPlating.ord.int32)
  let gold = w.players[0].gold
  doAssert w.applyCancel(0, id)
  doAssert w.players[0].gold == gold
  doAssert not w.researchInProgress(0, RunedPlating)
  doAssert w.applyResearch(0, id, RunedPlating.ord.int32)
  w.damageEntity(id, 100000)
  doAssert w.buildings[w.buildingIndex(id)].researchTicks == 0
  w.run(researchStats(RunedPlating, 1).ticks)
  doAssert w.researchLevel(0, RunedPlating) == 0

block passiveCombatAndMovement:
  let w = laboratory()
  for player in 0'i32 .. 1'i32:
    for level in 1'i32 .. MaxResearchLevel:
      for category in ResearchKind:
        w.players[player].researchLevels[category] = level
      for kind in UnitKind:
        let base = unitOf(player, kind)
        let actual = w.unitStats(player, kind)
        doAssert actual.armor == base.armor + 2 * level
        doAssert actual.basic == base.basic +
          (if kind in {SoldierUnit, KnightUnit, ClericUnit, MageUnit}: 2 * level else: 0)
        doAssert actual.piercing == base.piercing +
          (if kind == ArcherUnit: 2 * level else: 0)
        doAssert actual.hp == base.hp and actual.stepTicks == base.stepTicks
        let speed = w.unitMoveSpeed(player, kind)
        let baseSpeed = FixedOne / fixed(base.stepTicks)
        doAssert speed == (if kind == KnightUnit:
          baseSpeed * fixed(100 + 10 * level) / fixed(100) else: baseSpeed)

block researchStateIsHashedAndCloned:
  let w = laboratory()
  let baseline = Game(world: w).stateHash()
  w.players[0].researchLevels[RunedPlating] = 1
  doAssert Game(world: w).stateHash() != baseline, "Completed research is authoritative"
  w.players[0].researchLevels[RunedPlating] = 0
  let i = w.buildingIndex(w.smith())
  w.buildings[i].researchKind = TemperedEdges
  w.buildings[i].researchLevel = 1
  w.buildings[i].researchTicks = 3
  w.buildings[i].researchTotal = 3
  doAssert Game(world: w).stateHash() != baseline
  let snapshot = w.clone()
  for field in 0 .. 3:
    let altered = w.clone()
    case field
    of 0: altered.buildings[i].researchKind = RunedPlating
    of 1: altered.buildings[i].researchLevel = 2
    of 2: altered.buildings[i].researchTicks = 2
    else: altered.buildings[i].researchTotal = 4
    doAssert Game(world: altered).stateHash() != Game(world: snapshot).stateHash()
  w.run(3)
  doAssert w.researchLevel(0, TemperedEdges) == 1
  doAssert snapshot.researchLevel(0, TemperedEdges) == 0
  doAssert snapshot.buildings[i].researchTicks == 3
  w.restore(snapshot)
  doAssert Game(world: w).stateHash() == Game(world: snapshot).stateHash()

block controlQueueSubmitsWithoutLocalMutation:
  let game = newGame(researchMap, TickRate * 600)
  game.world = laboratory()
  var setup = Setup(mapSeed: researchMap.seed, tickRate: TickRate.uint16,
    gridTiles: researchMap.side.uint16, decisionTicks: DecisionTicks.uint16,
    maximumTicks: uint32(TickRate * 600), mapHash: researchMap.hash,
    contentHash: contentHash(), mapSettings: researchMap.settings)
  for i, origin in researchMap.hallOrigin:
    setup.players.add ReplayPlayerSetup(id: i.int32,
      startX: origin.x.int32, startY: origin.y.int32)
  game.recorder = initReplayRecorder(setup)
  game.networked = true
  let baseline = game.stateHash()
  clearPlayerCommands()
  queueResearch(0, game.world.smith(), TemperedEdges)
  game.flushPlayerCommands()
  doAssert game.stateHash() == baseline
  doAssert game.submissions.len == 1, "Research follows the ordinary command queue"
  let action = game.submissions[0]
  doAssert action.kind == ActionResearch
  let decoded = decodeSubmission(encodeSubmission(action))
  doAssert decoded.first == TemperedEdges.ord.int32
  doAssert decoded.entityId == action.entityId
  let peer = game.world.clone()
  let initial = game.world.clone()
  game.networked = false
  proc decide(w: World) =
    if w.tick == 1:
      doAssert game.applyResearch(0, action.entityId, action.first)
      doAssert not game.applyResearch(0, action.entityId, action.first)
  proc peerDecide(w: World) =
    if w.tick == 1: doAssert w.applyReplayAction(decoded)
  for _ in 0 ..< researchStats(TemperedEdges, 1).ticks:
    game.world.tickWorld(decide)
    peer.tickWorld(peerDecide)
    doAssert game.stateHash() == Game(world: peer).stateHash()
    game.recorder.recordHash(game.stateHash())
  let tape = decodeReplay(encodeReplay(game.recorder.data))
  doAssert tape.actions.len == 1
  doAssert tape.actions[0].kind == ActionResearch
  let playback = Game(world: initial)
  let cursor = initReplayPlayer(tape)
  proc replay(w: World) =
    var replayAction: ReplayAction
    while cursor.takeActionAt(w.tick.uint32, replayAction):
      doAssert w.applyReplayAction(replayAction)
  for hash in tape.hashes:
    playback.world.tickWorld(replay)
    doAssert playback.stateHash() == hash
  doAssert playback.world.researchLevel(0, TemperedEdges) == 1
  for field in 0 .. 5:
    var invalid = action
    case field
    of 0: invalid.first = 4
    of 1: invalid.second = 1
    of 2: invalid.third = 1
    of 3: invalid.append = true
    of 4: invalid.entityId = FirstUnitId
    else: invalid.offset.x = 0.1'fx
    var rejected = false
    try: invalid.validateAction(setup)
    except ReplayError: rejected = true
    doAssert rejected
  var old = tape
  old.header.gameVersion = 30
  var rejected = false
  try: old.validate()
  except ReplayError: rejected = true
  doAssert rejected
  doAssert LvdNetworkProtocol == 3

block eligibilityAndPlayerWideLocks:
  let w = laboratory()
  let id = w.smith()
  let i = w.buildingIndex(id)
  let baseline = Game(world: w).stateHash()
  for player in [-1'i32, 1, 100]:
    doAssert not w.applyResearch(player, id, TemperedEdges.ord.int32)
  for value in [-1'i32, 4, int32.high]:
    doAssert not w.applyResearch(0, id, value)
  doAssert not w.applyResearch(0, NoEntity, TemperedEdges.ord.int32)
  doAssert not w.applyResearch(0, id, KeenflightArrows.ord.int32)
  doAssert Game(world: w).stateHash() == baseline
  w.buildings[i].state = BuildingUnderConstruction
  doAssert not w.canResearch(0, id, TemperedEdges)
  w.buildings[i].state = BuildingComplete
  w.players[0].gold = 599
  doAssert not w.canResearch(0, id, TemperedEdges)
  w.players[0].gold = 20000
  w.players[0].wood = 199
  doAssert not w.canResearch(0, id, TemperedEdges)
  w.players[0].wood = 20000
  # The completed barracks is a normal live prerequisite, never a campaign gate.
  let barracks = w.buildings.high
  w.buildings[barracks].state = BuildingUnderConstruction
  doAssert not w.canResearch(0, id, TemperedEdges)
  w.buildings[barracks].state = BuildingComplete
  doAssert w.applyResearch(0, id, TemperedEdges.ord.int32)
  # Reuse opponent's registered structure as another smith for this lock check.
  var other = -1
  for index, b in w.buildings:
    if b.owner == 1: other = index
  w.buildings[other].owner = 0
  w.buildings[other].kind = BlacksmithBuilding
  doAssert not w.canResearch(0, w.buildings[other].id, TemperedEdges)
  doAssert w.canResearch(0, w.buildings[other].id, RunedPlating)
  doAssert w.applyResearch(0, w.buildings[other].id, RunedPlating.ord.int32)
  w.damageEntity(id, 100000)
  doAssert not w.researchInProgress(0, TemperedEdges)
  doAssert w.researchInProgress(0, RunedPlating)

block allCategoriesHaveThreeSequentialTiers:
  for category in ResearchKind:
    let w = laboratory()
    let i = w.buildingIndex(w.smith())
    w.buildings[i].kind = researchBuilding(category)
    for level in 1'i32 .. MaxResearchLevel:
      let cost = researchStats(category, level)
      doAssert cost.gold == 300 + 300 * level
      doAssert cost.wood == 200 * level
      doAssert cost.ticks == (10 + 10 * level) * TickRate
      doAssert w.applyResearch(0, w.buildings[i].id, category.ord.int32)
      doAssert w.buildings[i].researchLevel == level
      w.run(cost.ticks)
      doAssert w.researchLevel(0, category) == level
      doAssert w.researchLevel(1, category) == 0
    doAssert not w.canResearch(0, w.buildings[i].id, category)
    doAssert researchStats(category, 0) == ResearchStats()
    doAssert researchStats(category, 4) == ResearchStats()
    doAssert researchName(category).len > 0

block actualCombatExistingAndNewUnits:
  for category in [KeenflightArrows, TemperedEdges, RunedPlating]:
    for newUnit in [false, true]:
      let w = laboratory()
      let center = researchMap.side div 2
      let kind = if category == KeenflightArrows: ArcherUnit else: SoldierUnit
      if newUnit:
        w.players[0].researchLevels[category] = 2
        w.players[1].researchLevels[category] = 2
      let attacker = w.spawnUnit(0, kind, tile2(center, center))
      let defender = w.spawnUnit(1, PeonUnit, tile2(center + 1, center))
      let base = w.clone()
      base.players[0].researchLevels[category] = 0
      base.players[1].researchLevels[category] = 0
      w.players[0].researchLevels[category] = 2
      w.players[1].researchLevels[category] = 2
      w.rebuildVision()
      base.rebuildVision()
      doAssert base.applyAttack(0, attacker, defender)
      doAssert w.applyAttack(0, attacker, defender)
      for _ in 0 ..< 120:
        base.run(1)
        w.run(1)
        let baseHp = base.units[base.unitIndex(defender)].hp
        let hp = w.units[w.unitIndex(defender)].hp
        if baseHp < unitOf(1, PeonUnit).hp:
          doAssert hp == baseHp + (if category == RunedPlating: 4 else: -4)
          break
      doAssert base.units[base.unitIndex(defender)].hp < unitOf(1, PeonUnit).hp

block buildingsNeverGainArmor:
  let w = laboratory()
  let attacker = w.spawnUnit(1, SoldierUnit,
    tile2(researchMap.hallOrigin[0].x.int32 - 1, researchMap.hallOrigin[0].y.int32))
  let target = w.smith()
  let baseline = w.clone()
  w.players[0].researchLevels[RunedPlating] = 3
  w.rebuildVision()
  baseline.rebuildVision()
  doAssert w.applyAttack(1, attacker, target)
  doAssert baseline.applyAttack(1, attacker, target)
  let hp = w.buildings[w.buildingIndex(target)].hp
  for _ in 0 ..< 120:
    w.run(1)
    baseline.run(1)
    doAssert w.buildings[w.buildingIndex(target)].hp ==
      baseline.buildings[baseline.buildingIndex(target)].hp
  doAssert w.buildings[w.buildingIndex(target)].hp < hp

block actualKnightMovement:
  let w = laboratory()
  let center = researchMap.side div 2
  let knight = w.spawnUnit(0, KnightUnit, tile2(center, center))
  let ordinary = w.clone()
  w.players[0].researchLevels[WindrunnerTraining] = 3
  doAssert ordinary.applyMove(0, knight, center + 8, center)
  doAssert w.applyMove(0, knight, center + 8, center)
  ordinary.run(20)
  w.run(20)
  doAssert w.units[w.unitIndex(knight)].body.pos.x >
    ordinary.units[ordinary.unitIndex(knight)].body.pos.x

echo "LvD research tests passed"
