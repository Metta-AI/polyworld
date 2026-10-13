## Checks that each simplify level toward PufferLib moba takes effect.
import std/os
include ../examples/gods_of_the_arena/lockstep

const
  GameDir = "examples/gods_of_the_arena"
  Config = GameDir / "presets/saved.json"
  Bot = GameDir / "players/base.bas"

proc newBatch(level: int): StepBatch =
  ## Two lanes of five learners against base.bas at one simplify level.
  result = newStepBatch(Config, Bot, Bot, "nim", 2, 28_800, false,
    MobaReward, NimHarness)
  result.setSimplify(level)

proc stepTicks(batch: StepBatch, steps: int) =
  ## Steps every agent with key 0 (press nothing).
  let agents = batch.agentCount
  var
    actions = newSeq[int32](agents * ActionCount)
    rewards = newSeq[float32](agents)
    terminals = newSeq[uint8](agents)
    stats = newSeq[LaneStats](2)
  for _ in 0 ..< steps:
    batch.step(actions, rewards, terminals, stats)

echo "Testing simplify 0 keeps one tick per step"
block:
  let batch = newBatch(0)
  let before = batch.currentMatch(0).world.tick
  batch.stepTicks(1)
  doAssert batch.currentMatch(0).world.tick == before + 1

echo "Testing simplify 1 runs ten ticks per step"
block:
  let batch = newBatch(1)
  let before = batch.currentMatch(0).world.tick
  batch.stepTicks(1)
  doAssert batch.currentMatch(0).world.tick == before + 10

echo "Testing simplify 8 applies every cut"
block:
  let batch = newBatch(8)
  let world = batch.currentMatch(0).world
  doAssert world.simplify == 8
  doAssert world.phase == Playing
  for hero in world.heroes:
    doAssert hero.drafted
    doAssert hero.abilityLevels[HeroAbilitySlot(0)] == 1
    doAssert hero.abilityLevels[HeroAbilitySlot(3)] == 0
    doAssert world.heroHitTicks(hero) == 0
  doAssert world.heroes[0].class == DruidWarden
  doAssert world.heroes[9].class == Ranger
  doAssert world.fortExposed(RedTeam) and world.fortExposed(BlueTeam)
  for building in world.buildings:
    doAssert world.buildingExposed(building)
  doAssert world.visible(RedTeam, world.forts[1].center)
  let hero = world.heroes[0]
  doAssert not world.applyBuyItem(hero.id, 1)
  doAssert not world.applyLevelAbility(hero.id, 3)
  batch.stepTicks(3)
  hero.hp = 0
  batch.stepTicks(1)
  doAssert hero.state != Dying and hero.hp == hero.maxHp,
    "simplify 2 respawns at once"

echo "Simplify cuts take effect"
