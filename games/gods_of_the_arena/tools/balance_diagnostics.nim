import
  std/json,
  ../[content, sim]

type
  HeroDiagnostics* = object
    aliveTicks*, deadTicks*, lowManaTicks*: int64
    heroDamage*, creepDamage*, objectiveDamage*, incomingDamage*: int64
    basicDamage*, spellDamage*, requestedDamage*, healing*: int64
    spellHealing*, allyHealing*, manaRestored*: int64
    allyHealCasts*, healthyAllyHealCasts*: int64
      ## Healthy casts count allies targeted in ticks ending at full caster HP.
    casts*, hits*, damage*, requested*: array[4, int64]
    castErrors*: array[ActionError, int64]
  Diagnostics* = array[HeroClassCount, HeroDiagnostics]

proc collect*(data: var Diagnostics, world: World) =
  ## Accumulates tick events without changing simulation state.
  when defined(replayEvents):
    for event in world.events:
      if event.target.kind == 2 and event.kind == Damage:
        data[event.target.class].incomingDamage += event.amount
      if event.actor.kind != 2:
        continue
      let hero = event.actor.class.int
      case event.kind
      of Damage:
        data[hero].requestedDamage += event.requested
        case event.target.kind
        of 2: data[hero].heroDamage += event.amount
        of 3: data[hero].creepDamage += event.amount
        of 1, 4, 5: data[hero].objectiveDamage += event.amount
        else: discard
        if event.cause == BasicAttack:
          data[hero].basicDamage += event.amount
        elif event.cause == AbilityEffect:
          let slot = event.detail mod 4
          data[hero].spellDamage += event.amount
          inc data[hero].hits[slot]
          data[hero].damage[slot] += event.amount
          data[hero].requested[slot] += event.requested
      of SpellReleased:
        inc data[hero].casts[event.slot]
        if event.detail.Ability.abilitySpec.heal > 0 and
          event.target.kind == 2 and event.target.id != event.actor.id:
            inc data[hero].allyHealCasts
            let caster = world.heroById(event.actor.id)
            if caster.hp == caster.maxHp:
              inc data[hero].healthyAllyHealCasts
      of Healing:
        data[hero].healing += event.amount
        if event.cause == AbilityEffect:
          data[hero].spellHealing += event.amount
          if event.target.id != event.actor.id:
            data[hero].allyHealing += event.amount
      of ManaChanged:
        if event.cause == AbilityEffect and event.amount > 0:
          data[hero].manaRestored += event.amount
      of ActionRejected:
        if event.action in [6'u8, 10'u8]:
          inc data[hero].castErrors[event.error]
      else: discard
  if world.battleTick > 0:
    for hero in world.heroes:
      if hero.hp > 0:
        inc data[hero.class.ord].aliveTicks
        if hero.mana * 4 < hero.maxMana:
          inc data[hero.class.ord].lowManaTicks
      else:
        inc data[hero.class.ord].deadTicks

proc diagnosticsJson*(data: HeroDiagnostics): JsonNode =
  ## Serializes explicit per-match counters for later role review.
  result = %data
