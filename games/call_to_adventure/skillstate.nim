## What the skill bar shows of one skill.
##
## Both answers come from the actor alone and keep no memory between frames,
## so a seek or a rewound replay shows the same bar.

import content

proc cooldownLeft*(
    actor: Actor,
    ability: Ability,
    renderAlpha: float32
): float32 =
  ## Returns the share of a skill's wait still to run: 1 from the moment it
  ## is cast, because a cooldown only starts once recovery ends, down to 0 on
  ## the tick it is ready. The tick that sets a cooldown also takes one off
  ## it, so the sweep runs over one tick fewer and meets both ends exactly.
  if actor.action == ability:
    return 1
  let ticks = actor.cooldowns[int(ability)]
  if ticks > 0:
    return clamp(
      (ticks.float32 - renderAlpha) /
        max(Abilities[ability].cooldownTicks - 1, 1).float32,
      0,
      1
    )

proc lacksMana*(actor: Actor, ability: Ability): bool =
  ## Returns whether the hero cannot pay for a skill. Using an item neither
  ## checks nor charges mana, so this only applies to the hero's own skills.
  actor.mana < Abilities[ability].manaCost
