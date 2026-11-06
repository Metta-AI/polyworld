## Watching an expedition. The camera follows the party down, and the world
## is drawn as a cutaway: the uppermost selected hero's floor, plus everything
## below it, so you can see the levels they have yet to reach through the
## shafts while the ceilings above them are simply not drawn.
##
## Nothing in this file is authoritative. It reads the simulation and turns
## body poses into smooth float positions; no value computed here is ever
## written back.

import
  std/[math, tables, times],
  chroma, fixxy, opengl, pixie, silky, vmath, windy,
  polyworld/[actioncam, assets, characters, clickmarks, common, inputs,
    particles, particleshaders, chrome, pathing, player, profiles,
    quadterrain, rtscameras, screenocclusions, selectionoutlines, shadows,
    shapes, tapes, terrainsurfaces, viewers, visions, worldbars, worldtexts],
  abilityfx, appearances, attackclips, assets, content, maps, sim, game,
  replays, ui, controls, isocam

when defined(takeScreenshot):
  import std/[os, strutils]

const
  CameraDistanceScale = 1.75'f32
    ## Pulls every camera mode back so spectators see more of the dungeon.
  DefaultCameraDistance = 13.0'f * CameraDistanceScale
  ArenaFrameMargin = 1.06'f32
    ## Breathing room around the arena room in its fixed shot.
  ArenaFrameTop = 2.3'f32
    ## Heads and name labels by the far wall stay in the arena shot.
  PanPixelScale = 0.05'f32
    ## Ground units a drag moves the camera per screen pixel.
  BodyCutaway = TerrainCutaway(
    towardEye: isoBack(),
    rise: 0.85,
    halfWidth: 0.95,
    halfHeight: 1.35,
    clearance: 0.3
  )
    ## The hole cut through walls in front of a body: centered on its chest,
    ## a little wider and taller than the body itself on screen.
  DungeonOcclusion = ScreenOcclusionSettings(
    enabled: true,
    radius: 1.2,
    intensity: 3.0,
    bias: 0.08,
    tint: vec3(0.10, 0.10, 0.16),
    sharpness: 15.4,
    bodyOcclusion: 0.25
  )
    ## Soft contact shadows where walls meet floors and under bodies: CaC's
    ## SSAO, a little tighter and lighter. Bodies keep a quarter of their own.
    ## CTA_SSAO=0 or F8 turns it off; CTA_SSAO_RADIUS, _INTENSITY and _BIAS
    ## override these.
  AtlasPath = TmpRoot & "/cta.atlas.png"
  SimulationStep = 1.0'f32 / TickRate.float32
  SeekCheckpointTicks = TickRate * 10
  PathLift = 0.2'f32
  PathHalfWidth = 0.12'f32
  FacingHeight = 0.85'f32
  FacingOffset = 0.4'f32
  FacingLength = 0.45'f32
  FacingHalfWidth = 0.18'f32
  CorpseLingerTicks = TickRate * 8
    ## How long a fallen monster lies still before it sinks away.
  CorpseSinkTicks = TickRate * 3 div 2
  CorpseSinkDepth = 1.0'f32
  RunFadeSeconds = 0.15'f32
    ## How long a body takes to ease into a run or back out of one.

type
  ActorVisual = object
    ## Retains animation timing and one prepared pose for an actor slot.
    angle: float32
    animTime: float32
    clip: int
    visible: bool
    pose: CharacterPose
    gait: Gait
    fadeLeft: float32     ## game seconds left of a run fade
    fadeFrom: seq[Mat4]   ## the joints that fade eases out of

  Corpse = object
    ## An actor the simulation removed when it fell. The client keeps its
    ## body to play the death clip; monsters then sink, heroes stay down.
    kind: ActorKind
    class: uint8
    home: TileRef
    position: Vec3
    angle: float32
    tick: int32       ## the tick it fell on
    visible: bool
    pose: CharacterPose

  SeekCheckpoint = object
    ## Captures all authoritative state needed for an exact replay seek.
    tick: int32
    world: World
    log: seq[string]
    actionIndex: int
    hashCheck: ReplayHashCheck

var sk: Silky

proc registerTileColors() =
  ## Maps every dungeon kind to the generated texture array after loading.
  setTileMaterial(
    int(GrassTile), GrassSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.85'f), 1
  )
  setTileMaterial(
    int(RoadTile), DirtSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.85'f), 5
  )
  setTileMaterial(
    int(RockTile), CryptRockSurface, CryptRockSurface,
    vec3(1), vec3(0.8'f), 4
  )
  setTileMaterial(
    int(MarshTile), MarshSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.8'f), 2
  )
  setTileMaterial(
    int(StoneTile), CryptStoneSurface, CryptStoneSurface,
    vec3(1), vec3(0.85'f), 6
  )
  setTileMaterial(
    int(TreeTile), ForestSurface.float32, DirtSurface.float32,
    vec3(1), vec3(0.85'f), 0
  )
  setTileMaterial(
    int(FloorTile), CryptFloorSurface, CryptStoneSurface,
    vec3(1), vec3(0.8'f), 10
  )
  setTileMaterial(
    int(RubbleTile), CryptRubbleSurface, CryptRockSurface,
    vec3(1), vec3(0.8'f), 11
  )
  setTileMaterial(
    int(LavaTile), CryptLavaSurface, CryptLavaSurface,
    vec3(1), vec3(0.85'f), 16
  )
  setTileMaterial(
    int(ObsidianTile), CryptCrustSurface, CryptRockSurface,
    vec3(0.72'f), vec3(0.65'f), 15
  )
  setTileMaterial(
    int(GoldTile), VaultSurface, CryptStoneSurface,
    vec3(1, 0.9'f, 0.65'f), vec3(0.8'f), 17
  )
  setTileMaterial(
    int(MossTile), MarshSurface.float32, CryptRockSurface,
    vec3(1), vec3(0.8'f), 12
  )
  setTileMaterial(
    int(RampTile), CryptFloorSurface, CryptRockSurface,
    vec3(1.1'f), vec3(0.8'f), 13
  )

proc renderPosition(actor: Actor): Vec3 =
  ## Converts a tile-space body into a render position on the actor's floor.
  let
    base = tileCenter(
      int(actor.home.level), int(actor.home.x), int(actor.home.z))
    x = toFloat32(actor.body.pos.x) - HalfGrid
    z = toFloat32(actor.body.pos.y) - HalfGrid
  vec3(x, base.y, z)

proc actorYaw(actor: Actor): float32 =
  ## Renderer yaw from body facing: `arctan2(dx, dz)`. East is +pi/2,
  ## south is 0, west is -pi/2, north is pi.
  let dir = direction(actor.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc travelYaw(fromPos, toPos: Vec3, fallback: float32): float32 =
  ## Renderer yaw of a world-space step, or fallback when the step is tiny.
  let
    dx = toPos.x - fromPos.x
    dz = toPos.z - fromPos.z
  if dx * dx + dz * dz < 1e-8'f32:
    fallback
  else:
    arctan2(dx, dz)

proc startRunFade(visual: var ActorVisual) =
  ## Keeps the pose on show for the next ones to ease out of. A fade cut
  ## short starts from where it had got to, since its blend is on show.
  if visual.pose.toon.meshCount > 0:
    visual.fadeFrom = visual.pose.toon.meshes[0].joints
    visual.fadeLeft = RunFadeSeconds

proc easeRunFade(visual: var ActorVisual, dt: float32) =
  ## Blends a freshly prepared pose with the one it replaced. Characters
  ## pose one clip at a time, so the fade works on the finished joints. They
  ## are local to the mesh, so it doesn't matter how far the body has moved.
  if visual.fadeLeft <= 0:
    return
  visual.fadeLeft -= dt
  let weight = smoothstep(0'f32, 1'f32, 1 - visual.fadeLeft / RunFadeSeconds)
  template joints: untyped = visual.pose.toon.meshes[0].joints
  if weight >= 1 or visual.fadeFrom.len != joints.len:
    visual.fadeLeft = 0
    return
  for joint in 0 ..< joints.len:
    for column in 0 .. 3:
      for row in 0 .. 3:
        joints[joint][column, row] = mix(
          visual.fadeFrom[joint][column, row],
          joints[joint][column, row],
          weight
        )

proc actorPathColor(actor: Actor): ColorRGBX =
  ## Returns a stable debug color for one actor's followed path.
  if actor.kind == HeroActor:
    case actor.heroClass
    of FighterClass: rgbx(194, 125, 62, 255)
    of WizardClass: rgbx(126, 89, 210, 255)
    of RogueClass: rgbx(57, 153, 181, 255)
    of ClericClass: rgbx(213, 177, 73, 255)
  else:
    rgbx(235, 72, 56, 255)

proc liftedPathPoint(position: Vec3): Vec3 =
  ## Raises a path point so the line sits above the floor.
  vec3(position.x, position.y + PathLift, position.z)

proc addFacingTriangle(
    renderer: var ShapeRenderer,
    actor: Actor,
    color: ColorRGBX
) =
  ## Draws the heading the simulation currently stores on this body.
  let
    dir = direction(actor.body.facing)
    fx = toFloat32(dir.x)
    fz = toFloat32(dir.y)
  if fx * fx + fz * fz < 1e-8'f32:
    return
  let
    forward = normalize(vec3(fx, 0, fz))
    right = vec3(-forward.z, 0, forward.x)
    origin =
      renderPosition(actor) +
      forward * FacingOffset +
      vec3(0, FacingHeight, 0)
    tip = origin + forward * FacingLength
    left = origin + right * FacingHalfWidth
    rightPt = origin - right * FacingHalfWidth
  renderer.addTriangle(tip, left, rightPt, color)

proc addActorPaths(
    renderer: var ShapeRenderer,
    world: World,
    visibleFrom: int
) =
  ## Adds remaining path ribbons and a facing triangle for each living actor.
  for actor in world.actors:
    if actor.id == 0 or not actor.alive:
      continue
    if int(actor.home.level) < visibleFrom:
      continue
    if actor.kind == MonsterActor and not selectedVisible(actor.home):
      continue
    let color = actorPathColor(actor)
    renderer.addFacingTriangle(actor, color)
    if actor.path.len == 0 or actor.pathIndex >= int32(actor.path.len):
      continue
    var points: seq[Vec3]
    points.add liftedPathPoint(renderPosition(actor))
    for i in int(actor.pathIndex) ..< actor.path.len:
      let tile = actor.path[i].tile
      if int(tile.level) < visibleFrom:
        if points.len >= 2:
          renderer.addPolyline(points, color, PathHalfWidth)
        points.setLen(0)
        continue
      points.add liftedPathPoint(
        tileCenter(int(tile.level), int(tile.x), int(tile.z))
      )
    if points.len >= 2:
      renderer.addPolyline(points, color, PathHalfWidth)

proc makeCircleIcon(size: int, fill: ColorRGBA): Image =
  ## Builds a filled circle sprite for compact HUD chrome.
  result = newImage(size, size)
  let ctx = newContext(result)
  ctx.fillStyle = fill
  ctx.fillCircle(
    circle(vec2(size.float32 * 0.5'f32), size.float32 * 0.46'f32)
  )

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs the theme logo and compact HUD glyphs.
  builder.addThemeLogo(LogoPath)
  if not builder.addImage(
      "cta_badge",
      makeCircleIcon(22, rgba(18, 20, 28, 255))
    ):
    raise newException(
      ValueError,
      "the UI atlas is too small for HUD glyphs"
    )

proc addAbilityIcons(builder: AtlasBuilder) =
  ## Packs every ability art file used by the action bar.
  const AbilityDir = DataRoot & "/abilities/"
  for _, name in AbilityIconFiles:
    if name.len == 0:
      continue
    let icon = readImage(AbilityDir & name & ".png").resize(128, 128)
    if not builder.addImage("ability_" & name, icon):
      raise newException(
        ValueError,
        "the UI atlas is too small for ability icons"
      )

proc runGraphics*() =
  ## Runs the native or Emscripten graphical expedition viewer.
  startGameProfile()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    for class in HeroClass:
      let portrait = readImage(HeroPortraitPaths[class])
      if not builder.addImage(HeroPortraitKeys[class], portrait):
        raise newException(
          ValueError,
          "Failed to allocate hero portrait: " & HeroPortraitPaths[class]
        )
    addHudIcons(builder)
    addAbilityIcons(builder)
    builder.addDefaultFonts()
    builder.addFont(DefaultFontPath, "WorldName", 32.0)
    builder.write(AtlasPath)
  var window: Window
  profileBlock "window":
    (window, sk) = initGameWindow(
      "Call to Adventure",
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync,
      msaa = msaa4x
    )
  let splash = startSplash(sk, window)
  # The stack spans about 45 tiles top to bottom; the shading uses amplitude
  # as its height scale, so a value near the whole span keeps every level
  # readable instead of clipping the deep ones to black.
  profileBlock "terrain":
    amplitude = 48.0
    seed = run.world.setup.seed.int
    initTerrain(
      NoTrees, GeneratedTerrain, NoRocks, CtaTerrainTiles,
      settings = CtaTerrainAssets
    )
    registerTileColors()
    bakeTerrain(rebuildWalkability = false)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  var
    particles = initParticleSystem()
    clickMarks = initClickMarks()
    worldBarRenderer = initWorldBarRenderer()
    playerLabels = layoutNames(
      sk.atlas.fonts["WorldName"],
      sk.atlas.size,
      run.config.players
    )
    worldShapes = initShapeRenderer()
    abilityShapes = initShapeRenderer()
    damageTrails: DamageTrailTracker
    selectionOutline = initSelectionOutline()
    occlusion = initScreenOcclusion(
      screenOcclusionSettings("CTA_SSAO", DungeonOcclusion))
    models: CharacterModels
  profileBlock "models":
    models = loadCharacterModels()
  let
    heroModels = models.heroes
    monsterModels = models.monsters
  drawSplash(sk, window, splash.name)

  var
    heroIdle, heroRun, heroAttack: array[HeroClass, int]
    monsterIdle, monsterRun, monsterAttack: array[Species, int]
    heroDeath: array[HeroClass, int]
    monsterDeath: array[Species, int]
    heroSpell: array[HeroClass, int]
    monsterSpell: array[Species, int]
    heroBeats: array[HeroClass, ClipBeats]
    fighterSlash, fighterRoar: int
    monsterBeats: array[Species, ClipBeats]
  let spellBeats = clipBeats(SpellClip)
  for class in HeroClass:
    let
      model = heroModels[class]
      clips = class.heroClips()
    heroIdle[class] = model.clipIndex(clips[0])
    heroRun[class] = model.clipIndex(clips[1])
    heroAttack[class] = model.clipIndex(clips[2])
    heroDeath[class] = model.clipIndex(DeathClip)
    heroSpell[class] = model.clipIndex(SpellClip)
    heroBeats[class] = clipBeats(clips[2])
  fighterSlash = heroModels[FighterClass].clipIndex(BlazingSlashClip)
  fighterRoar = heroModels[FighterClass].clipIndex(TauntRoarClip)
  for species in Species:
    let
      model = monsterModels[species]
      clips = speciesClips(species)
    monsterIdle[species] = model.clipIndex(clips[0])
    monsterRun[species] = model.clipIndex(clips[1])
    monsterAttack[species] = model.clipIndex(clips[2])
    monsterDeath[species] = model.clipIndex(DeathClip)
    monsterSpell[species] = model.clipIndex(SpellClip)
    monsterBeats[species] = clipBeats(clips[2])

  var
    visuals: seq[ActorVisual]
    corpses: seq[Corpse]
    lifted: seq[LiftedLoot]
      ## Items picked up in the last moment, still rising off the floor.
    previousActorPositions: Table[int32, Vec3]
    previousActorFacings: Table[int32, float32]
    renderAlpha = 1.0'f32

  proc captureActorPositions() =
    ## Remembers the visual pose before one authoritative tick.
    var
      nextPositions: Table[int32, Vec3]
      nextFacings: Table[int32, float32]
    for actor in run.world.actors:
      if actor.id == 0:
        continue
      let pos = renderPosition(actor)
      nextPositions[actor.id] = pos
      nextFacings[actor.id] = travelYaw(
        previousActorPositions.getOrDefault(actor.id, pos),
        pos,
        actorYaw(actor)
      )
    previousActorPositions = nextPositions
    previousActorFacings = nextFacings

  proc actorRenderPosition(actor: Actor): Vec3 =
    ## Interpolates one actor between the two latest simulation snapshots.
    let current = renderPosition(actor)
    if not interpolateVisuals:
      return current
    mix(
      previousActorPositions.getOrDefault(actor.id, current),
      current,
      renderAlpha
    )

  proc actorRenderFacing(actor: Actor): float32 =
    ## Interpolates the last walked heading the short way. Travel yaw is
    ## taken from the tick's displacement so a ±pi wrap in body facing
    ## cannot spin the model.
    if not interpolateVisuals:
      return actorYaw(actor)
    let
      currentPos = renderPosition(actor)
      current = travelYaw(
        previousActorPositions.getOrDefault(actor.id, currentPos),
        currentPos,
        actorYaw(actor)
      )
      previous = previousActorFacings.getOrDefault(actor.id, current)
    previous + shortestTurn(previous, current) * renderAlpha

  proc actorGroundSpeed(actor: Actor): float32 =
    ## World units per game second of the step being interpolated, which is
    ## how fast the body on screen is moving, pushes and slides included.
    let
      current = renderPosition(actor)
      step = current - previousActorPositions.getOrDefault(actor.id, current)
    length(vec2(step.x, step.z)) * TickRate.float32

  proc attackClipTime(actor: Actor, clip: int, model: CharacterModel,
      beats: ClipBeats): float32 =
    ## Times an attack clip off the ability's phases rather than the wall
    ## clock, library clips and authored ones alike, so the clip's blow
    ## lands on the tick the hit does however long the swing.
    attackClipTime(actor.action, beats, model.clipDuration(clip),
      actor.actionTime(renderAlpha))

  proc addAbilityTells(visibleFrom: int) =
    ## Marks every visible skill still winding up with its one gizmo: a
    ## circle round its target or the shape of its area, and an arrow from
    ## its caster.
    for slot in 0 ..< run.world.actors.len:
      let actor = run.world.actors[slot]
      if not actor.alive or not actor.busy or
          int(actor.home.level) < visibleFrom:
        continue
      if actor.kind == MonsterActor and not selectedVisible(actor.home):
        continue
      let time = actor.actionTime(renderAlpha)
      if not actor.action.telegraphed(time):
        continue
      let spec = Abilities[actor.action]
      var tell = Telegraph(
        side: actor.sideOf,
        targeting: spec.targeting,
        progress: time / spec.anticipationTicks.float32,
        caster: actorRenderPosition(actor)
      )
      case spec.targeting
      of AreaTarget:
        tell.shape = spec.shape
        tell.center = tileFeet(actor.aim)
        tell.reach = spec.radiusTiles.float32 + 0.5'f32
        if spec.shape == LineArea:
          tell.center = tileFeet(
            run.world.lineEnd(spec, actor.home, actor.aim))
      of SingleTarget:
        # A target that has fallen or left the floor keeps its marker where
        # it stood as the wind-up began.
        tell.center = tileFeet(actor.aim)
        tell.reach = actor.markerRadius
        let targetSlot = run.world.actorSlot(actor.target)
        if targetSlot >= 0 and run.world.actors[targetSlot].alive and
            run.world.actors[targetSlot].home.level == actor.home.level:
          let target = run.world.actors[targetSlot]
          tell.center = actorRenderPosition(target)
          tell.reach = target.markerRadius
      abilityShapes.addTelegraph(tell)

  proc addWarriorEffects(visibleFrom: int, right, up: Vec3) =
    ## Status-driven, interpolated effects also remain correct during seeks.
    let clock = (run.world.tick.float32 + renderAlpha) / TickRate.float32
    for actor in run.world.actors:
      if not actor.alive or int(actor.home.level) < visibleFrom or
          not selectedVisible(actor.home): continue
      let center = actorRenderPosition(actor)
      if actor.kind == MonsterActor and actor.tauntTicks > 0:
        let
          height = HeroTargetHeight * RankScales[actor.species.monsterRank]
          anchor = center + vec3(0, height + 0.65'f32 + sin(clock * 8) * 0.045'f32, 0)
          fade = min(1.0'f32, actor.tauntTicks.float32 / 6)
        # Four bent strokes: the angry red popped-vein mark.
        for sx in [-1.0'f32, 1.0'f32]:
          for sy in [-1.0'f32, 1.0'f32]:
            let
              x = right * sx
              y = up * sy
              a = anchor + x * 0.07'f32 + y * 0.26'f32
              b = anchor + x * 0.07'f32 + y * 0.10'f32
              c = anchor + x * 0.26'f32 + y * 0.10'f32
            for layer in 0 ..< 2:
              let
                w = if layer == 0: 0.055'f32 else: 0.025'f32
                ink = if layer == 0: rgbx(135, 3, 10, uint8(210 * fade))
                  else: rgbx(255, 48, 43, uint8(254 * fade))
              abilityShapes.addQuad(a - x*w, a + x*w, b + x*w, b - x*w, ink)
              abilityShapes.addQuad(b - y*w, b + y*w, c + y*w, c - y*w, ink)
      if actor.heatTicks > 0:
        let fade = min(1.0'f32, actor.heatTicks.float32 / 12)
        # Fill the whole footprint, retaining the original waving border.
        for band in 0 ..< 24:
          let
            inner = band.float32 / 24
            outer = (band + 1).float32 / 24
            edgeFade = min(1.0'f32, (1 - inner) * 6)
            pulse = 0.94'f32 + 0.06'f32 * sin(clock * 2.8'f32)
            ink = rgbx(255, 142, 22, uint8(62 * edgeFade * fade * pulse))
          for segment in 0 ..< 80:
            let
              a = segment.float32 * 2 * PI.float32 / 80
              b = (segment + 1).float32 * 2 * PI.float32 / 80
            proc groundPoint(angle, fraction: float32): Vec3 =
              let wave = sin(angle * 5 - clock * 2.8'f32) * 0.10'f32 +
                sin(angle * 9 + clock * 1.7'f32) * 0.045'f32
              let radius = (2.05'f32 + wave) * fraction
              center + vec3(cos(angle) * radius, 0.10'f32, sin(angle) * radius)
            abilityShapes.addQuad(groundPoint(a, inner), groundPoint(b, inner),
              groundPoint(b, outer), groundPoint(a, outer), ink)
        for band in 0 ..< 16:
          let v = band.float32 / 16
          for segment in 0 ..< 80:
            let
              a = segment.float32 * 2 * PI.float32 / 80
              b = (segment + 1).float32 * 2 * PI.float32 / 80
            proc point(angle, level: float32): Vec3 =
              let
                wave = sin(angle * 5 - clock * 2.8'f32) * 0.10'f32 +
                  sin(angle * 9 + clock * 1.7'f32) * 0.045'f32
                radius = 2.05'f32 + wave + level * 0.25'f32
                lift = 0.07'f32 + level * (0.65'f32 + sin(angle * 4 - clock * 3) * 0.18'f32)
              center + vec3(cos(angle) * radius, lift, sin(angle) * radius)
            let ink = rgbx(255, uint8(95 + 65 * (1 - v)), 22,
              uint8(36 * sin((v + 0.03'f32) * PI.float32) * fade))
            abilityShapes.addQuad(point(a, v), point(b, v),
              point(b, v + 1.0'f32/16), point(a, v + 1.0'f32/16), ink)
      if actor.kind == HeroActor and actor.heroClass == FighterClass and
          actor.busy and actor.action == BlazingBlade:
        let
          time = actor.actionTime(renderAlpha)
          spec = Abilities[BlazingBlade]
          beats = clipBeats(BlazingSlashClip)
          duration = heroModels[FighterClass].clipDuration(fighterSlash)
          angle = actorRenderFacing(actor)
        # Molten ribbon follows the measured sword, with a white-hot edge.
        if time >= spec.anticipationTicks.float32:
          for step in 0 ..< 28:
            let
              t0 = max(spec.anticipationTicks.float32, time - 6 + step.float32 * 6 / 28)
              t1 = min(spec.impactTicks.float32, t0 + 6.0'f32/28)
            if t0 >= t1: continue
            proc bladeAtTime(t: float32): tuple[root, tip: Vec3] =
              let
                motion = BlazingBlade.bodyMotion(t)
                body = translate(center + heading(angle) * motion.pull +
                  vec3(0, motion.lift, 0)) * rotateY(angle + motion.twist)
                blade = models.blazingBlade.bladeAt(
                  attackClipTime(BlazingBlade, beats, duration, t) / duration)
              (body * blade.root, body * blade.tip)
            let
              a = bladeAtTime(t0)
              b = bladeAtTime(t1)
              fade = max(0.0'f32, 1 - (time - t1) / 6)
            for layer in 0 ..< 3:
              let
                inner = [0.20'f32, 0.52'f32, 0.83'f32][layer]
                outer = [1.22'f32, 1.12'f32, 1.02'f32][layer]
                ink = [rgbx(255, 48, 4, uint8(85 * fade)),
                  rgbx(255, 142, 12, uint8(150 * fade)),
                  rgbx(255, 236, 150, uint8(230 * fade))][layer]
              abilityShapes.addQuad(mix(a.root, a.tip, inner),
                mix(b.root, b.tip, inner), mix(b.root, b.tip, outer),
                mix(a.root, a.tip, outer), ink)

  proc addVines(visibleFrom: int) =
    ## Draws Entangle's vines, and how tightly they hold whoever stands in
    ## them.
    let
      now = run.world.tick.float32 - 1 + renderAlpha
      clock = now / TickRate.float32
    for patch in run.world.vines:
      if int(patch.center.level) >= visibleFrom and
          selectedVisible(patch.center):
        abilityShapes.addVinePatch(patch, now, clock)
    for actor in run.world.actors:
      if not actor.alive or actor.entangledTicks == 0 or
          int(actor.home.level) < visibleFrom or
          not selectedVisible(actor.home):
        continue
      let scale =
        if actor.kind == HeroActor: 1.0'f32
        else: RankScales[actor.species.monsterRank]
      abilityShapes.addVineWrap(actorRenderPosition(actor), scale,
        actor.entangledTicks.float32 / VineRootTicks.float32)

  proc addDruidEffects(visibleFrom: int, right, up: Vec3) =
    ## Sunlight gathers in a rotating corona before the orb is loosed.
    for actor in run.world.actors:
      if not actor.alive or actor.kind != HeroActor or
          actor.heroClass != ClericClass or not actor.busy or
          int(actor.home.level) < visibleFrom or
          not selectedVisible(actor.home): continue
      let
        time = actor.actionTime(renderAlpha)
        spec = Abilities[actor.action]
      if actor.action == SunOrb and time < spec.anticipationTicks.float32:
        let
          charge = time / spec.anticipationTicks.float32
          center = actorRenderPosition(actor) + vec3(0, 1.25'f32, 0)
        for ray in 0 ..< 10:
          let
            angle = ray.float32 * TAU.float32 / 10 + time * 0.06'f32
            axis = right * cos(angle) + up * sin(angle)
            side = up * cos(angle) - right * sin(angle)
            near = center + axis * (0.18'f32 + charge * 0.12'f32)
            tip = center + axis * (0.28'f32 + charge * 0.22'f32)
          abilityShapes.addTriangle(near - side * 0.018'f32,
            near + side * 0.018'f32, tip, rgbx(255, 204, 84, uint8(130 * charge)))

  type
    ActorParticleState = object
      id: int32
      kind: ActorKind
      class: uint8
      hp: int16
      action: Ability
      actionTicks: int16
      home: TileRef
      position: Vec3
      angle: float32
      origin: Vec3
      targetFound: bool
      targetId: int32
      targetPosition: Vec3
      aim: TileRef
      victims: seq[Vec3]
      heatTicks: int16
      scorched: seq[Vec3]
  proc captureParticleActors(): seq[ActorParticleState] =
    ## Captures flat pre-tick combat data without retaining simulation refs.
    for actor in run.world.actors:
      if not actor.alive:
        continue
      let position = renderPosition(actor)
      var state = ActorParticleState(
        id: actor.id,
        kind: actor.kind,
        class: actor.class,
        hp: actor.hp,
        action: actor.action,
        actionTicks: actor.actionTicks,
        home: actor.home,
        position: position,
        angle: previousActorFacings.getOrDefault(actor.id, actorYaw(actor)),
        origin: position + vec3(0, 0.82'f32, 0),
        heatTicks: actor.heatTicks
      )
      for victim in run.world.scorched(run.world.actorSlot(actor.id)):
        state.scorched.add renderPosition(run.world.actors[victim]) +
          vec3(0, 0.72'f32, 0)
      let targetSlot = run.world.actorSlot(actor.target)
      if targetSlot >= 0 and run.world.actors[targetSlot].alive:
        state.targetFound = true
        state.targetId = actor.target
        state.targetPosition = renderPosition(
          run.world.actors[targetSlot]
        ) + vec3(0, 0.72'f32, 0)
      if actor.busy:
        state.aim = actor.aim
        if actor.actionTicks + 1 == Abilities[actor.action].impactTicks:
          for victim in run.world.victims(run.world.actorSlot(actor.id)):
            state.victims.add renderPosition(run.world.actors[victim]) +
              vec3(0, 0.72'f32, 0)
      result.add state

  proc launchMissile(state: ActorParticleState) =
    ## Looses a shot or a lob as its release begins, so it flies the rest
    ## of the release and bursts on the tick the hit lands.
    let
      spec = Abilities[state.action]
      look = AbilityLooks[state.action]
    var goal = state.targetPosition
    if spec.shape == LineArea and spec.radiusTiles > 0:
      goal = tileFeet(run.world.lineEnd(spec, state.home, state.aim)) +
        vec3(0, 0.72'f32, 0)
    elif spec.radiusTiles > 0:
      goal = tileFeet(state.aim) + vec3(0, 0.72'f32, 0)
    elif not state.targetFound:
      return
    let flight = max(float32(spec.releaseTicks - 1), 1) / TickRate.float32
    if state.action == SunOrb:
      goal = tileFeet(state.aim) + vec3(0, 0.06'f32, 0)
      # Decide which ground to burn only when the orb actually arrives.
      particles.emitParticleFlight(look.missile, state.origin, goal, flight)
    else:
      particles.emitParticleProjectile(look.missile, look.burst,
        state.origin, goal, flight)

  proc launchVolley(state: ActorParticleState, ticks: int16) =
    ## Climbs a volley out of the bow over the first half of the release,
    ## then brings every arrow down across the area to land with the hit.
    let
      spec = Abilities[state.action]
      look = AbilityLooks[state.action]
      climb = spec.releaseTicks div 2
      middle = tileFeet(state.aim)
      reach = spec.radiusTiles.float32 + 0.5'f32
    for index in 0 ..< VolleyArrows:
      let
        spot = volleySpot(index) * reach
        sky = middle + vec3(spot.x, VolleyHeight, spot.y)
      if ticks == spec.anticipationTicks + 1:
        # Nothing is struck up there, so the climb ends in its own trail.
        particles.emitParticleProjectile(
          look.missile, look.missile, state.origin, sky,
          float32(climb) / TickRate.float32)
      elif ticks == spec.anticipationTicks + 1 + climb:
        particles.emitParticleProjectile(
          look.missile, look.burst, sky,
          middle + vec3(spot.x, 0.1'f32, spot.y),
          float32(spec.releaseTicks - climb - 1) / TickRate.float32)

  proc igniteBlade(state: ActorParticleState, ticks: int16) =
    ## Lights the Fighter's sword where it will be over the coming tick,
    ## which the frames then play out. The flames outlive the blade's
    ## passing, so as it sweeps they leave its arc burning in the air.
    if HeroClass(state.class) != FighterClass:
      return
    let
      beats = clipBeats(BlazingSlashClip)
      duration = models.heroes[FighterClass].clipDuration(
        models.heroes[FighterClass].clipIndex(BlazingSlashClip))
      steps = BlazingBlade.bladeFlames((ticks - 1).float32)
    for step in 0 ..< steps:
      let
        part = step.float32 / steps.float32
        time = (ticks - 1).float32 + part
        motion = BlazingBlade.bodyMotion(time)
        body = translate(state.position +
          heading(state.angle) * motion.pull + vec3(0, motion.lift, 0)) *
          rotateY(state.angle + motion.twist)
        blade = models.blazingBlade.bladeAt(
          attackClipTime(BlazingBlade, beats, duration, time) / duration)
      particles.emitParticleSpan(BladeFlame, body * blade.root,
        body * blade.tip, part / TickRate.float32)

  proc emitTickParticles(oldActors: seq[ActorParticleState]) =
    ## Emits each missile as it leaves, each blow as it lands, and all
    ## actual hit-point restoration, once.
    var blooming: seq[int32]
    for source in oldActors:
      if source.action == Bloom and source.targetFound and
          source.actionTicks + 1 == Abilities[Bloom].impactTicks:
        blooming.add source.targetId
    for old in oldActors:
      let slot = run.world.actorSlot(old.id)
      if slot >= 0 and
          run.world.actors[slot].hp > old.hp:
        particles.emitParticleBurst(
          (if old.id in blooming: BloomPetals else: MendingAura),
          renderPosition(run.world.actors[slot]),
          anchor = old.id
        )
      for victim in old.scorched:
        particles.emitParticleBurst(CombatSparks, victim)
      if old.action == NoAbility:
        continue
      let
        spec = Abilities[old.action]
        look = AbilityLooks[old.action]
        ticks = old.actionTicks + 1
      if old.action == Bloom:
        if ticks == spec.anticipationTicks + 1 and old.targetFound:
          particles.emitParticleFlight(BloomSeed,
            old.origin, old.targetPosition,
            max(1.0'f32, spec.releaseTicks.float32 - 1) / TickRate.float32)
      if old.action == SunOrb and ticks == spec.impactTicks:
        var fueledByVines = false
        for patch in run.world.vines:
          if (patch.holding(run.world.tick) or patch.burned > 0) and
              not patch.gone(run.world.tick) and patch.orbLandsIn(old.aim):
            fueledByVines = true
            break
        if not fueledByVines:
          let middle = tileFeet(old.aim) + vec3(0, 0.06'f32, 0)
          particles.emitParticleSpan(SolarFlames, middle,
            middle + vec3(SunOrbGroundFlameRadius, 0, 0))
        # Ignited patches each emit one full-area fire below; no extra
        # orb-centered fire is layered onto a vine landing.
      if old.action == BlazingBlade and ticks == spec.anticipationTicks + 1:
        # Aim from the same tiles and use the same radius as inCone.
        let direction = tileFeet(old.aim) - tileFeet(old.home)
        if length(direction) > 0.001'f32:
          let origin = old.position + vec3(0, 0.45'f32, 0)
          particles.emitParticleSpan(FireWave, origin, origin +
            normalize(direction) * (spec.radiusTiles.float32 + 0.5'f32))
      if old.action.burning(ticks.float32 - 1) and old.kind == HeroActor:
        igniteBlade(old, ticks)
      if look.delivery == VolleyDelivery:
        launchVolley(old, ticks)
      elif look.delivery in Projectiles and
          ticks == spec.anticipationTicks + 1:
        launchMissile(old)
      # A missile bursts where it ends, which for a line is past its victims.
      if ticks == spec.impactTicks and not look.plain and
          spec.damage > 0 and
          (look.delivery notin Projectiles or spec.shape == LineArea):
        for victim in old.victims:
          particles.emitParticleBurst(look.burst, victim)
    for patch in run.world.vines:
      if patch.sprouted == run.world.tick:
        particles.emitParticleBurst(RootLeaves, tileFeet(patch.center))
    # Consumed vines fuel a rising bed of flame over the whole patch.
    # The patch itself chars and disappears on the simulation's burn clock.
    for patch in run.world.vines:
      if patch.burned == run.world.tick:
        let middle = tileFeet(patch.center) + vec3(0, 0.06'f32, 0)
        particles.emitParticleSpan(SolarFlames, middle,
          middle + vec3(vineReach(), 0, 0))

  proc collectCorpses(oldActors: seq[ActorParticleState]) =
    ## Keeps a body for everyone who fell this tick, and lets monster
    ## bodies that have sunk away go.
    for old in oldActors:
      let slot = run.world.actorSlot(old.id)
      if slot < 0 or not run.world.actors[slot].alive:
        corpses.add Corpse(
          kind: old.kind,
          class: old.class,
          home: old.home,
          position: old.position,
          angle: old.angle,
          tick: run.world.tick
        )
    var kept = 0
    for corpse in corpses:
      if corpse.kind == HeroActor or run.world.tick - corpse.tick <
          CorpseLingerTicks + CorpseSinkTicks:
        corpses[kept] = corpse
        inc kept
    corpses.setLen(kept)

  proc collectLifted(oldItems: seq[Item]) =
    ## Keeps every item picked up this tick on screen while it rises away.
    lifted.add run.world.pickedUp(oldItems)
    var kept = 0
    for loot in lifted:
      if float32(run.world.tick - loot.tick) < PickupLiftTicks:
        lifted[kept] = loot
        inc kept
    lifted.setLen(kept)

  proc advanceTracked() =
    ## Advances one tick outside the frame loop, still keeping bodies and
    ## the loot rising away.
    let
      oldActors = captureParticleActors()
      oldItems = run.world.items
    advanceGame()
    collectCorpses(oldActors)
    collectLifted(oldItems)

  var
    cameraDistance = DefaultCameraDistance
    cameraTarget = vec3(0, 0, 0)
    panning = false
    minimapPanning = false
    lastMouse = ivec2(0, 0)
    lastFrameTime = epochTime()
    followSelection = false
    cameraEase: CameraEase
    focusPlayerHero = false
    viewingDt = 0.0'f
    viewingSeeking = false
    actionCam = initActionCam(
      subjectMode = true,
      defaultDistance = DefaultCameraDistance,
      minDistance = 12 * CameraDistanceScale,
      maxDistance = 36 * CameraDistanceScale,
      tight = 0.35,
      followRate = 3.5,
      zoomRate = 2.5,
      holdSeconds = 0.7,
      mapSpan = 28
    )
    primaryId = 0
    selectedIds: array[PartySize, bool]
    playerSlot = options.playerSlot - 1
    attackTargetId = 0'i32
    selectionPressPosition = vec2(0)
    rightPressPosition = vec2(0)
    selectionStarted = false
    selectionAdditive = false
    groupCameraScale = 1.0'f32
    terrainVisionTick = int32.low
    terrainVisionLevel = int32.low
    replayCheckpoints: seq[SeekCheckpoint]
    transport = initPlayer(
      live = not run.replayMode,
      durationTicks = options.maximumTicks,
      playing = not options.pauseOnStart,
      speed = options.speed,
      repeating = true
    )

  proc copyLog(): seq[string] =
    ## Copies the presentation log into an independent checkpoint value.
    for line in run.log:
      result.add line

  proc captureCheckpoint(): SeekCheckpoint =
    ## Captures the exact simulation and replay cursor at the current tick.
    SeekCheckpoint(
      tick: run.world.tick,
      world: run.world.clone(),
      log: copyLog(),
      actionIndex: run.replayPlayer.actionIndex,
      hashCheck: run.hashCheck
    )

  proc restoreCheckpoint(checkpoint: SeekCheckpoint) =
    ## Restores one simulation checkpoint without rebinding the game object.
    run.world.restore(checkpoint.world)
    run.log = checkpoint.log
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = checkpoint.hashCheck

  proc cacheSeekCheckpoint() =
    ## Extends the seek cache as playback reaches new territory.
    let finalTick = transport.timelineEnd
    if run.world.tick mod SeekCheckpointTicks != 0 and
        run.world.tick != finalTick:
      return
    if replayCheckpoints.len == 0 or
        replayCheckpoints[^1].tick < run.world.tick:
      replayCheckpoints.add captureCheckpoint()

  proc restoreTo(target: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    var checkpointIndex = 0
    for i, checkpoint in replayCheckpoints:
      if checkpoint.tick > target:
        break
      checkpointIndex = i
    restoreCheckpoint(replayCheckpoints[checkpointIndex])
    run.historyPlayback = true
    transport.accumulator = 0
    previousActorPositions.clear()
    previousActorFacings.clear()
    particles.clearParticles()
    var kept = 0
    for corpse in corpses:
      if corpse.tick <= run.world.tick:
        corpses[kept] = corpse
        inc kept
    corpses.setLen(kept)
    kept = 0
    for loot in lifted:
      if loot.tick <= run.world.tick:
        lifted[kept] = loot
        inc kept
    lifted.setLen(kept)
    renderAlpha = 1
    while run.world.tick < target:
      advanceTracked()
      cacheSeekCheckpoint()

  replayCheckpoints = @[captureCheckpoint()]

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one party hero.
    options.playerSlot > 0 and not run.replayMode

  proc partyCenter(): Vec3 =
    ## Returns the average interpolated position of the living party.
    var
      total = vec3(0, 0, 0)
      count = 0
    for slot in 0 ..< PartySize:
      if run.world.actors[slot].alive:
        total = total + actorRenderPosition(run.world.actors[slot])
        inc count
    if count == 0: cameraTarget else: total / count.float32

  cameraTarget = partyCenter()

  proc selectedAlive(): bool =
    ## Returns whether the selected party slot contains a living hero.
    primaryId >= 0 and
      primaryId < min(PartySize, run.world.actors.len) and
      run.world.actors[primaryId].alive

  proc selectedCount(): int =
    ## Returns the number of selected party slots.
    for selected in selectedIds:
      if selected:
        inc result

  proc selectedLivingCount(): int =
    ## Returns the number of selected heroes currently alive.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      if selectedIds[slot] and run.world.actors[slot].alive:
        inc result

  proc selectedLivingHero(): int =
    ## Returns the first selected living hero slot, or minus one.
    result = -1
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      if selectedIds[slot] and run.world.actors[slot].alive:
        return slot

  proc selectedViewLevel(): int =
    ## Returns the uppermost floor a selected living hero stands on.
    if playerMode() and
        playerSlot >= 0 and
        playerSlot < run.world.actors.len:
      return int(run.world.actors[playerSlot].home.level)
    if actionCam.enabled and actionCam.locked:
      return int(actionCam.director.subject.floor)
    int(run.viewLevel(selectedIds))

  proc updateSelectionCamera() =
    ## Activates the camera mode appropriate for the current selection.
    let livingCount = selectedLivingCount()
    followSelection = livingCount > 0
    if livingCount > 1:
      groupCameraScale = 1.0'f32

  proc selectEntity(slot: int, additive = false) =
    ## Selects one party slot and updates the shared camera selection.
    if slot < 0 or slot >= min(PartySize, run.world.actors.len):
      return
    if not additive:
      for i in 0 ..< PartySize:
        selectedIds[i] = false
    elif selectedIds[slot] and selectedCount() > 1:
      selectedIds[slot] = false
      if slot == primaryId:
        for i in 0 ..< PartySize:
          if selectedIds[i]:
            primaryId = i
            break
      updateSelectionCamera()
      actionCam.takeManual()
      return
    selectedIds[slot] = true
    primaryId = slot
    actionCam.takeManual()
    updateSelectionCamera()

  proc selectAllHeroes() =
    ## Selects every party hero and activates the group camera.
    for slot in 0 ..< PartySize:
      selectedIds[slot] = true
    if not selectedAlive():
      for slot in 0 ..< min(PartySize, run.world.actors.len):
        if run.world.actors[slot].alive:
          primaryId = slot
          break
    actionCam.takeManual()
    updateSelectionCamera()

  proc clearSelection() =
    ## Clears the party selection and leaves the camera free-floating.
    for slot in 0 ..< PartySize:
      selectedIds[slot] = false
    followSelection = false
    actionCam.takeManual()

  if playerMode():
    selectedIds[playerSlot] = true
    primaryId = playerSlot
    followSelection = false
    actionCam.enabled = false
    if playerSlot >= 0 and playerSlot < run.world.actors.len:
      cameraTarget =
        actorRenderPosition(run.world.actors[playerSlot]) +
          vec3(0, 0.85'f32, 0)
  else:
    selectAllHeroes()
    actionCam.enabled = true
    followSelection = false

  proc arenaCenter(): Vec3 =
    ## Returns the middle of the arena room's floor.
    let room = run.dungeon.rooms[ArenaLevel][0]
    vec3(
      room.x.float32 + room.width.float32 / 2 - HalfGrid,
      tileCenter(ArenaLevel, int(room.x), int(room.z)).y,
      room.z.float32 + room.depth.float32 / 2 - HalfGrid
    )

  proc arenaFrameDistance(): float32 =
    ## Returns the zoom that fits the arena room, its walls and the slab
    ## under them between the top and bottom HUD plates.
    let
      room = run.dungeon.rooms[ArenaLevel][0]
      floorY = arenaCenter().y
      band = window.hudFreeBand()
    isoFitDistance(
      vec3(
        room.x.float32 - 1 - HalfGrid,
        floorY - SlabSteps.float32 / 8,
        room.z.float32 - 1 - HalfGrid
      ),
      vec3(
        (room.x + room.width).float32 + 1 - HalfGrid,
        floorY + ArenaFrameTop,
        (room.z + room.depth).float32 + 1 - HalfGrid
      ),
      window.size.x.float32 / max(window.size.y.float32, 1),
      band.free
    ) * ArenaFrameMargin

  if run.world.isArena and not playerMode():
    # The arena room fits in one fixed shot, so hold it instead of chasing.
    actionCam.enabled = false
    cameraTarget = arenaCenter()
    cameraDistance = arenaFrameDistance()

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all selected living heroes.
    var count = 0
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if selectedIds[slot] and actor.alive:
        result = result + actorRenderPosition(actor)
        inc count
    if count > 0:
      result = result / count.float32

  proc selectedRadius(center: Vec3): float32 =
    ## Returns the largest planar distance from the selection midpoint.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not selectedIds[slot] or not actor.alive:
        continue
      let
        position = actorRenderPosition(actor)
        dx = position.x - center.x
        dz = position.z - center.z
      result = max(result, sqrt(dx * dx + dz * dz))

  proc feedCtaActions(observeTick = false) =
    ## Refreshes real subjects and observes every simulated tick.
    if not actionCam.enabled:
      return
    var subjects: seq[Subject]
    for slot, actor in run.world.actors:
      if actor.id == 0:
        continue
      let hero = actor.kind == HeroActor
      subjects.add Subject(
        id: actor.id, owner: (if hero: int32(slot) else: -1),
        floor: int32(actor.home.level), position: actorRenderPosition(actor),
        height: 0.85, radius: 0.8,
        visible: hero or selectedVisible(actor.home), alive: actor.alive,
        hp: int32(actor.hp), maxHp: int32(actor.maxHp), complete: true,
        participant: actor.target,
        fighting: actor.action != NoAbility and Abilities[actor.action].damage > 0,
        activity: int32(actor.actionTicks), gold: actor.carriedValue,
        returned: hero and run.world.returned[slot],
        idleScore: (if hero and actor.path.len > 0: 24.0'f else: 12.0'f),
        combatScore: (if hero: 125.0'f else: 85.0'f)
      )
    if observeTick and not viewingSeeking:
      actionCam.director.observe(subjects)
    var heroes: seq[Subject]
    for subject in subjects:
      if subject.owner >= 0:
        heroes.add subject
    actionCam.director.refresh(heroes)

  proc updateCutaways(visibleFrom: int) =
    ## Cuts walls, pillars and higher slabs out of the line of sight to
    ## every shown hero and the monsters they are fighting. The low
    ## isometric angle would otherwise bury a corridor behind its near wall.
    var
      cuts: seq[Vec4]
      targets: seq[int32]
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let hero = run.world.actors[slot]
      if hero.alive and int(hero.home.level) >= visibleFrom:
        let feet = actorRenderPosition(hero)
        cuts.add vec4(feet.x, feet.y, feet.z, 1)
        if hero.target != 0:
          targets.add hero.target
    for actor in run.world.actors:
      if cuts.len >= TerrainCutawaySlots:
        break
      if actor.kind == MonsterActor and actor.alive and
          actor.id in targets and int(actor.home.level) >= visibleFrom and
          selectedVisible(actor.home):
        let feet = actorRenderPosition(actor)
        cuts.add vec4(feet.x, feet.y, feet.z, 1)
    setTerrainCutaways(BodyCutaway, cuts)

  proc updateTerrainVision(level: int32) =
    ## Uploads softened party vision and explored memory for one floor.
    if terrainVisionTick == run.world.tick and
        terrainVisionLevel == level:
      return
    terrainVisionTick = run.world.tick
    terrainVisionLevel = level
    var values = newSeq[uint8](TilesPerLevel)
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          tile = TileRef(level: int8(level), x: uint8(x), z: uint8(z))
          index = z * GridTiles + x
        values[index] =
          if selectedVisible(tile): 255
          elif run.world.explored(tile): 48
          else: 0
    uploadTerrainVisibility(blurVisibility(values, GridTiles, GridTiles))

  proc screenPosition(position: Vec3, viewProjection: Mat4): Vec2 =
    ## Projects one world position into window pixel coordinates.
    let clip = viewProjection * vec4(
      position.x,
      position.y,
      position.z,
      1
    )
    if clip.w <= 0:
      return vec2(-10000)
    let normalized = vec2(clip.x / clip.w, clip.y / clip.w)
    vec2(
      (normalized.x * 0.5'f32 + 0.5'f32) * window.size.x.float32,
      (0.5'f32 - normalized.y * 0.5'f32) * window.size.y.float32
    )

  proc addPlayerNames(visibleFrom: int) =
    ## Labels party slots on the visible dungeon floors.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if slot >= run.config.players.len or not actor.alive or
        int(actor.home.level) < visibleFrom:
          continue
      let anchor = actorRenderPosition(actor) + vec3(0, 2.22'f, 0)
      worldBarRenderer.addText(
        playerLabels[slot],
        anchor
      )

  proc pickLoot(viewProjection: Mat4): int32 =
    ## Finds loose treasure under the pointer on the visible floor.
    result = 0
    var bestDistance = 28.0'f32
    let visibleFrom = selectedViewLevel()
    for item in run.world.items:
      if item.carrier != 0 or int(item.tile.level) < visibleFrom:
        continue
      let
        point = screenPosition(
          tileCenter(
            int(item.tile.level), int(item.tile.x), int(item.tile.z)
          ) + vec3(0, 0.4'f32, 0),
          viewProjection
        )
        distance = (point - window.mousePos.vec2).length
      if distance < bestDistance:
        bestDistance = distance
        result = item.id

  proc pickMonster(viewProjection: Mat4): int32 =
    ## Finds a living monster under the pointer on the visible floor.
    result = 0
    var bestDistance = 32.0'f32
    let visibleFrom = selectedViewLevel()
    for slot in PartySize ..< run.world.actors.len:
      let actor = run.world.actors[slot]
      if not actor.alive or actor.kind != MonsterActor or
          int(actor.home.level) < visibleFrom:
        continue
      let
        point = screenPosition(
          actorRenderPosition(actor) + vec3(0, 0.9'f32, 0),
          viewProjection
        )
        distance = (point - window.mousePos.vec2).length
      if distance < bestDistance:
        bestDistance = distance
        result = actor.id

  proc pickEntity(viewProjection: Mat4): int =
    ## Finds the nearest visible living hero under the pointer.
    result = -1
    var bestDistance = 32.0'f32
    let visibleFrom = selectedViewLevel()
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not actor.alive or int(actor.home.level) < visibleFrom:
        continue
      let
        point = screenPosition(
          actorRenderPosition(actor) + vec3(0, 0.9'f32, 0),
          viewProjection
        )
        delta = point - window.mousePos.vec2
        distance = sqrt(delta.x * delta.x + delta.y * delta.y)
      if distance < bestDistance:
        bestDistance = distance
        result = slot

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Left-click selects in spectator mode, or attacks, loots, and heals
    ## for the human hero.
    if not window.mouseReleased(MouseLeft):
      return
    let
      delta = window.mousePos.vec2 - selectionPressPosition
      dragDistance = sqrt(delta.x * delta.x + delta.y * delta.y)
    if selectionStarted and dragDistance <= 6.0'f32 and
        not mouseOverUi(window, sk.mousePos):
      if playerMode():
        let
          slot = playerSlot
          monster = pickMonster(viewProjection)
          loot = pickLoot(viewProjection)
          ally = pickEntity(viewProjection)
        if monster != 0:
          attackTargetId = monster
          queueAttackTarget(slot, monster)
        elif loot != 0:
          attackTargetId = 0
          queuePickupTarget(slot, loot)
        elif ally == slot:
          selectEntity(slot)
        elif ally >= 0:
          attackTargetId = 0
          queueHealTarget(slot, run.world.actors[ally].id)
        elif not selectionAdditive:
          clearSelection()
      else:
        let picked = pickEntity(viewProjection)
        if picked >= 0:
          selectEntity(picked, selectionAdditive)
        elif not selectionAdditive:
          for slot in 0 ..< PartySize:
            selectedIds[slot] = false
          followSelection = false
          actionCam.takeManual()
    selectionStarted = false

  proc updatePlayerWalk(viewProjection: Mat4) =
    ## Right-click walks the human hero onto the tile under the pointer.
    if not playerMode():
      return
    if not window.mouseReleased(MouseRight):
      return
    if mouseOverUi(window, sk.mousePos):
      return
    if (window.mousePos.vec2 - rightPressPosition).length > 6.0'f32:
      return
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
      picked = pickWalkableTile(
        origin,
        dir,
        selectedViewLevel()
      )
    if playerSlot < 0 or
        playerSlot >= run.world.actors.len or
        not run.world.actors[playerSlot].alive:
      return
    let
      monster = pickMonster(viewProjection)
      loot = pickLoot(viewProjection)
    if monster != 0:
      attackTargetId = monster
      queueAttackTarget(int32(playerSlot), monster)
      return
    if loot != 0:
      attackTargetId = 0
      queuePickupTarget(int32(playerSlot), loot)
      return
    if picked.hit:
      attackTargetId = 0
      queueWalkTo(
        int32(playerSlot),
        int32(picked.layer),
        int32(picked.x),
        int32(picked.z)
      )
      selectEntity(playerSlot)
      clickMarks.emitClickMark(
        tileCenter(picked.layer, picked.x, picked.z)
      )

  proc playerHeroFrame(): Vec3 =
    ## Returns the look-at that frames the human hero. The projection's
    ## HUD lift already raises it above the ability bar.
    if playerSlot < 0 or playerSlot >= run.world.actors.len:
      return cameraTarget
    let actor = run.world.actors[playerSlot]
    if not actor.alive:
      return cameraTarget
    actorRenderPosition(actor) + vec3(0, 0.85'f32, 0)

  proc addLootIcon(kind: LootKind, tile: TileRef, rise, alpha: float32) =
    ## Draws one loot icon over its tile, raised and faded as given.
    let
      ability = LootAbilities[kind]
      key =
        if ability != NoAbility:
          "ability_" & AbilityIconFiles[ability]
        else:
          case kind
          of GoldPile: "gold"
          of Gemstone: "crystal"
          of Chalice: "chalice"
          of Idol: "idol"
          of Crown: "crown"
          else: "bounty"
      tint =
        case kind
        of Chalice: rgbx(217, 209, 140, 255)
        of Idol: rgbx(158, 122, 82, 255)
        of Crown: rgbx(255, 199, 71, 255)
        else: rgbx(255, 255, 255, 255)
      entry = sk.atlas.entries[key]
      anchor = tileCenter(int(tile.level), int(tile.x), int(tile.z)) +
        vec3(0, 0.4'f + rise, 0)
    worldBarRenderer.addBillboardQuad(
      anchor,
      vec2(-0.36'f),
      vec2(0.72'f),
      rgbx(tint.r, tint.g, tint.b, uint8(tint.a.float32 * alpha)),
      vec2(entry.x.float32, entry.y.float32) / sk.atlas.size.float32,
      vec2(entry.width.float32, entry.height.float32) /
        sk.atlas.size.float32,
      textureMode = ColorTexture
    )

  proc addLootIcons(visibleFrom: int) =
    ## Draws the loot on the floor, and what was just picked up rising off
    ## it and fading away.
    for item in run.world.items:
      if item.carrier != 0 or int(item.tile.level) < visibleFrom or
        not selectedVisible(item.tile):
          continue
      addLootIcon(item.kind, item.tile, 0, 1)
    for loot in lifted:
      if int(loot.tile.level) < visibleFrom or not selectedVisible(loot.tile):
        continue
      let time = float32(run.world.tick - loot.tick) + renderAlpha
      addLootIcon(loot.kind, loot.tile, rise(time), fade(time))

  proc drawWorldBars(
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      visibleFrom: int,
      dt: float32
  ) =
    ## Draws hero resources and damage-gated monster health in the world.
    damageTrails.beginFrame()
    worldBarRenderer.clear()
    addLootIcons(visibleFrom)
    for actor in run.world.actors:
      if actor.id == 0 or not actor.alive or
          int(actor.home.level) < visibleFrom:
        continue
      let
        health = max(actor.hp, 0'i16).float32
        maximumHealth = max(actor.maxHp, 1'i16).float32
        delayedHealth = damageTrails.delayedValue(
          actor.id,
          health,
          maximumHealth,
          dt
        )
      if actor.kind == HeroActor:
        var bars = @[WorldResourceBar(
          value: health,
          maximum: maximumHealth,
          delayedValue: delayedHealth,
          height: 0.15'f32,
          color: healthColor(health, maximumHealth),
          showDamageTrail: true
        )]
        if actor.maxMana > 0:
          bars.add WorldResourceBar(
            value: max(actor.mana, 0'i16).float32,
            maximum: actor.maxMana.float32,
            delayedValue: max(actor.mana, 0'i16).float32,
            height: 0.09'f32,
            color: rgbx(60, 125, 231, 255)
          )
        let anchor = actorRenderPosition(actor) + vec3(0, 2.02'f32, 0)
        worldBarRenderer.addResourceBars(anchor, 1.55'f32, bars)
      elif actor.hp < actor.maxHp:
        let
          height = HeroTargetHeight * RankScales[actor.species.monsterRank]
          anchor = actorRenderPosition(actor) + vec3(0, height + 0.2'f, 0)
          bars = [WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.1'f32,
            color: healthColor(health, maximumHealth),
            showDamageTrail: true
          )]
        worldBarRenderer.addResourceBars(anchor, 1.0'f32, bars)
    damageTrails.finishFrame()
    addPlayerNames(visibleFrom)
    worldBarRenderer.draw(
      viewProjection,
      cameraRight,
      cameraUp,
      sk.atlasTextureId()
    )

  proc attackTargetSlot(visibleFrom: int): int32 =
    ## Returns the living attack-target slot, or minus one.
    if attackTargetId == 0:
      return -1
    let slot = run.world.actorSlot(attackTargetId)
    if slot < 0:
      attackTargetId = 0
      return -1
    let actor = run.world.actors[slot]
    if not actor.alive or actor.kind != MonsterActor:
      attackTargetId = 0
      return -1
    if int(actor.home.level) < visibleFrom or
        not selectedVisible(actor.home):
      return -1
    slot

  proc drawActorOutline(
      slot: int32,
      view,
      projection: Mat4,
      cameraEye: Vec3,
      outlineColor: Vec3
  ) =
    ## Draws one actor silhouette and composites it in `outlineColor`.
    if slot < 0 or slot >= run.world.actors.len or slot >= visuals.len:
      return
    if not visuals[slot].visible:
      return
    selectionOutline.beginMask(window.size)
    beginCharacters(scene, window, view, projection, cameraEye)
    scene.drawCharacter(visuals[slot].pose)
    finishCharacters(scene)
    selectionOutline.drawOutline(outlineColor)

  proc drawSelectedOutline(
      view,
      projection: Mat4,
      cameraEye: Vec3,
      visibleFrom: int
  ) =
    ## Draws the yellow party outline and the red attack-target outline.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not selectedIds[slot] or not actor.alive or
          int(actor.home.level) < visibleFrom:
        continue
      drawActorOutline(
        int32(slot),
        view,
        projection,
        cameraEye,
        SelectionOutlineColor
      )
    if playerMode():
      let target = attackTargetSlot(visibleFrom)
      if target >= 0:
        drawActorOutline(
          target,
          view,
          projection,
          cameraEye,
          AttackOutlineColor
        )

  window.onButtonPress = proc(button: Button) =
    sk.uiScale = gameUiScale(window)
    sk.mousePos = window.mousePos.vec2 / sk.uiScale
    case button
    of MouseLeft, MouseLeftKey:
      if window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]:
        if not playerMode():
          selectAllHeroes()
      elif not mouseOverUi(window, sk.mousePos):
        selectionPressPosition = window.mousePos.vec2
        selectionStarted = true
        selectionAdditive =
          window.buttonDown[KeyLeftShift] or
          window.buttonDown[KeyRightShift]
    of MouseRight, MouseRightKey:
      if not mouseOverUi(window, sk.mousePos):
        rightPressPosition = window.mousePos.vec2
        lastMouse = window.mousePos
    of MouseMiddle, MouseMiddleKey:
      if not mouseOverUi(window, sk.mousePos):
        lastMouse = window.mousePos
    of KeySpace:
      transport.handleKey(button)
    of KeyC:
      if not playerMode():
        actionCam.toggle(followSelection)
    of KeyT:
      scene.toggleShading()
    of KeyF8:
      occlusion.settings.enabled = not occlusion.settings.enabled
    of KeyF, KeyG:
      if playerMode() and
          playerSlot >= 0 and
          playerSlot < run.world.actors.len:
        let bag = int32(if button == KeyF: 0 else: 1)
        if window.buttonDown[KeyLeftShift] or
            window.buttonDown[KeyRightShift]:
          queueDropItem(int32(playerSlot), bag)
        else:
          queueUseItem(int32(playerSlot), bag)
      elif button == KeyF and
          not playerMode() and
          selectedLivingCount() > 0:
        followSelection = not followSelection
        if followSelection:
          actionCam.takeManual()
    of KeyF1, KeyF2:
      discard handleChromeKey(button)
    of KeyEscape:
      when not defined(emscripten):
        window.closeRequested = true
    else:
      discard

  window.onScroll = proc() =
    sk.uiScale = gameUiScale(window)
    sk.mousePos = window.mousePos.vec2 / sk.uiScale
    if not mouseOverUi(window, sk.mousePos):
      cancelCameraEase(cameraEase)
      if not playerMode():
        actionCam.takeManual()
      if not playerMode() and
          followSelection and selectedLivingCount() > 1:
        groupCameraScale = clamp(
          groupCameraScale *
            (1.0'f32 - window.scrollDelta.y * 0.1'f32 / 3.0'f32),
          0.75,
          3.0
        )
      else:
        cameraDistance = clamp(
          cameraDistance *
            (1.0'f32 - window.scrollDelta.y * 0.1'f32 / 3.0'f32),
          8,
          160
        )

  when defined(takeScreenshot):
    var screenshotFrame = 0
    applyScreenshotCamera(cameraDistance)
    if existsEnv("PBR"):
      scene.shading = PbrCharacters
    if existsEnv("SIM_TICKS"):
      for _ in 0 ..< getEnv("SIM_TICKS").parseInt:
        if run.world.phase in {EscapedPhase, WipedPhase}:
          break
        advanceTracked()
      # Snap rather than ease: a capture renders a handful of frames, which
      # is nowhere near enough for a smoothed camera to travel from the
      # entrance to wherever the party actually got to.
      if not run.world.isArena:
        cameraTarget = partyCenter()
    if run.replayMode and existsEnv("REPLAY_TICK"):
      transport.seekTo(int32(getEnv("REPLAY_TICK").parseInt))
      cameraTarget = partyCenter()
    if existsEnv("WARRIOR_VFX_PREVIEW"):
      # Deterministic render-only fixture; never part of a normal game.
      let preview = getEnv("WARRIOR_VFX_PREVIEW")
      for actor in run.world.actors.mitems:
        if actor.kind == MonsterActor:
          if preview == "taunt": actor.tauntTicks = TauntTicks
        elif actor.heroClass == FighterClass:
          actor.action = NoAbility
          if preview == "heat": actor.heatTicks = HeatTicks
          if preview == "blade":
            actor.action = BlazingBlade
            actor.actionTicks = Abilities[BlazingBlade].impactTicks - 1
      if preview == "blade":
        for state in captureParticleActors():
          if state.kind == HeroActor and HeroClass(state.class) == FighterClass:
            particles.emitParticleSpan(FireWave, state.position + vec3(0, 0.45'f32, 0),
              state.position + vec3(0, 0.45'f32, 0) + heading(state.angle) *
                (Abilities[BlazingBlade].radiusTiles.float32 + 0.5'f32))
            for tick in 12'i16 .. 14'i16:
              igniteBlade(state, tick)
              particles.advanceParticles(SimulationStep)
    if existsEnv("DRUID_VFX_PREVIEW"):
      let
        preview = getEnv("DRUID_VFX_PREVIEW")
        sampleTime = if existsEnv("DRUID_VFX_TIME"):
          max(0.0'f32, getEnv("DRUID_VFX_TIME").parseFloat.float32)
          else: 0.3'f32
      for actor in run.world.actors:
        if actor.kind != HeroActor or actor.heroClass != ClericClass: continue
        let center = renderPosition(actor)
        if preview == "bloom":
          actor.action = Bloom
          actor.target = actor.id
          actor.actionTicks = Abilities[Bloom].impactTicks + 1 +
            min(Abilities[Bloom].recoverTicks - 1, int16(sampleTime * TickRate.float32))
          if sampleTime * TickRate.float32 >= Abilities[Bloom].recoverTicks.float32:
            actor.action = NoAbility
          particles.emitParticleBurst(BloomPetals, center, anchor = actor.id)
          particles.advanceParticles(sampleTime)
        elif preview == "entangle":
          run.world.tick = max(2, int32(sampleTime * TickRate.float32) + 2)
          run.world.vines.add VinePatch(side: HeroActor, center: actor.home,
            sprouted: 1)
          actor.entangledTicks = min(VineRootTicks, int16(sampleTime * TickRate.float32))
          particles.emitParticleBurst(RootLeaves, center)
          particles.advanceParticles(sampleTime)
        elif preview in ["sun", "sunconsume"]:
          var patchCenter = actor.home
          patchCenter.x -= 3
          var aim = patchCenter
          aim.z -= 1 # Land near the edge, so patch-centered fire is clear.
          let
            goal = tileFeet(aim) + vec3(0, 0.06'f32, 0)
            flight = (Abilities[SunOrb].releaseTicks.float32 - 1) / TickRate.float32
          particles.emitParticleFlight(SolarOrb,
            center + vec3(0, 0.82'f32, 0), goal, flight)
          if preview == "sunconsume":
            run.world.tick = 100 + int32(sampleTime * TickRate.float32)
            let burnTick = 100 + int32(Abilities[SunOrb].releaseTicks - 1)
            let patch = VinePatch(side: HeroActor, center: patchCenter, sprouted: 90,
              burned: (if run.world.tick >= burnTick: burnTick else: 0),
              burnedFrom: aim)
            if not patch.gone(run.world.tick): run.world.vines.add patch
            let middle = tileFeet(patchCenter) + vec3(0, 0.06'f32, 0)
            particles.emitParticleSpan(SolarFlames, middle,
              middle + vec3(vineReach(), 0, 0), flight)
          else:
            particles.emitParticleSpan(SolarFlames, goal,
              goal + vec3(SunOrbGroundFlameRadius, 0, 0), flight)
          particles.advanceParticles(sampleTime)
        elif preview == "sunburst":
          let goal = center + vec3(0, 0.06'f32, 0)
          particles.emitParticleSpan(SolarFlames, goal,
            goal + vec3(SunOrbGroundFlameRadius, 0, 0))
          particles.advanceParticles(sampleTime)
    if existsEnv("SELECT_ALL"):
      selectAllHeroes()

  var
    viewingClock: ViewingClock
    cameraSeekSerial = -1

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime, SimulationStep)
      viewingDt = viewingClock.viewingDelta(window)
      viewingSeeking = transport.targetTick >= 0 or transport.restoreTick >= 0
      if not transport.playing or viewingSeeking:
        viewingDt = 0
      if cameraSeekSerial != transport.seekSerial:
        actionCam.resetDirector(transport.automaticSeek)
        cameraSeekSerial = transport.seekSerial
      sk.uiScale = gameUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        elif run.replayMode: int32(run.replayPlayer.data.hashes.len)
        else: run.world.tick
      transport.sync(
        run.world.tick,
        recorded,
        run.world.phase in {EscapedPhase, WipedPhase}
      )
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(
          run.world.tick,
          recorded,
          run.world.phase in {EscapedPhase, WipedPhase}
        )
      feedCtaActions(observeTick = true)
      transport.startFrame(dt, TickRate)
      let
        frameStart = epochTime()
        active = simulationActive(transport)
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(run.world.tick, options.maximumTicks, transport.live):
            break
          captureActorPositions()
          let
            oldActors = captureParticleActors()
            oldItems = run.world.items
          run.historyPlayback = transport.inHistory
          advanceGame()
          feedCtaActions(observeTick = true)
          emitTickParticles(oldActors)
          collectCorpses(oldActors)
          collectLifted(oldItems)
          cacheSeekCheckpoint()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            elif run.replayMode: int32(run.replayPlayer.data.hashes.len)
            else: run.world.tick
          transport.sync(
            run.world.tick,
            recordedNow,
            run.world.phase in {EscapedPhase, WipedPhase}
          )
      renderAlpha =
        if active:
          clamp(transport.accumulator / SimulationStep, 0.0'f32, 1.0'f32)
        else:
          1.0'f32
      if active:
        particles.advanceParticles(dt * transport.speed.float32)
        clickMarks.advanceClickMarks(dt * transport.speed.float32)

      # Camera
      profileBlock "camera":
        let overUi = mouseOverUi(window, sk.mousePos)
        if focusPlayerHero:
          focusPlayerHero = false
          startCameraEase(cameraEase, cameraTarget)
        if window.mousePressed(MouseMiddle) and
            (not overUi or window.buttonPressed[MouseMiddleKey]):
          if not playerMode():
            followSelection = false
            actionCam.takeManual()
          cancelCameraEase(cameraEase)
          lastMouse = window.mousePos
        let wantPan =
          window.mouseDown(MouseMiddle) and
            (not overUi or window.buttonDown[MouseMiddleKey]) or
          (not playerMode() and not overUi and window.mouseDown(MouseRight))
        if wantPan and not panning:
          lastMouse = window.mousePos
        panning = wantPan
        updateMinimapCamera(
          window,
          sk.mousePos,
          cameraTarget,
          minimapPanning,
          followSelection,
          selectedViewLevel()
        )
        if minimapPanning:
          actionCam.takeManual()
          cancelCameraEase(cameraEase)
        if playerMode():
          if panning:
            let delta = window.mousePos - lastMouse
            lastMouse = window.mousePos
            cancelCameraEase(cameraEase)
            let pan = isoPan(
              vec2(delta.x.float32, delta.y.float32), PanPixelScale)
            cameraTarget.x -= pan.x
            cameraTarget.z -= pan.y
            cameraTarget.x = clamp(cameraTarget.x, -HalfGrid, HalfGrid)
            cameraTarget.z = clamp(cameraTarget.z, -HalfGrid, HalfGrid)
          elif not minimapPanning and
              applyRtsPan(
                cameraTarget,
                isoPan(rtsPanDir(window), 1),
                dt,
                cameraDistance,
                HalfGrid
              ):
            cancelCameraEase(cameraEase)
          else:
            discard advanceCameraEase(
              cameraEase,
              cameraTarget,
              playerHeroFrame(),
              dt
            )
        else:
          if panning:
            let delta = window.mousePos - lastMouse
            lastMouse = window.mousePos
            followSelection = false
            actionCam.takeManual()
            let pan = isoPan(
              vec2(delta.x.float32, delta.y.float32), PanPixelScale)
            cameraTarget.x -= pan.x
            cameraTarget.z -= pan.y
            cameraTarget.x = clamp(cameraTarget.x, -HalfGrid, HalfGrid)
            cameraTarget.z = clamp(cameraTarget.z, -HalfGrid, HalfGrid)
          if not minimapPanning and
              applyRtsPan(
                cameraTarget,
                isoPan(rtsPanDir(window), 1),
                dt,
                cameraDistance,
                HalfGrid
              ):
            followSelection = false
            actionCam.takeManual()
          if actionCam.enabled:
            feedCtaActions()
            actionCam.direct(
              cameraTarget, cameraDistance, viewingDt,
              run.world.phase in {EscapedPhase, WipedPhase} or
                transport.tick >= transport.timelineEnd,
              transport.repeating,
              window.size.x.float32 / max(window.size.y.float32, 1),
              # The director's own lift assumes a north-facing perspective
              # camera; the isometric projection lifts every mode instead.
              lift = 0
            )
          else:
            let livingSelection = selectedLivingCount()
            if followSelection and livingSelection == 1:
              let
                cameraHero = selectedLivingHero()
                actor = run.world.actors[cameraHero]
                targetPosition =
                  actorRenderPosition(actor) + vec3(0, 0.85'f32, 0)
              cameraTarget = mix(
                cameraTarget,
                targetPosition,
                damping(5.0'f32, dt)
              )
            elif followSelection and livingSelection > 1:
              let
                groupCenter = selectedCenter()
                groupDistance = clamp(
                  10.0'f32 + selectedRadius(groupCenter) * 2.8'f32,
                  16.0'f32,
                  80.0'f32
                ) * CameraDistanceScale * groupCameraScale
              cameraTarget = mix(
                cameraTarget,
                groupCenter + vec3(0, 0.45'f32, 0),
                damping(4.0'f32, dt)
              )
              cameraDistance = mix(
                cameraDistance,
                groupDistance,
                damping(2.0'f32, dt)
              )
            elif followSelection:
              followSelection = false

      let
        eye = isoEye(cameraTarget)
        view = isoView(cameraTarget)
        projection = isoProjection(
          cameraDistance,
          window.size.x.float32 / max(window.size.y.float32, 1),
          window.hudFreeBand().lift
        )
        viewProjection = projection * view
        cameraForward = normalize(cameraTarget - eye)
        barCameraRight = normalize(cross(cameraForward, vec3(0, 1, 0)))
        barCameraUp = normalize(cross(barCameraRight, cameraForward))

      updateWorldSelection(viewProjection)
      updatePlayerWalk(viewProjection)

      profileBlock "drawWorld":
        # One clock for the whole frame: the palette, the sun's position,
        # and its shadow map all follow the expedition hour. The fractional
        # tick keeps the sun gliding between simulation steps instead of
        # visibly stepping shadow positions once a second.
        scene.setToonHour(
          smoothClockHour(float32(run.world.tick) + renderAlpha))
        setEnvironmentPalette(scene.toon)

        # The cutaway. Levels are baked in order from the surface down, so
        # "this floor and everything under it" is one contiguous vertex range and
        # costs a single draw call with an offset. The sun depth pass draws
        # the same range, so hidden floors above never cast down into view.
        let visibleFrom = selectedViewLevel()

        profileBlock "prepare character poses":
          visuals.setLen(run.world.actors.len)
          let gameDt = dt * transport.speed.float32
          for slot in 0 ..< run.world.actors.len:
            let shown = visuals[slot].visible
            visuals[slot].visible = false
            let actor = run.world.actors[slot]
            if actor.id == 0 or not actor.alive:
              continue
            if int(actor.home.level) < visibleFrom:
              continue
            if actor.kind == MonsterActor and not selectedVisible(actor.home):
              continue
            if active:
              visuals[slot].gait.track(actorGroundSpeed(actor), gameDt)
            let
              position = actorRenderPosition(actor)
              hero = actor.kind == HeroActor
              model =
                if hero: heroModels[actor.heroClass]
                else: monsterModels[actor.species]
              delivery =
                if actor.busy: AbilityLooks[actor.action].delivery
                else: RiteDelivery
              signature = hero and actor.busy and
                actor.action in {BlazingBlade, Taunt} and
                actor.heroClass == FighterClass
              runClip =
                if hero: heroRun[actor.heroClass]
                else: monsterRun[actor.species]
              stride =
                if hero: models.heroStrides[actor.heroClass]
                else: models.monsterStrides[actor.species]
              wantedClip =
                if signature:
                  if actor.action == Taunt: fighterRoar else: fighterSlash
                elif actor.busy and delivery in Spells:
                  if hero: heroSpell[actor.heroClass]
                  else: monsterSpell[actor.species]
                elif actor.busy and delivery != GrabDelivery:
                  if hero: heroAttack[actor.heroClass]
                  else: monsterAttack[actor.species]
                elif actor.moving and not actor.staggered and
                    not actor.rooted and
                    visuals[slot].gait.striding:
                  runClip
                else:
                  if hero: heroIdle[actor.heroClass]
                  else: monsterIdle[actor.species]
            var
              place = position
              angle = actorRenderFacing(actor)
            if actor.busy:
              # The body coils, lunges and sags on top of the clip.
              let motion = actor.action.bodyMotion(
                actor.actionTime(renderAlpha))
              place += heading(angle) * motion.pull + vec3(0, motion.lift, 0)
              angle += motion.twist
            visuals[slot].angle = angle
            if visuals[slot].clip != wantedClip:
              if shown and runClip in [visuals[slot].clip, wantedClip]:
                visuals[slot].startRunFade()
              visuals[slot].clip = wantedClip
              visuals[slot].animTime = 0
            if active:
              let rate =
                if wantedClip == runClip:
                  visuals[slot].gait.runRate(
                    stride, model.clipDuration(runClip))
                else:
                  1'f32
              visuals[slot].animTime += gameDt * rate
            if actor.busy and delivery != GrabDelivery:
              let beats =
                if signature: clipBeats(TauntRoarClip)
                elif delivery in Spells: spellBeats
                elif hero: heroBeats[actor.heroClass]
                else: monsterBeats[actor.species]
              visuals[slot].animTime =
                attackClipTime(actor, wantedClip, model, beats)
            if hero:
              # The arrow leaves the string on release and comes back with
              # the next nock.
              model.mergedMesh =
                if actor.busy and
                    actor.action.loosed(actor.actionTime(renderAlpha)):
                  models.loosedMeshes[actor.heroClass]
                else: 0
            scene.prepareCharacter(
              visuals[slot].pose,
              model,
              place,
              visuals[slot].angle,
              visuals[slot].clip,
              visuals[slot].animTime
            )
            visuals[slot].easeRunFade(if active: gameDt else: 0'f32)
            visuals[slot].visible = true
          for corpse in corpses.mitems:
            corpse.visible = false
            if int(corpse.home.level) < visibleFrom:
              continue
            if corpse.kind == MonsterActor and
                not selectedVisible(corpse.home):
              continue
            let
              hero = corpse.kind == HeroActor
              model =
                if hero: heroModels[HeroClass(corpse.class)]
                else: monsterModels[Species(corpse.class)]
              clip =
                if hero: heroDeath[HeroClass(corpse.class)]
                else: monsterDeath[Species(corpse.class)]
              ticks = float32(run.world.tick - corpse.tick) + renderAlpha
              sinking = clamp(
                (ticks - CorpseLingerTicks.float32) / CorpseSinkTicks.float32,
                0, 1)
              depth = if hero: 0'f32 else: CorpseSinkDepth * sinking
            # Death plays once and holds its last frame.
            scene.prepareCharacter(
              corpse.pose,
              model,
              corpse.position - vec3(0, depth, 0),
              corpse.angle,
              clip,
              min(ticks / TickRate.float32, model.clipDuration(clip))
            )
            corpse.visible = true

        proc drawWorldActors() =
          ## Reuses each actor's pose for shadows, color and outlines.
          for slot, visual in visuals.mpairs:
            if visual.visible:
              scene.drawCharacter(visual.pose,
                if run.world.actors[slot].cloaked: CloakTint
                else: color(1, 1, 1, 1))
          for corpse in corpses.mitems:
            if corpse.visible:
              scene.drawCharacter(corpse.pose)

        if sunShadowsActive() and layerVertexRanges.len > visibleFrom:
          sunDepthPasses(window.size):
            drawTerrainSunDepth(
              layerVertexRanges[visibleFrom].a,
              layerVertexRanges[^1].b - layerVertexRanges[visibleFrom].a + 1
            )
            scene.sunDepthPass = true
            drawWorldActors()
            scene.sunDepthPass = false

        glViewport(0, 0, window.size.x.GLsizei, window.size.y.GLsizei)
        when not defined(emscripten):
          glEnable(GL_MULTISAMPLE)
        glClearColor(0, 0, 0, 1)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

        if layerVertexRanges.len > visibleFrom:
          let
            first = layerVertexRanges[visibleFrom].a
            last = layerVertexRanges[^1].b
          updateTerrainVision(int32(visibleFrom))
          updateCutaways(visibleFrom)
          drawTerrainRange(
            viewProjection,
            first,
            last - first + 1,
            showTiles
          )

        # Bodies drawn after the ground copy cast contact shadows but keep
        # their own colors.
        occlusion.captureGround(window.size)
        beginCharacters(scene, window, view, projection, eye)
        drawWorldActors()
        finishCharacters(scene)
        # Only the opaque world is occluded: gizmos, particles, bars,
        # outlines and the HUD draw after it at full brightness.
        profileBlock "ambient occlusion":
          occlusion.applyScreenOcclusion(window.size, projection)
        abilityShapes.clear()
        addAbilityTells(visibleFrom)
        addWarriorEffects(visibleFrom, barCameraRight, barCameraUp)
        addVines(visibleFrom)
        addDruidEffects(visibleFrom, barCameraRight, barCameraUp)
        abilityShapes.draw(viewProjection)
        # Heals swirl round whoever they mend, wherever it walks.
        particles.followParticleAnchors(
          proc(anchor: int32, position: var Vec3): bool =
            let slot = run.world.actorSlot(anchor)
            if slot < 0 or not run.world.actors[slot].alive:
              return false
            position = actorRenderPosition(run.world.actors[slot])
            true
        )
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward
        )
        clickMarks.drawClickMarks(viewProjection)
        if showPaths:
          worldShapes.clear()
          worldShapes.addActorPaths(run.world, visibleFrom)
          worldShapes.draw(viewProjection)
        drawWorldBars(
          viewProjection,
          barCameraRight,
          barCameraUp,
          visibleFrom,
          dt
        )
        drawSelectedOutline(
          view,
          projection,
          eye,
          visibleFrom
        )

      profileBlock "ui":
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glDisable(GL_BLEND)
        when not defined(emscripten):
          glDisable(GL_MULTISAMPLE)
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
        sk.beginUi(window, window.size)
        drawUi(
          sk,
          window,
          transport,
          cameraTarget,
          cameraDistance,
          primaryId,
          selectedIds,
          followSelection,
          actionCam,
          focusPlayerHero,
          renderAlpha
        )
        sk.endUi()
        drawStatsOverlay(sk, window)
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          8,
          "games/call_to_adventure/shot.png"
        )
      profileBlock "present":
        window.presentFrame(framePaceHz)
        reportDirectorFrame(
          actionCam, transport, cameraDistance, int32(run.hashCheck.mismatches)
        )
        reportReplayFrame(run.world.tick, int32(run.hashCheck.mismatches))
    if noteProfileFrame():
      when not defined(emscripten):
        window.closeRequested = true

  while not window.closeRequested:
    pollEvents()
    waitForDisplay()

  if not run.replayMode:
    saveRecording()
  clickMarks.closeClickMarks()
  worldShapes.closeShapeRenderer()
  abilityShapes.closeShapeRenderer()
  worldBarRenderer.closeWorldBarRenderer()
  selectionOutline.closeSelectionOutline()
  occlusion.closeScreenOcclusion()
  particles.closeParticles()
  finishGameProfile()
  echo "run ended: ", run.world.phase, " with ", run.world.banked, " gold banked"
