## Call to Adventure skill bar: the cooldown sweep against the simulation.

import
  ../[content, sim, skillstate]

const Steps = 4
  ## Sub-tick frames each tick is checked at.

proc idle(game: Game, slot: int32) =
  discard

proc castAndWait(ability: Ability): int =
  ## Casts an ability and walks its sweep from the first tick of the cast to
  ## the first tick the ability is ready, checking it at sub-tick steps.
  ## Returns how many ticks the wait took once the cast was over.
  let
    game = newGame(2026, 2000)
    hero = game.world.actors[0]
    frame = 1 / (Steps.float32 * (Abilities[ability].cooldownTicks - 1).float32)
  doAssert hero.cooldownLeft(ability, 0) == 0, "starts ready"
  hero.action = ability
  for step in 0 .. Steps:
    doAssert hero.cooldownLeft(ability, step / Steps) == 1
  while hero.action == ability:
    game.tickWorld(idle)
  doAssert hero.cooldownLeft(ability, 0) == 1,
    "the sweep must start where the cast's full dim ended"
  var previous = 1.0'f32
  while hero.cooldowns[int(ability)] > 0:
    for step in 0 ..< Steps:
      let left = hero.cooldownLeft(ability, step / Steps)
      doAssert left <= previous
      doAssert previous - left <= frame * 1.01, "the sweep jumped"
      previous = left
    game.tickWorld(idle)
    inc result
  doAssert hero.cooldownLeft(ability, 0) == 0
  doAssert previous <= frame * 1.01, "the last step must land on ready"

echo "Testing the cooldown sweep runs unbroken from cast to ready"
block:
  for ability in [BlazingBlade, MeteorStrike, BowAttack, BattleHorn]:
    doAssert castAndWait(ability) == Abilities[ability].cooldownTicks - 1

echo "Testing a skill with no cooldown only dims while it is cast"
block:
  let
    game = newGame(2026, 2000)
    hero = game.world.actors[0]
  hero.action = SwordAttack
  doAssert hero.cooldownLeft(SwordAttack, 1) == 1
  while hero.action == SwordAttack:
    game.tickWorld(idle)
  doAssert hero.cooldownLeft(SwordAttack, 0) == 0

echo "Testing a cast dims only the skill being cast"
block:
  let
    game = newGame(2026, 2000)
    hero = game.world.actors[0]
  hero.action = BlazingBlade
  doAssert hero.cooldownLeft(SwordAttack, 0) == 0

echo "Testing a skill lacks mana only below its cost"
block:
  let
    game = newGame(2026, 2000)
    wizard = game.world.actors[1]
    cost = Abilities[MeteorStrike].manaCost
  doAssert wizard.heroClass == WizardClass
  wizard.mana = cost
  doAssert not wizard.lacksMana(MeteorStrike)
  wizard.mana = cost - 1
  doAssert wizard.lacksMana(MeteorStrike)
  wizard.mana = 0
  doAssert not wizard.lacksMana(SwordAttack), "free skills never lack mana"

echo "Skill bar tests passed"
