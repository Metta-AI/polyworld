## Checks the tokenized layout of the polyworld-tokens experiment: its
## sizes, the tokens and structures it writes, and a stretch of random
## play with the one-key actions.
import std/random
include ../examples/gods_of_the_arena/lockstep

let
  config = "examples/gods_of_the_arena/presets/saved.json"
  bot = "examples/gods_of_the_arena/players/base.bas"

const
  GridCells = 81
  TokenStart = 81
  TokenCount = 24
  TokenSize = 5
  TokenReach = 16'i32
  StructureStart = 251
  StructureSlots = 34

echo "Testing the tokenized sizes"
doAssert ObservationSize == 541, $ObservationSize
doAssert ActionSizes == [22'i32]

echo "Testing tokens, structures and random play"
block:
  let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
    MobaReward, NimHarness)
  batch.reset(4)
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
    features = newSeq[int32](batch.agentCount * ObservationSize)
    seats = newSeq[int32](batch.agentCount)
    rng = initRand(7)
  for tick in 0 ..< 1500:
    for i in 0 ..< actions.len:
      actions[i] = int32(rng.rand(int(ActionSizes[0]) - 1))
    batch.step(actions, rewards, terminals, stats)
  batch.observe(features, seats)
  for agent in 0 ..< batch.agentCount:
    let base = agent * ObservationSize
    var walkable = 0
    for i in 0 ..< GridCells:
      walkable += features[base + i]
    doAssert walkable > 0, "some nearby tiles are walkable"
    # Tokens come nearest first and use occupant codes 1 to 9.
    var
      tokens = 0
      last = -1
    for t in 0 ..< TokenCount:
      let
        code = features[base + TokenStart + t * TokenSize]
        dx = features[base + TokenStart + t * TokenSize + 1]
        dy = features[base + TokenStart + t * TokenSize + 2]
      if code == 0:
        break
      doAssert code in 1'i32 .. 9'i32
      let distance = dx * dx + dy * dy
      doAssert distance >= last or abs(dx) == TokenReach or
        abs(dy) == TokenReach, "tokens are sorted by distance"
      last = distance
      inc tokens
    doAssert tokens > 0, "a hero sees something after 1,500 ticks"
    var alive = 0
    for i in 0 ..< StructureSlots:
      let value = features[base + StructureStart + i]
      doAssert value in 0'i32 .. 11'i32
      if value > 0:
        inc alive
    doAssert alive >= 20, "most structures are still standing: " & $alive

echo "Testing the structure reward"
block:
  # Knock half the health off one enemy structure between two ticks: every
  # learner gets half the weight more than without the structure reward.
  var totals: array[2, float64]
  for on in [false, true]:
    let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
      MobaReward, NimHarness)
    if on:
      batch.setStructureWeight(2)
    batch.reset(5)
    var
      actions = newSeq[int32](batch.agentCount * ActionCount)
      rewards = newSeq[float32](batch.agentCount)
      terminals = newSeq[uint8](batch.agentCount)
      stats = newSeq[LaneStats](1)
    batch.step(actions, rewards, terminals, stats)
    let lane = batch.lanes[0].addr
    for building in lane.game.world.buildings.mitems:
      if building.team != lane.team and building.lane == 0 and
        building.kind == TowerBuilding:
          building.hp = building.hp - building.maxHp div 2
          break
    batch.step(actions, rewards, terminals, stats)
    for reward in rewards:
      totals[int(on)] += float64(reward)
  let perHero = (totals[1] - totals[0]) / 5
  doAssert abs(perHero - 1.0) < 0.05,
    "half a structure at weight 2 pays each learner 1: " & $perHero

echo "Testing the death weight"
block:
  # Add one death to a learner between two ticks: at weight 1 the learners
  # lose 1 minus moba's weight more than at moba's weight.
  var totals: array[2, float64]
  for on in [false, true]:
    let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
      MobaReward, NimHarness)
    if on:
      batch.setDeathWeight(1)
    batch.reset(5)
    var
      actions = newSeq[int32](batch.agentCount * ActionCount)
      rewards = newSeq[float32](batch.agentCount)
      terminals = newSeq[uint8](batch.agentCount)
      stats = newSeq[LaneStats](1)
    batch.step(actions, rewards, terminals, stats)
    let lane = batch.lanes[0].addr
    inc lane.game.world.heroes[lane.agents[0]].deaths
    batch.step(actions, rewards, terminals, stats)
    for reward in rewards:
      totals[int(on)] += float64(reward)
  let extra = totals[0] - totals[1]
  doAssert abs(extra - (1 - MobaDeathWeight)) < 0.001,
    "one death at weight 1 costs 1 minus moba's weight more: " & $extra

proc tileDistance(hero: Hero, point: WorldPoint): float32 =
  ## Whole-tile distance from a hero to a point, as lockstep's shaping
  ## measures it.
  let
    dx = mapCoordinate(point.x) - mapCoordinate(hero.position.x)
    dy = mapCoordinate(point.z) - mapCoordinate(hero.position.z)
  sqrt(float32(dx * dx + dy * dy))

echo "Testing the finish shaping target"
block:
  let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
    MobaReward, NimHarness)
  batch.reset(5)
  let
    world = batch.lanes[0].game.world
    hero = world.heroes[batch.lanes[0].agents[0]]
    enemy = Team(1 - hero.team.ord)
  doAssert enemyDistance(world, hero, 1) ==
    enemyDistance(world, hero, 0),
    "before a lane falls, finish aims at the nearest structure too"
  # Clearing the enemy's lane 0 towers exposes both of its god guards.
  for building in world.buildings.mitems:
    if building.team == enemy and building.lane == 0 and
      building.kind == TowerBuilding and not building.guardsGod:
        building.hp = 0
  var guard = high(float32)
  for building in world.buildings:
    if building.team == enemy and building.guardsGod:
      guard = min(guard, tileDistance(hero, building.position))
  doAssert abs(enemyDistance(world, hero, 1) - guard) < 0.001,
    "with a lane down, finish aims at the nearest god guard"
  for building in world.buildings.mitems:
    if building.team == enemy and building.guardsGod:
      building.hp = 0
  doAssert abs(enemyDistance(world, hero, 1) -
    tileDistance(hero, world.forts[enemy.ord].center)) < 0.001,
    "with both guards down, finish aims at the enemy god"

echo "Testing god damage with finish"
block:
  # Take half the enemy god's health between two ticks: with finish each
  # learner gets half of GodStructures more.
  var totals: array[2, float64]
  for on in [false, true]:
    let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
      MobaReward, NimHarness)
    batch.setStructureWeight(1)
    batch.setFinish(int(on))
    batch.reset(5)
    var
      actions = newSeq[int32](batch.agentCount * ActionCount)
      rewards = newSeq[float32](batch.agentCount)
      terminals = newSeq[uint8](batch.agentCount)
      stats = newSeq[LaneStats](1)
    batch.step(actions, rewards, terminals, stats)
    let
      lane = batch.lanes[0].addr
      enemy = 1 - lane.team.ord
    lane.game.world.forts[enemy].hp -= FortHp div 2
    batch.step(actions, rewards, terminals, stats)
    for reward in rewards:
      totals[int(on)] += float64(reward)
  let perHero = (totals[1] - totals[0]) / 5
  doAssert abs(perHero - GodStructures / 2) < 0.01,
    "half the god pays each learner half of GodStructures: " & $perHero

echo "Testing the finish 2 focus lane"
block:
  let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
    MobaReward, NimHarness)
  batch.reset(5)
  let
    world = batch.lanes[0].game.world
    hero = world.heroes[batch.lanes[0].agents[0]]
    enemy = Team(1 - hero.team.ord)
  proc nextTower(laneIndex: int): float32 =
    ## Distance to the attackable tower of one enemy lane.
    for building in world.buildings:
      if building.team == enemy and building.kind == TowerBuilding and
        not building.guardsGod and building.lane == laneIndex and
        world.buildingExposed(building):
          return tileDistance(hero, building.position)
    -1
  doAssert abs(enemyDistance(world, hero, 2) - nextTower(1)) < 0.001,
    "with every lane whole, finish 2 aims at the middle lane"
  for building in world.buildings.mitems:
    if building.team == enemy and building.lane == 0 and
      building.kind == TowerBuilding and building.tier == OuterTower:
        building.hp = 0
  doAssert abs(enemyDistance(world, hero, 2) - nextTower(0)) < 0.001,
    "finish 2 aims at the lane with the fewest towers standing"

echo "Testing the health shaping"
block:
  # Once a learner is on the field, take half its health between two ticks:
  # with health shaping at 1 the learners get about 0.5 less.
  var totals: array[2, float64]
  for on in [false, true]:
    let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
      MobaReward, NimHarness)
    batch.setShaping(0, 0.99979)
    if on:
      batch.setHealthWeight(1)
    batch.reset(5)
    var
      actions = newSeq[int32](batch.agentCount * ActionCount)
      rewards = newSeq[float32](batch.agentCount)
      terminals = newSeq[uint8](batch.agentCount)
      stats = newSeq[LaneStats](1)
    let lane = batch.lanes[0].addr
    var ticks = 0
    while (lane.game.world.phase == Drafting or
      lane.game.world.heroes[lane.agents[0]].hp <= 0) and ticks < 3000:
        batch.step(actions, rewards, terminals, stats)
        inc ticks
    batch.step(actions, rewards, terminals, stats)
    let hero = lane.game.world.heroes[lane.agents[0]]
    hero.hp = hero.hp - hero.maxHp div 2
    batch.step(actions, rewards, terminals, stats)
    for reward in rewards:
      totals[int(on)] += float64(reward)
  let change = totals[1] - totals[0]
  doAssert abs(change + 0.5) < 0.02,
    "half a hero's health at weight 1 costs about 0.5: " & $change
