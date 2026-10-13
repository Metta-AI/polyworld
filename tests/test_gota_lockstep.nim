include ../examples/gods_of_the_arena/lockstep

let policy = """
dim obs(5966)
dim act(9)
obs(0) = 100
obs(1) = selfTeam * 100
obs(2) = selfClass * 10
obs(3) = 77
obs(4391) = 44
' METTA_DECISION
if act(0) = 0 then
  walkTo(10, 10)
end if
if act(0) = 1 then
  walkTo(mapWidth - 10, 10)
end if
if act(3) = 1 then
  castTarget(0, selfId)
end if
"""
let
  config = "examples/gods_of_the_arena/presets/saved.json"
  bot = "examples/gods_of_the_arena/players/base.bas"

proc run(
    selfPlay: bool,
    rewardMode: RewardMode,
    maxTicks, steps: int
): tuple[features: seq[int32], seats: seq[int32], rewards: seq[float32],
    finished: int] =
  ## Plays a fixed action pattern and returns the last frame.
  let batch = newStepBatch(config, bot, bot, policy, 2, maxTicks,
    selfPlay, rewardMode)
  let agents = batch.agentCount
  var
    actions = newSeq[int32](agents * ActionCount)
    rewards = newSeq[float32](agents)
    terminals = newSeq[uint8](agents)
    stats = newSeq[LaneStats](2)
  result.features = newSeq[int32](agents * ObservationSize)
  result.seats = newSeq[int32](agents)
  for step in 0 ..< steps:
    for i in 0 ..< actions.len:
      actions[i] = int32((step + i) mod ActionSizes[i mod ActionCount])
    batch.step(actions, rewards, terminals, stats)
    for lane in stats:
      result.finished += int(lane.finished)
  batch.observe(result.features, result.seats)
  result.rewards = rewards

echo "Testing agent counts"
doAssert newStepBatch(config, bot, bot, policy, 3, 240, false).agentCount == 15
doAssert newStepBatch(config, bot, bot, policy, 3, 240, true).agentCount == 30

echo "Testing observations and seats"
let played = run(true, XpReward, 2400, 20)
for agent in 0 ..< played.seats.len:
  doAssert played.seats[agent] in 0 .. 4
  doAssert played.features[agent * ObservationSize + 3] == 77
  doAssert played.features[agent * ObservationSize + 4391] == 44

echo "Testing the minimap"
block:
  const
    MiniStart = 4392
    MiniCells = 225
  let batch = newStepBatch(config, bot, bot, "", 1, 2400, false,
    MobaReward, NimHarness)
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
    features = newSeq[int32](batch.agentCount * ObservationSize)
    seats = newSeq[int32](batch.agentCount)
  for step in 0 ..< 600:
    batch.step(actions, rewards, terminals, stats)
  batch.observe(features, seats)
  for agent in 0 ..< batch.agentCount:
    let base = agent * ObservationSize + MiniStart
    var allies, selves, gods = 0
    for cell in 0 ..< MiniCells:
      allies += features[base + cell]
      selves += features[base + 6 * MiniCells + cell]
      if features[base + 4 * MiniCells + cell] == 11:
        inc gods
    doAssert selves == 1, "one own cell per hero"
    doAssert allies in 1 .. 5, "allied heroes are always visible"
    doAssert gods >= 1, "the full-health allied god and structures show"

echo "Testing determinism"
let replayed = run(true, XpReward, 2400, 20)
doAssert played.features == replayed.features
doAssert played.rewards == replayed.rewards

echo "Testing restarts"
let restarted = run(false, LeaderboardReward, 240, 500)
doAssert restarted.finished >= 4, "every lane should finish twice"

echo "Testing reward modes"
for mode in RewardMode:
  let frame = run(false, mode, 480, 10)
  for reward in frame.rewards:
    doAssert reward == reward, "reward must not be NaN"

echo "Testing training Glory agrees with hosted scoring"
for (ended, draw, winner) in [
  (true, false, RedTeam),
  (true, false, BlueTeam),
  (true, true, RedTeam),
  (false, false, RedTeam)
]:
  let
    batch = newStepBatch(config, bot, bot, policy, 1, 28800,
      true, LeaderboardReward)
    world = batch.lanes[0].game.world
  world.tick = if ended: 15120 else: 28800
  world.draftTicks = 120
  world.gameOver = ended
  world.draw = draw
  world.winner = winner
  for hero in world.heroes:
    hero.totalXp = 3150
  let hosted = scores(world.totalXp(), int(world.tick), world.scores())
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
  batch.step(actions, rewards, terminals, stats)
  doAssert stats[0].finished == 1
  doAssert stats[0].outcome == (if hosted[0] > 0: 1 else: -1)
  doAssert stats[0].potential == int64(hosted[0]) * 7200
  for agent in 0 ..< batch.agentCount:
    doAssert terminals[agent] == 1
    doAssert abs(rewards[agent] - float32(hosted[agent]) / 1000) < 0.000001'f

echo "Testing MobaReward sums to each hero's XP, deaths and structures"
block:
  let batch = newStepBatch(config, bot, bot, "", 1, 6000,
    false, MobaReward, NimHarness)
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
    totals = newSeq[float64](batch.agentCount)
  for step in 0 ..< 5999:
    # March at the enemy, stopping every third second to fight and cast.
    let marching = step div 30 mod 3 != 2
    for agent in 0 ..< batch.agentCount:
      let base = agent * ActionCount
      actions[base + 0] = if marching: 6 else: 3
      actions[base + 1] = if marching: 0 else: 3
      for slot in 3 .. 6:
        actions[base + slot] = 1
    batch.step(actions, rewards, terminals, stats)
    doAssert stats[0].finished == 0
    for agent in 0 ..< batch.agentCount:
      totals[agent] += float64(rewards[agent])
  let lane = batch.lanes[0].addr
  for i, index in lane.agents:
    let
      hero = lane.game.world.heroes[index]
      structures = lane.game.world.stats.values[index][StructuresMetric]
      expected =
        float64(hero.totalXp) * float64(MobaXpWeight) -
        float64(hero.deaths) * float64(MobaDeathWeight) +
        float64(structures) * float64(MobaStructureWeight)
    echo "  hero ", index, " xp ", hero.totalXp, " deaths ", hero.deaths,
      " structures ", structures, " reward ", totals[i]
    doAssert abs(totals[i] - expected) < 0.01, "MobaReward should add up"
  var earned = false
  for total in totals:
    if total != 0:
      earned = true
  doAssert earned, "some hero should earn MobaReward"

echo "Testing the opponent curriculum"
block:
  let
    players = "examples/gods_of_the_arena/players/"
    easy = players & "base.bas"
    middle = players & "rusher.bas"
    hard = players & "puller.bas"
    batch = newStepBatch(config, bot, easy & "\n" & middle & "\n" & hard,
      "", 1, 240, false, MobaReward, NimHarness)
  proc count(groups: seq[BotGroup], path: string): int =
    for group in groups:
      if group.path == path:
        result += group.count
  var even: array[3, int]
  for seed in 0 ..< 3000:
    let (index, groups) = batch.opponentGroups(seed * 200_000)
    doAssert groups.count(batch.opponents[index]) == TeamSize
    inc even[index]
  for share in even:
    doAssert share in 800 .. 1200, "a static mix draws every opponent evenly"
  batch.setLevel(0)
  for seed in 0 ..< 200:
    let (level, groups) = batch.opponentGroups(seed)
    doAssert level == 0 and groups.count(easy) == TeamSize
  batch.setLevel(7)
  var current = 0
  for seed in 0 ..< 2000:
    let (level, groups) = batch.opponentGroups(seed)
    doAssert level in 0 .. 7
    if level == 7:
      inc current
      doAssert groups.count(middle) == 3 and groups.count(hard) == 2,
        "level 7 is three of the second opponent and two of the third"
    doAssert groups.count(easy) + groups.count(middle) +
      groups.count(hard) == TeamSize
  doAssert current in 1350 .. 1650, "the current level gets three in four"
  batch.setLevel(99)
  doAssert batch.level == batch.maxLevel and batch.maxLevel == 10
  for seed in 0 ..< 200:
    let (level, groups) = batch.opponentGroups(seed)
    if level == 10:
      doAssert groups.count(hard) == TeamSize
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
  batch.setWalk(0)
  batch.reset(1)
  for step in 0 ..< 240:
    batch.step(actions, rewards, terminals, stats)
    if step == 200:
      for harness in batch.lanes[0].harnesses:
        doAssert not harness.walking, "no hero walks at 0 percent"
  doAssert stats[0].finished == 1
  doAssert stats[0].played in 0'i32 .. 10'i32 and stats[0].level == 10
  batch.setWalk(100)
  batch.reset(2)
  for step in 0 ..< 200:
    batch.step(actions, rewards, terminals, stats)
  var walkers = 0
  for harness in batch.lanes[0].harnesses:
    if harness.walking:
      inc walkers
  doAssert walkers > 0, "heroes walk at 100 percent"
  batch.setReach(0)
  batch.reset(3)
  for step in 0 ..< 200:
    batch.step(actions, rewards, terminals, stats)
  for harness in batch.lanes[0].harnesses:
    doAssert not harness.walking, "no hero walks with reach 0"
  batch.setReach(50)
  batch.reset(4)
  for step in 0 ..< 200:
    batch.step(actions, rewards, terminals, stats)
  for harness in batch.lanes[0].harnesses:
    doAssert harness.walkStop > 16,
      "reach 50 stops the walk a quarter of the squared way short"

echo "Testing MobaWinReward's win bonus"
block:
  for won in [true, false]:
    let
      batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
        MobaWinReward, NimHarness)
      lane = batch.lanes[0].addr
      world = lane.game.world
    world.tick = 15120
    world.draftTicks = 120
    world.gameOver = true
    world.draw = false
    world.winner = if won: lane.team else: Team(1 - lane.team.ord)
    var
      actions = newSeq[int32](batch.agentCount * ActionCount)
      rewards = newSeq[float32](batch.agentCount)
      terminals = newSeq[uint8](batch.agentCount)
      stats = newSeq[LaneStats](1)
    batch.step(actions, rewards, terminals, stats)
    doAssert stats[0].finished == 1
    for agent in 0 ..< batch.agentCount:
      doAssert terminals[agent] == 1
      if won:
        doAssert rewards[agent] >= MobaWinBonus - 1, "winners get the bonus"
      else:
        doAssert rewards[agent] < 1, "losers do not"

echo "Testing potential-based shaping toward enemy structures"
block:
  # Same seed and actions with and without shaping: at gamma 1 the extra
  # reward telescopes to weight * (distance at the start - distance now).
  let
    plain = newStepBatch(config, bot, bot, "", 1, 28800, false,
      MobaReward, NimHarness)
    shaped = newStepBatch(config, bot, bot, "", 1, 28800, false,
      MobaReward, NimHarness)
  shaped.setShaping(0.01, 1)
  plain.reset(5)
  shaped.reset(5)
  var
    starts: seq[float32]
    actions = newSeq[int32](plain.agentCount * ActionCount)
    rewards = newSeq[float32](plain.agentCount)
    shapedRewards = newSeq[float32](plain.agentCount)
    extras = newSeq[float64](plain.agentCount)
    terminals = newSeq[uint8](plain.agentCount)
    stats = newSeq[LaneStats](1)
  for index in shaped.lanes[0].agents:
    starts.add enemyDistance(shaped.lanes[0].game.world,
      shaped.lanes[0].game.world.heroes[index])
  for step in 0 ..< 1500:
    plain.step(actions, rewards, terminals, stats)
    shaped.step(actions, shapedRewards, terminals, stats)
    for agent in 0 ..< plain.agentCount:
      extras[agent] += float64(shapedRewards[agent] - rewards[agent])
  var walked = false
  for agent, index in shaped.lanes[0].agents:
    let
      world = shaped.lanes[0].game.world
      now = enemyDistance(world, world.heroes[index])
      expected = 0.01 * float64(starts[agent] - now)
    doAssert abs(extras[agent] - expected) < 0.001,
      "shaping telescopes: " & $extras[agent] & " vs " & $expected
    if now < starts[agent] - 5:
      walked = true
  doAssert walked, "the lane walk brings heroes closer to the enemy"

echo "Testing the retreat: standing still with target 0 walks home"
block:
  let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
    MobaReward, NimHarness)
  batch.reset(3)
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
    farthest = 0'i32
  for agent in 0 ..< batch.agentCount:
    actions[agent * ActionCount] = 3
    actions[agent * ActionCount + 1] = 3
  for step in 0 ..< 6000:
    batch.step(actions, rewards, terminals, stats)
    if step == 1500:
      # The lane walk has taken every hero well away from home.
      for agent, harness in batch.lanes[0].harnesses:
        let hero = batch.lanes[0].game.world.heroes[batch.lanes[0].agents[agent]]
        farthest = max(farthest,
          abs(mapCoordinate(hero.position.x) - harness.homeX) +
          abs(mapCoordinate(hero.position.z) - harness.homeY))
  doAssert farthest > 30, "the walk leaves home"
  var home = 0
  for agent, harness in batch.lanes[0].harnesses:
    let hero = batch.lanes[0].game.world.heroes[batch.lanes[0].agents[agent]]
    if abs(mapCoordinate(hero.position.x) - harness.homeX) +
      abs(mapCoordinate(hero.position.z) - harness.homeY) <= 8:
        inc home
  doAssert home >= 4, "retreating heroes are back home: " & $home

echo "Testing a larger win bonus"
block:
  let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
    MobaWinReward, NimHarness)
  batch.setWinBonus(30)
  let
    lane = batch.lanes[0].addr
    world = lane.game.world
  world.tick = 15120
  world.draftTicks = 120
  world.gameOver = true
  world.draw = false
  world.winner = lane.team
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
  batch.step(actions, rewards, terminals, stats)
  for agent in 0 ..< batch.agentCount:
    doAssert rewards[agent] >= 29, "winners get the set bonus"

echo "Testing the build order for the buy head"
block:
  # Every hero always asks to buy item 13 (a sunsteel longsword). With the
  # build order on they buy base.bas's list instead and never the sword.
  let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
    MobaReward, NimHarness)
  batch.setBuild(true)
  batch.reset(4)
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
  for agent in 0 ..< batch.agentCount:
    actions[agent * ActionCount] = 3
    actions[agent * ActionCount + 1] = 3
    actions[agent * ActionCount + 2] = 1
    actions[agent * ActionCount + 7] = 13
  for step in 0 ..< 600:
    batch.step(actions, rewards, terminals, stats)
  var boots = 0
  for index in batch.lanes[0].agents:
    let hero = batch.lanes[0].game.world.heroes[index]
    for slot in 0 ..< InventorySlots:
      doAssert hero.inventory[slot].ord != 13, "the build order skips item 13"
      if hero.inventory[slot].ord == 8:
        inc boots
  doAssert boots == batch.lanes[0].agents.len, "every hero buys boots first"

echo "Testing the automatic retreat below a share of health"
block:
  # Heroes stand and fight base.bas until hurt; with the retreat on, every
  # hero that dropped under 40% at some point was sent home.
  let batch = newStepBatch(config, bot, bot, "", 1, 28800, false,
    MobaReward, NimHarness)
  batch.setRetreat(40)
  batch.reset(6)
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
    retreats = 0
  for agent in 0 ..< batch.agentCount:
    actions[agent * ActionCount] = 3
    actions[agent * ActionCount + 1] = 3
    actions[agent * ActionCount + 2] = 1
  for step in 0 ..< 6000:
    batch.step(actions, rewards, terminals, stats)
    for harness in batch.lanes[0].harnesses:
      if harness.retreating:
        inc retreats
  doAssert retreats > 0, "hurt heroes retreat"
