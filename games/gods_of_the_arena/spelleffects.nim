## Spell telegraphs and projectiles drawn from replay-authoritative state.

import
  std/math,
  vmath,
  polyworld/[fxmeshes, pathing, quadterrain],
  content, sim

type
  SpellMesh = tuple[vertices: seq[float32], indices: seq[uint32]]
  AreaMesh = object
    heroId, started: int32
    ability: Ability
    position: WorldPoint
    direction: Heading
    mesh: SpellMesh
  SpellRenderer* = object
    renderer: FxRenderer
    areas: seq[AreaMesh]
    preview: AreaMesh
    queued: AreaMesh
    queuedContours: array[Ability, seq[seq[Vec2]]]
    meshes: array[Ability, SpellMesh]
    glow: SpellMesh
    trail: SpellMesh
    fireball: SpellMesh
    portalRing, portalTube: SpellMesh

proc initSpellRenderer*(): SpellRenderer =
  ## Creates the shared spell mesh shader and reusable geometry buffer.
  result.renderer = initFxRenderer()

proc spellPoint(point: WorldPoint): Vec3 =
  ## Converts simulation positions only at the rendering boundary.
  vec3(point.x.float32, point.y.float32, point.z.float32) / WorldScale.float32

proc effectVisible*(world: World, viewMode: int32, position: Vec3): bool =
  ## Checks the displayed effect position, including allied shots into fog.
  viewMode == 0 or world.visible(Team(viewMode - 1), WorldPoint(
    x: int32(floor(position.x * WorldScale.float32)),
    z: int32(floor(position.z * WorldScale.float32))
  ))

proc footprintSettings*(area: FxArea): FxSettings =
  ## Builds the exact ground outline used by authoritative area hit tests.
  result = defaultFxSettings()
  result.radius = area.radius.float32 / WorldScale.float32
  result.innerRadius = area.innerRadius.float32 / WorldScale.float32
  result.width = area.width.float32 / WorldScale.float32
  result.length = area.length.float32 / WorldScale.float32
  result.height = 0.03
  result.angleOffset = 90
  result.arcDegrees = area.angle.float32
  result.pivot = CenterPivot
  result.texture = SolidTexture
  result.blendMode = AlphaBlend
  result.gradientSource = RadialGradient
  case area.shape
  of CircleFootprint:
    result.shape = AoeCircleShape
    result.innerRadius = 0
  of RingFootprint:
    result.shape = AoeCircleShape
  of SectorFootprint:
    result.shape = AoeConeShape
  of LineFootprint, CrossFootprint:
    result.shape = AoeLineShape
  of CapsuleFootprint:
    result.shape = AoeCapsuleShape
    result.length = max(0.0001'f, result.length - result.width)
  result.expandStart = 1
  result.expandEnd = 1
  result.fadeIn = 0
  result.fadeOut = 0

proc mapHeight(position: Vec3): float32 =
  ## Keeps warnings on the terrain and above shallow water.
  result = surfaceHeightNear(position.x, position.z, position.y)
  result += groundOffset(position.x, position.z)
  let (x, z) = worldToTile(position.x, position.z)
  for layer in layers:
    if not layer.water:
      continue
    let
      tx = x - layer.originX
      tz = z - layer.originZ
    if tx < 0 or tx >= layer.width or tz < 0 or tz >= layer.depth:
      continue
    let tile = layer.tiles[tz * layer.width + tx]
    if tile.exists:
      for height in tile.tops.unpack:
        result = max(result, height)

proc areaMesh(
    settings: FxSettings,
    spell: SpellCast,
    model: Mat4,
    crossed: bool
): AreaMesh =
  ## Projects a fixed footprint onto its map surface once per cast.
  result.heroId = spell.heroId
  result.started = spell.started
  result.ability = spell.ability
  result.position = spell.position
  result.direction = spell.direction
  let flat = buildFxMesh(settings)
  for arm in 0 .. (if crossed: 1 else: 0):
    let
      matrix =
        if arm == 0:
          model
        else:
          model * translate(vec3(0, 0, settings.length / 2)) *
            rotateY(PI.float32 / 2) *
            translate(vec3(0, 0, -settings.length / 2))
      base = uint32(result.mesh.vertices.len div 12)
    for index in flat.indices:
      result.mesh.indices.add(base + index)
    for vertex in 0 ..< flat.vertices.len div 12:
      let offset = vertex * 12
      var point = matrix * vec3(
        flat.vertices[offset], flat.vertices[offset + 1],
        flat.vertices[offset + 2]
      )
      point.y = mapHeight(point) + 0.08
      for field in 0 ..< 12:
        result.mesh.vertices.add(
          if field < 3: point[field] else: flat.vertices[offset + field]
        )

proc spellColor(ability: Ability): Vec3 =
  ## Gives each spell family an elemental identity independent of its team.
  case ability
  of LionGuard, FirebrandSword, InfernoAegis, BlazingBlade,
      RageCrucible, MoltenFist, VolcanicEruption, MeteorStrike:
    vec3(1.0, 0.38, 0.06)
  of ManaCrystal, FrostLance, FrostSigil, IceSpear, BoneMarionette:
    vec3(0.20, 0.75, 1.0)
  of NatureTalisman, HealingBloom, KindredWisps, GolemSeed, VerdantArrow:
    vec3(0.30, 1.0, 0.48)
  of ShadowCloak, VoidBlade, ShadowComet, AetherSiphon, MothHex,
      DreadTotem, VoidPortal, BoundVoid, ArcaneMeteor:
    vec3(0.75, 0.25, 1.0)
  of SanguineChalice, AfterlightSickle, WitheringIdol, DarkEclipse:
    vec3(1.0, 0.18, 0.47)
  of StormEagle, GaleSlash, WingedBoot:
    vec3(0.40, 0.95, 1.0)
  else:
    vec3(1.0, 0.80, 0.30)

proc spellArcHeight*(ability: Ability, distance: float32): float32 =
  ## Gives thrown payloads and drifting magic a modest visual arc in tiles.
  let amount =
    case ability
    of SiegeScarab, DreadTotem: 0.18'f
    of MothHex, ShadowComet: 0.12'f
    else: 0.0'f
  min(1.25'f, max(0.0'f, distance) * amount)

proc spellArcPoint*(origin, target: Vec3, progress, height: float32): Vec3 =
  ## Lifts only the middle of a flight while preserving both endpoints.
  let t = clamp(progress, 0.0'f, 1.0'f)
  result = mix(origin, target, t)
  result.y += 4 * height * t * (1 - t)

proc effectSettings(ability: Ability): FxSettings =
  ## Authors animated local geometry separately from the exact hit footprint.
  let spec = ability.abilitySpec
  result = defaultFxSettings()
  result.shape = spec.effect
  result.pivot = CenterPivot
  result.blendMode = AdditiveBlend
  result.texture = StreakTexture
  result.gradientSource = LifeGradient
  result.uvScale = vec2(2, 3)
  result.scroll = vec2(0.25, -1.6)
  result.noiseScale = 3
  result.dissolveEdge = 0.16
  result.dissolveOut = 0.35
  result.fadeOut = 0.25
  result.expandStart = 0.65
  result.expandEnd = 1.05
  result.expandPower = 0.6
  result.radius = max(0.4'f, spec.area.radius.float32 / WorldScale.float32 / 2)
  result.innerRadius = result.radius * 0.78
  result.height = 0.65
  result.thickness = 0.10
  result.radialSegments = 48
  result.widthSegments = 12
  result.arcDegrees = 360
  result.angleOffset = 90
  case spec.casting
  of SelfCast:
    result.shape = HelixShape
    result.radius = 0.4
    result.height = 0.8
    result.turns = 2
    result.pitch = 0.3
    result.spinSpeed = 1.8
  of MeleeCast:
    result.shape = ArcShape
    result.radius = spec.range.float32 / WorldScale.float32 / 2
    result.innerRadius = result.radius * 0.5
    result.arcDegrees = 110
    result.arcCrescent = 0.9
    result.sweepSource = SweepU
    result.sweepBand = 0.6
    result.sweepSoft = 0.12
  of ProjectileCast:
    result.shape = SphereShape
    result.radius = 0.13
    result.texture = CellTexture
    result.spinSpeed = 2.2
    result.pulseAmp = 0.08
    result.pulseSpeed = 10
    result.expandStart = 1
    result.expandEnd = 1
    result.dissolveOut = 0
    result.fadeOut = 0
    if ability in {DragonSight, VerdantArrow, FinalMeasure, SiegeScarab}:
      result.shape = BoxShape
      result.size = vec3(0.05, 0.05, 0.4)
      result.spinSpeed = 0
  of AreaCast:
    case result.shape
    of AoeLineShape, AoeConeShape, AoeCapsuleShape:
      result = spec.area.footprintSettings()
    of ArcShape:
      result.arcDegrees = spec.area.angle.float32
      result.arcCrescent = 1
      result.sweepSource = SweepU
      result.sweepBand = 0.65
      result.sweepSoft = 0.08
    of AoeCircleShape:
      result.shape = RingShape
      result.texture = NoiseTexture
      result.rippleAmp = 0.12
      result.rippleFreq = 8
      result.rippleSpeed = 2
    of DiscShape:
      result.innerRadius = 0
      result.spinSpeed = 2
      result.texture = CellTexture
    of SphereShape, HemisphereShape:
      result.texture = CellTexture
      result.innerRadius = 0
      result.waveAmp = 0.05
      result.waveFreq = 5
      result.waveSpeed = 3
    of CylinderShape:
      result.height = 1.5
      result.gradientSource = AxisGradient
    of HelixShape:
      result.turns = 3
      result.pitch = 0.3
      result.spinSpeed = 2
      result.texture = CellTexture
    of TorusShape:
      result.texture = CellTexture
      result.spinSpeed = 1.5
      result.pulseAmp = 0.06
      result.pulseSpeed = 8
    of BoxShape:
      result.size = vec3(
        spec.area.width.float32 / WorldScale.float32 / 2,
        0.55,
        spec.area.length.float32 / WorldScale.float32 / 2
      )
      result.texture = NoiseTexture
    else:
      discard

proc drawGlow(effects: var SpellRenderer, viewProjection, model: Mat4,
    color: Vec3, time, opacity: float32) =
  ## Adds a soft luminous core using the same simulation clock as the spell.
  var settings = defaultFxSettings()
  settings.shape = SphereShape
  settings.radius = 0.10
  settings.radialSegments = 12
  settings.heightSegments = 6
  settings.pivot = CenterPivot
  settings.texture = SoftTexture
  settings.blendMode = AdditiveBlend
  settings.startColor = vec4(mix(color, vec3(1), 0.2), opacity * 0.25)
  settings.endColor = vec4(color, 0.0)
  if effects.glow.vertices.len == 0:
    effects.glow = buildFxMesh(settings)
  effects.renderer.uploadFxMesh(effects.glow)
  effects.renderer.drawFxMesh(settings, viewProjection, model, time, 0.2)

proc matches(area: AreaMesh, spell: SpellCast): bool =
  ## Rejects stale geometry when a seek is followed by a different cast.
  area.heroId == spell.heroId and area.started == spell.started and
    area.ability == spell.ability and area.position == spell.position and
    area.direction == spell.direction

proc drawTowerShots(
    effects: var SpellRenderer,
    world: World,
    viewProjection: Mat4,
    alpha: float32,
    viewMode: int32
) =
  ## Draws homing fireballs and impacts directly from replay simulation state.
  var settings = defaultFxSettings()
  settings.shape = SphereShape
  settings.pivot = CenterPivot
  settings.radius = 0.22
  settings.radialSegments = 16
  settings.heightSegments = 8
  settings.texture = NoiseTexture
  settings.blendMode = AdditiveBlend
  settings.startColor = vec4(1.0, 0.85, 0.25, 1.0)
  settings.endColor = vec4(1.0, 0.16, 0.02, 0.6)
  settings.scroll = vec2(0.7, -1.8)
  settings.waveAmp = 0.04
  settings.waveFreq = 5
  settings.waveSpeed = 6
  if effects.fireball.vertices.len == 0:
    effects.fireball = buildFxMesh(settings)
  for shot in world.towerShots:
    let
      age = (world.tick.float32 + alpha - shot.started.float32) /
        TickRate.float32
      impact = shot.impact > 0
      fade =
        if impact:
          clamp(1 - (world.tick.float32 + alpha - shot.impact.float32) /
            TowerImpactTicks.float32, 0, 1)
        else:
          1.0'f
      position =
        if impact:
          shot.position.spellPoint()
        else:
          mix(shot.previous.spellPoint(), shot.position.spellPoint(), alpha)
      size = if impact: 1 + (1 - fade) * 3 else: 1.0'f
      base = translate(position)
    if not world.effectVisible(viewMode, position):
      continue
    settings.startColor.w = fade
    settings.endColor.w = fade * 0.6
    effects.renderer.uploadFxMesh(effects.fireball)
    effects.renderer.drawFxMesh(
      settings, viewProjection, base, age, 0.2, sizeScale = size
    )
    effects.drawGlow(viewProjection, base, vec3(1.0, 0.5, 0.04), age, fade)

proc drawSpells*(
    effects: var SpellRenderer,
    world: World,
    viewProjection: Mat4,
    alpha: float32,
    viewMode: int32
) =
  ## Layers map warnings, flowing textures, and impacts for every caster.
  let
    time = world.tick.float32 + alpha
    seconds = time / TickRate.float32
  effects.drawTowerShots(world, viewProjection, alpha, viewMode)
  var write = 0
  for area in effects.areas:
    for spell in world.casts:
      if area.matches(spell):
          effects.areas[write] = area
          inc write
          break
  effects.areas.setLen(write)
  for spell in world.casts:
    let
      ability = spell.ability
      spec = ability.abilitySpec
      caster = world.heroById(spell.heroId)
    let
      pending = not spell.resolved
      age = max(0.0'f, time - spell.started.float32) / TickRate.float32
      progress = clamp((time - spell.started.float32) /
        max((spell.impact - spell.started).float32, 1), 0, 1)
      fade = clamp((spell.ends.float32 - time) / 12, 0, 1)
      life = if pending: progress else: 1 - fade
      color = ability.spellColor
      light = mix(color, vec3(1), 0.7)
      teamColor =
        if spec.damage == 0: vec3(0.3, 1.0, 0.5)
        elif caster.team == RedTeam: vec3(1.0, 0.3, 0.12)
        else: vec3(0.2, 0.65, 1.0)
    var
      position = spell.position.spellPoint()
      angle = arctan2(spell.direction.x.float32, spell.direction.z.float32)
      pitch = 0.0'f
    case spec.casting
    of ProjectileCast:
      var target = position
      if spell.targetId != 0:
        let hero = world.heroById(spell.targetId)
        if hero.id != 0:
          target = hero.position.spellPoint()
        else:
          let footman = world.footmanById(spell.targetId)
          if footman.id != 0:
            target = footman.position.spellPoint()
      let
        origin = spell.origin.spellPoint()
        offset = target - origin
        distance = length(vec2(offset.x, offset.z))
        height = spellArcHeight(ability, distance)
      position = spellArcPoint(origin, target, progress, height)
      position.y += 0.8
      if height > 0 and distance > 0.001'f:
        pitch = arctan2(offset.y + 4 * height * (1 - 2 * progress), distance)
    of MeleeCast:
      position = spell.origin.spellPoint() + vec3(0, 0.65, 0)
      angle += life * 0.6 - 0.3
    else:
      position.y = mapHeight(position) + 0.10
    if not world.effectVisible(viewMode, position):
      continue
    let base = translate(position) * rotateY(angle) * rotateX(-pitch)
    if spec.casting == AreaCast:
      var
        ground = spec.area.footprintSettings()
        offset = vec3(0.0'f)
      if spec.area.shape == CapsuleFootprint:
        offset.z = ground.width / 2
      elif spec.area.shape == CrossFootprint:
        offset.z = -ground.length / 2
      var index = -1
      for i, area in effects.areas:
        if area.matches(spell):
            index = i
            break
      if index < 0:
        index = effects.areas.len
        effects.areas.add areaMesh(
          ground, spell, base * translate(offset),
          spec.area.shape == CrossFootprint
        )
      effects.renderer.uploadFxMesh(effects.areas[index].mesh)
      if ability in {StormEagle, ClockworkCharge}:
        # Keep the warning still, then send one front along the cast area.
        if pending:
          ground.startColor = vec4(teamColor, 0.14'f)
          ground.endColor = ground.startColor
          effects.renderer.drawFxMesh(
            ground, viewProjection, mat4(), seconds, 0, sizeScale = 1
          )
        else:
          let sweep = clamp(
            (time - spell.impact.float32) /
              max((spell.ends - spell.impact).float32, 1),
            0.0'f,
            1.0'f
          )
          ground.blendMode = AdditiveBlend
          ground.texture = StreakTexture
          ground.uvScale = vec2(3, 4)
          ground.scroll = vec2(0)
          ground.sweepSource = SweepV
          ground.sweepBand = 0.24'f
          ground.sweepSoft = 0.045'f
          ground.startColor = vec4(light, 0.9'f)
          ground.endColor = vec4(color, 0.45'f)
          ground.edgeColor = vec4(light, 1)
          effects.renderer.drawFxMesh(
            ground, viewProjection, mat4(), seconds, sweep, sizeScale = 1
          )
        continue
      # The full footprint stays visible under the moving decorative layers.
      ground.startColor = vec4(teamColor,
        if pending: 0.12'f + progress * 0.10'f else: fade * 0.20'f)
      ground.endColor = ground.startColor
      effects.renderer.drawFxMesh(
        ground, viewProjection, mat4(), seconds, life, sizeScale = 1
      )
      ground.blendMode = AdditiveBlend
      ground.texture =
        case spec.area.shape
        of LineFootprint, CapsuleFootprint, SectorFootprint: StreakTexture
        of RingFootprint: CellTexture
        else: NoiseTexture
      ground.uvScale = vec2(3, 4)
      ground.scroll = vec2(0.12, -0.75)
      ground.startColor = vec4(color,
        if pending: 0.42'f + 0.12'f * sin(age * 5) else: fade * 0.9'f)
      ground.endColor = vec4(light, ground.startColor.w * 0.5)
      ground.edgeColor = vec4(light, 1)
      effects.renderer.drawFxMesh(
        ground, viewProjection, mat4(), seconds, life, sizeScale = 1
      )
      # One bright front crosses the full cast without restarting on impact.
      ground.sweepSource =
        if spec.area.shape in {CircleFootprint, RingFootprint, SectorFootprint}:
          SweepRadial
        else:
          SweepV
      ground.sweepBand = 0.24
      ground.sweepSoft = 0.045
      ground.startColor = vec4(light, if pending: 0.7'f else: fade)
      ground.endColor = vec4(color, ground.startColor.w * 0.5)
      let sweep = clamp(
        (time - spell.started.float32) /
          max((spell.ends - spell.started).float32, 1),
        0.0'f,
        1.0'f
      )
      effects.renderer.drawFxMesh(
        ground, viewProjection, mat4(), seconds, sweep, sizeScale = 1
      )
      # Floating sparks trace the area while it charges and lift on impact.
      for i in 0 ..< 4:
        let phase = i.float32 / 4
        var local: Vec3
        case spec.area.shape
        of LineFootprint, CapsuleFootprint, CrossFootprint:
          local = vec3(
            (if i mod 2 == 0: -0.35'f else: 0.35'f) * ground.width,
            0,
            (phase + age * 0.4'f - floor(phase + age * 0.4'f)) *
              spec.area.length.float32 / WorldScale.float32
          )
        of SectorFootprint:
          let theta = (phase - 0.375'f) * ground.arcDegrees * PI.float32 / 180
          local = vec3(sin(theta), 0, cos(theta)) * ground.radius * 0.85
        of CircleFootprint, RingFootprint:
          let theta = phase * PI.float32 * 2 + age
          local = vec3(cos(theta), 0, sin(theta)) * ground.radius * 0.85
        var mote = base * local
        mote.y = mapHeight(mote) + 0.25 +
          (if pending: 0.10'f * sin(age * 4 + phase * 6) else: life * 1.5'f)
        effects.drawGlow(viewProjection, translate(mote), color, seconds,
          if pending: 0.55'f else: fade * 0.8'f)
      if pending:
        continue
      if spec.effect in {AoeLineShape, AoeConeShape, AoeCapsuleShape}:
        continue
    var settings = ability.effectSettings()
    let strength =
      if spec.effect in {HelixShape, TorusShape}: 0.35'f
      elif spec.casting == AreaCast: 0.75'f
      else: 1.0'f
    settings.startColor = vec4(mix(color, vec3(1), 0.2),
      strength * (if pending: 0.95'f else: fade))
    settings.endColor = vec4(color,
      strength * (if pending: 0.65'f else: fade * 0.45'f))
    settings.edgeColor = vec4(light, 1)
    if effects.meshes[ability].vertices.len == 0:
      effects.meshes[ability] = buildFxMesh(settings)
    var model = base
    if spec.casting == SelfCast:
      model = base * translate(vec3(0, 0.8, 0))
    elif spec.casting == AreaCast and spec.effect == BoxShape:
      model = base * translate(vec3(0, 0.55,
        spec.area.length.float32 / WorldScale.float32 / 2))
    effects.renderer.uploadFxMesh(effects.meshes[ability])
    effects.renderer.drawFxMesh(settings, viewProjection, model, age, life)
    if spec.casting == ProjectileCast:
      if pending:
        # The wake follows the shot; it never changes projectile collision.
        var trail = defaultFxSettings()
        trail.shape = ConeShape
        trail.pivot = StartPivot
        trail.radius = 0.09
        trail.topRadius = 0
        trail.height = 0.7
        trail.texture = StreakTexture
        trail.uvScale = vec2(2, 2)
        trail.scroll = vec2(0, -3)
        trail.blendMode = AdditiveBlend
        trail.gradientSource = AxisGradient
        trail.startColor = vec4(color, 0.8)
        trail.endColor = vec4(color, 0)
        if effects.trail.vertices.len == 0:
          effects.trail = buildFxMesh(trail)
        effects.renderer.uploadFxMesh(effects.trail)
        effects.renderer.drawFxMesh(
          trail, viewProjection, base * rotateX(-PI.float32 / 2), age, 0.2
        )
      effects.drawGlow(viewProjection, base, color, seconds, fade)
    elif spec.casting == SelfCast:
      # Small orbiting motes make healing and restoration visibly different.
      for i in 0 ..< 4:
        let
          phase = i.float32 * PI.float32 / 2 + age * 3
          offset = vec3(cos(phase) * 0.7, 0.4 + life, sin(phase) * 0.7)
        effects.drawGlow(
          viewProjection,
          base * translate(offset),
          color, seconds, fade * 0.6
        )

proc placementPreview*(
  world: World,
  hero: Hero,
  slot: HeroAbilitySlot,
  targetId: int32,
  point: WorldPoint,
  spell: var SpellCast
): ActionError =
  ## Resolves the footprint at the expected release position for placement.
  result = world.aimAbility(hero, slot, targetId, point, spell)
  if result notin {NoActionError, ActionOutOfRange}:
    return
  let spec = spell.ability.abilitySpec(spell.level)
  if result == ActionOutOfRange and spec.casting == AreaCast and
    spec.fromCaster:
      var destination = point
      if targetId != 0:
        var target: WorldObject
        if world.spellTarget(targetId, target):
          destination = target.position
      let
        dx = destination.x.float64 - hero.position.x.float64
        dz = destination.z.float64 - hero.position.z.float64
        distance = sqrt(dx * dx + dz * dz)
      if distance > 0:
        # Preview the release position at cast range, not the walking hero.
        spell.position = WorldPoint(
          x: destination.x - int32(round(dx * spec.range.float64 / distance)),
          y: destination.y,
          z: destination.z - int32(round(dz * spec.range.float64 / distance))
        )
        spell.origin = spell.position
  spell.started = 0

proc queuedCastPreview*(world: World, hero: Hero, spell: var SpellCast): bool =
  ## Resolves the pending order without altering its target or simulation.
  if hero.id == 0 or not hero.hasQueuedCast or hero.hp <= 0:
    return false
  world.placementPreview(
    hero,
    hero.queuedCastSlot,
    hero.queuedCastTarget,
    hero.queuedCastPoint,
    spell
  ) in {NoActionError, ActionOutOfRange}

proc queuedContours*(area: FxArea): seq[seq[Vec2]] =
  ## Returns closed polygon boundaries for every simulation footprint.
  const Segments = 64
  let
    radius = area.radius.float32 / WorldScale.float32
    inner = area.innerRadius.float32 / WorldScale.float32
    halfWidth = area.width.float32 / WorldScale.float32 / 2
    length = area.length.float32 / WorldScale.float32
  var points: seq[Vec2]
  case area.shape
  of CircleFootprint, RingFootprint:
    for r in [radius, inner]:
      if r <= 0:
        continue
      points = @[]
      for i in 0 ..< Segments:
        let angle = i.float32 * 2 * PI.float32 / Segments.float32
        points.add vec2(sin(angle), cos(angle)) * r
      result.add points
      if area.shape == CircleFootprint:
        break
    return
  of SectorFootprint:
    let angle = area.angle.float32 * PI.float32 / 180
    for i in 0 .. Segments:
      let theta = -angle / 2 + angle * i.float32 / Segments.float32
      points.add vec2(sin(theta), cos(theta)) * radius
    if inner > 0:
      for i in countdown(Segments, 0):
        let theta = -angle / 2 + angle * i.float32 / Segments.float32
        points.add vec2(sin(theta), cos(theta)) * inner
    else:
      points.add vec2(0)
  of LineFootprint:
    points = @[vec2(-halfWidth, 0), vec2(halfWidth, 0),
      vec2(halfWidth, length), vec2(-halfWidth, length)]
  of CapsuleFootprint:
    for cap in 0 .. 1:
      for i in 0 .. Segments div 2:
        let
          theta = (-0.5'f + cap.float32 +
            i.float32 / (Segments div 2).float32) * PI.float32
          center = if cap == 0: max(halfWidth, length - halfWidth)
            else: halfWidth
        points.add vec2(sin(theta) * halfWidth,
          center + cos(theta) * halfWidth)
  of CrossFootprint:
    let halfLength = length / 2
    points = @[
      vec2(-halfWidth, -halfLength), vec2(halfWidth, -halfLength),
      vec2(halfWidth, -halfWidth), vec2(halfLength, -halfWidth),
      vec2(halfLength, halfWidth), vec2(halfWidth, halfWidth),
      vec2(halfWidth, halfLength), vec2(-halfWidth, halfLength),
      vec2(-halfWidth, halfWidth), vec2(-halfLength, halfWidth),
      vec2(-halfLength, -halfWidth), vec2(-halfWidth, -halfWidth)
    ]
  result.add points

proc drawCastOutline(effects: var SpellRenderer, outline: var AreaMesh,
    spell: SpellCast, viewProjection: Mat4, seconds: float32, valid: bool,
    offset: Vec3) =
  ## Keeps a bright terrain-following wall around the pending action area.
  let
    spec = spell.ability.abilitySpec(spell.level)
    area =
      if spec.casting == AreaCast: spec.area
      else: FxArea(shape: CircleFootprint, radius: 27_000)
  if effects.queuedContours[spell.ability].len == 0:
    effects.queuedContours[spell.ability] = queuedContours(area)
  if not outline.matches(spell) or outline.mesh.indices.len == 0:
    let model = translate(spell.position.spellPoint()) * rotateY(
      arctan2(spell.direction.x.float32, spell.direction.z.float32)
    )
    outline.mesh.vertices.setLen(0)
    outline.mesh.indices.setLen(0)
    for contour in effects.queuedContours[spell.ability]:
      for i in 0 ..< contour.len:
        let
          first = contour[i]
          last = contour[(i + 1) mod contour.len]
          segments = max(1, int(ceil((last - first).length / 0.35'f)))
        for segment in 0 ..< segments:
          let base = outline.mesh.vertices.len.uint32 div 12
          for point in [
            mix(first, last, segment.float32 / segments.float32),
            mix(first, last, (segment + 1).float32 / segments.float32)
          ]:
            var bottom = model * vec3(point.x, 0, point.y)
            bottom.y = mapHeight(bottom) + 0.08'f
            for level in 0 .. 1:
              let
                height = level.float32
                vertex = bottom + vec3(0, height * 0.4'f, 0)
                shimmer = height * sin(bottom.x * 5 + bottom.z * 7)
              outline.mesh.vertices.add [
                vertex.x, vertex.y, vertex.z,
                0.0'f, shimmer, 0,
                0.0'f, height,
                height, 0, 0, 0
              ]
          outline.mesh.indices.add [
            base, base + 2, base + 1, base + 1, base + 2, base + 3
          ]
    outline.heroId = spell.heroId
    outline.started = spell.started
    outline.ability = spell.ability
    outline.position = spell.position
    outline.direction = spell.direction
  var settings = defaultFxSettings()
  settings.texture = SolidTexture
  settings.blendMode = AdditiveBlend
  settings.gradientSource = AxisGradient
  settings.startColor =
    if valid: vec4(0.3, 0.95, 1.0, 0.85)
    else: vec4(1.0, 0.2, 0.15, 0.85)
  settings.endColor = vec4(settings.startColor.xyz, 0)
  settings.expandStart = 1
  settings.expandEnd = 1
  settings.pulseAmp = 0.04'f
  settings.pulseSpeed = 3.5'f
  settings.fadeIn = 0
  settings.fadeOut = 0
  effects.renderer.uploadFxMesh(outline.mesh)
  effects.renderer.drawFxMesh(
    settings, viewProjection, translate(offset), seconds, 0.5, sizeScale = 1
  )

proc drawAim*(effects: var SpellRenderer, spell: SpellCast,
    viewProjection: Mat4, seconds: float32, valid: bool, offset: Vec3) =
  ## Moves the glowing placement outline with the cursor until confirmed.
  effects.drawCastOutline(
    effects.preview,
    spell,
    viewProjection,
    seconds,
    valid,
    offset
  )

proc drawQueuedCast*(effects: var SpellRenderer, spell: SpellCast,
    viewProjection: Mat4, seconds: float32, offset: Vec3) =
  ## Retains the same glowing outline while the hero approaches the cast.
  effects.drawCastOutline(
    effects.queued,
    spell,
    viewProjection,
    seconds,
    true,
    offset
  )

proc drawPortals*(effects: var SpellRenderer, world: World,
    viewProjection: Mat4, alpha: float32, viewMode: int32) =
  ## Builds energy at both visible endpoints until the teleport completes.
  let seconds = (world.tick.float32 + alpha) / TickRate.float32
  var ring = defaultFxSettings()
  ring.shape = RingShape
  ring.radius = 0.95
  ring.innerRadius = 0.78
  ring.radialSegments = 64
  ring.texture = StreakTexture
  ring.blendMode = AdditiveBlend
  ring.scroll = vec2(0.18, 0)
  ring.uvScale = vec2(6, 1)
  ring.fadeIn = 0
  ring.fadeOut = 0
  ring.startColor = vec4(0.65, 0.4, 1, 0.85)
  ring.endColor = ring.startColor
  var tube = ring
  tube.shape = CylinderShape
  tube.height = 2.6
  tube.radialSegments = 48
  tube.heightSegments = 12
  tube.gradientSource = AxisGradient
  tube.texture = NoiseTexture
  tube.scroll = vec2(0.14, -0.65)
  tube.uvScale = vec2(4, 2)
  tube.startColor = vec4(0.5, 0.28, 1, 0.24)
  tube.endColor = vec4(0.7, 0.85, 1, 0)
  tube.waveAmp = 0.025
  tube.waveFreq = 2
  tube.waveSpeed = 4
  for hero in world.heroes:
    if hero.portalEnds <= world.tick or hero.hp <= 0:
      continue
    let progress = clamp(1 - (hero.portalEnds.float32 - world.tick.float32 -
      alpha) / PortalChannelTicks.float32, 0.0'f, 1.0'f)
    if effects.portalRing.vertices.len == 0:
      effects.portalRing = buildFxMesh(ring)
      effects.portalTube = buildFxMesh(tube)
    for point in [hero.position, hero.portalDestination]:
      var center = point.spellPoint()
      if not world.effectVisible(viewMode, center):
        continue
      center.y = mapHeight(center) + 0.09'f
      let base = translate(center)
      ring.startColor = vec4(0.65, 0.4 + progress * 0.35, 1, 0.85)
      ring.endColor = ring.startColor
      effects.renderer.uploadFxMesh(effects.portalRing)
      effects.renderer.drawFxMesh(
        ring, viewProjection, base, seconds, progress, sizeScale = 1
      )
      for i in 0 ..< 2:
        let rise = (seconds * 0.65'f + i.float32 * 0.5'f) mod 1.0'f
        var halo = ring
        halo.startColor.w = (1 - rise) * 0.45'f
        halo.endColor = halo.startColor
        effects.renderer.drawFxMesh(
          halo, viewProjection, base * translate(vec3(0, rise * 2.5, 0)),
          seconds, progress, sizeScale = 1
        )
      tube.startColor.w = 0.18'f + progress * 0.2'f
      effects.renderer.uploadFxMesh(effects.portalTube)
      effects.renderer.drawFxMesh(
        tube, viewProjection, base, seconds, progress, sizeScale = 1
      )
      for i in 0 ..< 12:
        let
          phase = i.float32 / 12
          rise = (seconds * 0.7'f + phase) mod 1.0'f
          angle = phase * 2 * PI.float32 + seconds * 2
          position = center + vec3(
            cos(angle) * 0.85'f, 0.1'f + rise * 2.6'f,
            sin(angle) * 0.85'f
          )
        effects.drawGlow(viewProjection, translate(position),
          vec3(0.65, 0.6, 1), seconds, (1 - rise) * (0.8'f + progress))

proc closeSpellRenderer*(effects: var SpellRenderer) =
  ## Releases the spell mesh renderer alongside the other scene effects.
  effects.renderer.closeFxRenderer()
  effects.areas.setLen(0)
  effects.preview = AreaMesh()
  effects.queued = AreaMesh()
  effects.queuedContours = default(typeof(effects.queuedContours))
  effects.meshes = default(typeof(effects.meshes))
  effects.glow = default(SpellMesh)
  effects.trail = default(SpellMesh)
  effects.fireball = default(SpellMesh)
  effects.portalRing = default(SpellMesh)
  effects.portalTube = default(SpellMesh)
