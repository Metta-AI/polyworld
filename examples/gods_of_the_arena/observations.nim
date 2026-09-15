import sim

proc spellVisible(world: World, team: Team, spell: SpellCast): bool =
  ## Filters pending spell warnings using the same team vision as rendering.
  if spell.resolved or world.tick < spell.started or world.tick > spell.impact:
    return false
  let caster = world.heroIndex(spell.heroId)
  caster >= 0 and (world.heroes[caster].team == team or
    world.visible(team, spell.position))

proc visibleSpellCount*(world: World, heroId: int32): int =
  ## Counts unresolved, currently visible projectiles and area warnings.
  if world == nil:
    return 0
  let observer = world.heroIndex(heroId)
  if observer < 0:
    return 0
  let team = world.heroes[observer].team
  for spell in world.casts:
    if world.spellVisible(team, spell):
      inc result

proc visibleSpellAt*(
    world: World,
    heroId: int32,
    index: int,
    value: var SpellCast
): bool =
  ## Reads a zero-based visible spell in simulation order without mutation.
  if world == nil or index < 0:
    return false
  let observer = world.heroIndex(heroId)
  if observer < 0:
    return false
  let team = world.heroes[observer].team
  var visibleIndex = 0
  for spell in world.casts:
    if not world.spellVisible(team, spell):
      continue
    if visibleIndex == index:
      value = spell
      return true
    inc visibleIndex
  false

proc visibleSpellCasterId*(
    world: World,
    heroId: int32,
    spell: SpellCast
): int32 =
  ## Returns the visible caster's object ID, or zero when hidden or invalid.
  if world == nil:
    return 0
  let observer = world.heroIndex(heroId)
  if observer < 0:
    return 0
  let team = world.heroes[observer].team
  if not world.spellVisible(team, spell):
    return 0
  let caster = world.heroes[world.heroIndex(spell.heroId)]
  if caster.team == team or world.visible(team, caster.position):
    caster.id
  else:
    0
