import
  vmath,
  polyworld/particles,
  ../examples/gods_of_the_arena/[content, maps, sim, spelleffects]

echo "Effects follow current team LOS, including after vision is lost."
let
  world = World()
  size = mapTiles()
  index = (size div 2) * size + size div 2
  at = vec3(0.5, 1, 0.5)
for team in Team:
  world.teamVisible[team.ord] = newSeq[uint8](size * size)
doAssert world.effectVisible(0, at)
doAssert not world.effectVisible(1, at)
doAssert not world.effectVisible(2, at)
world.teamVisible[RedTeam.ord][index] = 255
doAssert world.effectVisible(1, at)
doAssert not world.effectVisible(2, at)
doAssert not world.effectVisible(1, vec3(4.5, 1, 0.5))
world.teamVisible[RedTeam.ord][index] = 0
doAssert not world.effectVisible(1, at)

echo "Particle trails and delayed impacts cannot reveal unseen tiles."
var visibility = newSeq[uint8](16)
let
  start = vec3(0.5, 0, 0.5)
  finish = vec3(3.5, 0, 0.5)
for i in 0 ..< 4:
  visibility[i] = 255
doAssert particlePathVisible(start, finish, visibility, 4, vec2(0))
visibility[2] = 0
doAssert not particlePathVisible(start, finish, visibility, 4, vec2(0))
doAssert particlePathVisible(finish, finish, visibility, 4, vec2(0))
visibility[3] = 0
doAssert not particlePathVisible(finish, finish, visibility, 4, vec2(0))
doAssert not particlePathVisible(start, vec3(-1), visibility, 4, vec2(0))
doAssert particlePathVisible(start, finish, [], 0, vec2(0))
echo "Effect visibility checks passed."

echo "Selected spell arcs preserve their launch and impact positions."
let
  launch = vec3(1, 1, 2)
  impact = vec3(7, 2, 2)
  arc = spellArcHeight(SiegeScarab, 6)
doAssert arc > 0 and arc <= 1.25
doAssert spellArcPoint(launch, impact, 0, arc) == launch
doAssert spellArcPoint(launch, impact, 1, arc) == impact
doAssert spellArcPoint(launch, impact, 0.5, arc).y > 1.5
doAssert spellArcHeight(VerdantArrow, 6) == 0
doAssert spellArcHeight(FrostLance, 6) == 0

echo "Queued casts use the real area and clear with their order."
let hero = Hero(id: 100, hp: 100, class: Arcanist,
  hasQueuedCast: true, queuedCastSlot: SecondaryAbility,
  queuedCastPoint: WorldPoint(x: 10 * WorldScale),
  abilityLevels: [1'i32, 1, 1, 1])
var preview: SpellCast
doAssert world.queuedCastPreview(hero, preview)
doAssert preview.ability == MeteorStrike
doAssert preview.position == hero.queuedCastPoint
hero.hasQueuedCast = false
doAssert not world.queuedCastPreview(hero, preview)

echo "Caster-based queued areas preview their eventual release position."
hero.class = Ranger
hero.hasQueuedCast = true
hero.queuedCastSlot = UltimateAbility
hero.queuedCastPoint = WorldPoint(x: 20 * WorldScale)
doAssert world.queuedCastPreview(hero, preview)
doAssert preview.ability == StormEagle
let release = preview.position
var placement: SpellCast
doAssert world.placementPreview(
  hero, UltimateAbility, 0, hero.queuedCastPoint, placement
) == ActionOutOfRange
doAssert placement.position == preview.position
doAssert placement.direction == preview.direction
doAssert release.x == hero.queuedCastPoint.x -
  StormEagle.abilitySpec(1).range
doAssert release != hero.position
hero.position.x = 2 * WorldScale
doAssert world.queuedCastPreview(hero, preview)
doAssert preview.position == release
doAssert preview.origin == release
for ability in Ability:
  let spec = ability.abilitySpec
  if spec.casting != AreaCast:
    continue
  let contours = queuedContours(spec.area)
  doAssert contours.len == (if spec.area.innerRadius > 0: 2 else: 1)
  for contour in contours:
    doAssert contour.len >= 3
let line = queuedContours(FxArea(shape: LineFootprint,
  width: 2 * WorldScale, length: 8 * WorldScale))
doAssert line[0] == @[vec2(-1, 0), vec2(1, 0), vec2(1, 8), vec2(-1, 8)]
