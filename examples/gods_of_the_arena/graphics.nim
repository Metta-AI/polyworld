## Window, terrain rendering, characters, camera, and HUD for the arena.

import
  std/[math, tables, times],
  bumpy, chroma, opengl, pixie, silky, vmath,
  assets, brushes, content, landscapes, sim, game, maps, replays, ui, walls,
  controls, spelleffects, humaninput,
  polyworld/actioncam, polyworld/assets, polyworld/characters,
  polyworld/clickmarks,
  polyworld/common, polyworld/pathing,
  polyworld/tapes, polyworld/toon,
  polyworld/particles, polyworld/particleshaders, polyworld/player,
  polyworld/profiles,
  polyworld/quadterrain,
  polyworld/shadows,
  polyworld/terrainsurfaces,
  polyworld/[chrome, rtscameras, selectionoutlines, shapes, viewers,
    visions, worldbars, worldtexts]

from keybinds import
  installBrowserKeys, setControlPreset, loadPlayKeys, capturePlayPress,
  capturePlayRelease, pollBrowserKeys, beginPlayInputFrame,
  MouseControls, WasdControls, MouseKeyControls, controlPreset,
  mousePressed, mouseDown, mouseReleased

when defined(takeScreenshot):
  import std/[os, strutils]

const
  DefaultCameraDistance = 17.0'f / 1.2'f
  AtlasPath = TmpRoot & "/gota.atlas.png"
  MossyStoneSurface = SurfaceNames.len
  CourtyardSurface = MossyStoneSurface + 1
  CryptRockSurface = SurfaceNames.len + FortTextures.len
  CryptRubbleSurface = CryptRockSurface + 1
  CryptFortSurface = CryptRockSurface + 2
  CryptRoadSurface = CryptRockSurface + 3
  CryptSpawnSurface = CryptRockSurface + 4
  # Match crypt-rock-1's mean RGB while preserving the rock texture detail.
  CryptRockTint = vec3(0.993051'f, 0.760436'f, 0.854697'f)

type
  GraphicsError = object of CatchableError

proc renderPoint(position: WorldPoint): Vec3 =
  ## Converts authoritative integer coordinates at the rendering boundary.
  result = vec3(
    position.x.float32 / WorldScale.float32,
    position.y.float32 / WorldScale.float32,
    position.z.float32 / WorldScale.float32
  )
  result.y += groundOffset(result.x, result.z)

proc renderFacing(value: Heading): float32 =
  ## Converts an integer heading to the renderer's angular convention.
  arctan2(value.x.float32, value.z.float32)

proc renderSite(point: PathPoint): Vec3 =
  ## Positions a generated structure on the packed ground beneath its feet.
  result = vec3(
    point.x.float32 / PathUnitsPerTile.float32,
    0,
    point.z.float32 / PathUnitsPerTile.float32
  )
  result.y = groundHeight(result.x, result.z) +
    groundOffset(result.x, result.z)

proc addAbilityIcons(builder: AtlasBuilder) =
  ## Packs every hero ability art file used by the action bar.
  const AbilityDir = DataRoot & "/abilities/"
  var packed: set[Ability]
  for class in HeroClass:
    for slot in HeroAbilitySlot:
      let ability = heroAbility(class, slot)
      if ability in packed:
        continue
      packed.incl ability
      let icon = readImage(
        AbilityDir & ability.abilitySpec.icon & ".png"
      ).resize(128, 128)
      if not builder.addImage(abilityIconKey(ability), icon):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for ability icons"
        )

proc addItemIcons(builder: AtlasBuilder) =
  ## Packs every shop item art file used by the inventory.
  const ItemDir = DataRoot & "/items/"
  for item in Item:
    if item == NoItem:
      continue
    let icon = readImage(
      ItemDir & item.itemSpec.icon & ".png"
    ).resize(128, 128)
    if not builder.addImage(itemIconKey(item), icon):
      raise newException(
        GraphicsError,
        "the UI atlas is too small for item icons"
      )

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs the theme logo into the atlas.
  builder.addThemeLogo(LogoPath)

# Lane footmen and the gods per team: humans for red, undead for blue, so
# the teams read from their models with no tinting. Heroes are outfits of
# the same modular pack Call to Adventure uses. Blue wears the upper tank,
# ranged, mage, support, and fighter looks. Red wears the lower ones.
# Ranger, Crossbowman, and Arcanist drop or swap gear from their numbered
# preset. Everyone else wears the preset as published.
var
  window: Window
  sk: Silky

proc runGraphics*() =
  ## Runs the native or Emscripten graphical spectator.
  startGameProfile()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    for class in HeroClass:
      if not builder.addImage(
          HeroPortraitKeys[class], readImage(HeroPortraitPaths[class])):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for hero portraits"
        )
    addHudIcons(builder)
    addAbilityIcons(builder)
    addItemIcons(builder)
    builder.addDefaultFonts()
    builder.addFont(DefaultFontPath, "HeroVersus", 24.0)
    builder.addFont(DefaultFontPath, "WorldName", 32.0)
    builder.write(AtlasPath)
  profileBlock "window":
    (window, sk) = initGameWindow(
      "Gods of the Arena",
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync,
      msaa = msaa4x
    )
  installBrowserKeys()
  if pendingControlPreset.len > 0:
    case pendingControlPreset
    of "mouse":
      setControlPreset(MouseControls)
    of "wasd":
      setControlPreset(WasdControls)
    of "mousekeys", "mousekey":
      setControlPreset(MouseKeyControls)
    else:
      discard
  if pendingKeysPath.len > 0:
    loadPlayKeys(pendingKeysPath)
  let splash = startSplash(sk, window)
  profileBlock "terrain":
    amplitude = 2.8'f
    seed = ArenaSeed
    treeHeight = 5.8'f / 2
    treeWidth = 0.0'f
    initTerrain(
      GotaTreeStyle, GeneratedTerrain, PaintedRocks, ArenaTextures,
      settings = GotaTerrainAssets
    )
    terrainUnboostedMaterial = CourtyardSurface.float32
    let landscape = buildLandscape(
      layers[GroundLayer],
      run.map.mainRoads,
      run.map.preset.seed,
      CryptRoadSurface,
      CryptRoadSurface
    )
    groundRelief = landscape.relief
    groundMaterialOverrides = landscape.materials
    # Blend road materials at sub-tile resolution without changing pathing.
    setTileMaterial(
      RoadTile.int,
      GrassSurface.float32,
      DirtSurface.float32,
      vec3(1),
      vec3(0.78'f32, 0.74'f32, 0.62'f32),
      1
    )
    for i, kind in ArenaWallKinds:
      let material =
        if i == 0:
          CryptRockSurface.float32
        else:
          GrassSurface.float32
      setTileMaterial(
        kind.int,
        material,
        material,
        vec3(1),
        vec3(0.8'f),
        2
      )
    terrainBlendDepth = 0.65'f
    terrainHeightBlend = 1.0'f
    for side in 0 .. 1:
      let surfaces = [
        [GrassSurface, OliveSurface, CourtyardSurface, CourtyardSurface,
          MossyStoneSurface, DirtSurface, DirtSurface, GravelSurface],
        [CryptRockSurface, CryptRubbleSurface, CryptFortSurface,
          CryptFortSurface, CryptSpawnSurface, CryptRoadSurface,
          CryptRoadSurface, CryptRoadSurface]
      ]
      for i, surface in surfaces[side]:
        setTileMaterial(
          int(ArenaKindBase) + side * int(ArenaKindStride) + i,
          surface.float32,
          (if side == 0: GravelSurface else: CryptRockSurface).float32,
          vec3(1),
          vec3(0.8'f),
          (if i >= 5: 5'i32 else: 2'i32)
        )
    setTileMaterial(
      ArenaRockKind.int,
      CryptRockSurface.float32,
      CryptRockSurface.float32,
      vec3(1),
      vec3(0.8'f),
      2
    )
  let scene = newCharacterScene(window)
  scene.useToonShading()
  var
    # Footmen and gods are the lane grunts of each faction: humans for red,
    # undead for blue, so the teams read from their models alone.
    footmanModels: array[Team, CharacterModel]
    footmanRenderClips: array[Team, array[6, int]]
    heroModels: array[HeroClass, CharacterModel]
    heroRenderClips: array[5, int]
  profileBlock "models":
    for team in Team:
      let model = loadCharacterModel(FootmanModels[ord(team)], 1.15)
      footmanModels[team] = model
      footmanRenderClips[team] = [
        model.clipIndex("Run"),
        model.clipIndex("Idle"),
        model.clipIndex("Death"),
        model.clipIndex("Victory"),
        model.clipIndex("Attack01"),
        model.clipIndex("Attack02")
      ]
    for class in HeroClass:
      heroModels[class] = loadModularCharacterModel(
        HeroModelPath,
        HeroLooks[class],
        HeroTargetHeight
      )
    let heroModel = heroModels[VanguardKnight]
    heroRenderClips = [
      heroModel.clipIndex("Run"),
      heroModel.clipIndex("Idle"),
      heroModel.clipIndex("Death"),
      heroModel.clipIndex("Attack01"),
      heroModel.clipIndex("Attack02")
    ]
  var
    particles = initParticleSystem()
    spellEffects = initSpellRenderer()
    clickMarks = initClickMarks()
    worldShapes = initShapeRenderer()
    selectionOutline = initSelectionOutline()
    occlusionOutline = initSelectionOutline(OccludedOutline)
    showOccludedCharacters = true
    worldBarRenderer = initWorldBarRenderer()
    playerLabels = layoutNames(
      sk.atlas.fonts["WorldName"],
      sk.atlas.size,
      run.config.players
    )
    damageTrails: DamageTrailTracker

  const
    SmallTowerScale = 3.5'f
    TallTowerScale = 4.5'f
    GateTowerScale = 6.0'f
    BarracksScale = 1.65'f

  const
    # The undead asset is authored with a narrower body than the human asset.
    # Keep the normalized height while giving Dire the same readable footprint.
    FootmanSizeIncrease = 1.1'f32
    FootmanSizeFactors: array[Team, float32] = [
      1.0'f32 * FootmanSizeIncrease,
      1.15'f32 * FootmanSizeIncrease
    ]

  proc footmanSizeFactor(team: Team): float32 =
    ## Matches the apparent body size of both lane-creep models.
    FootmanSizeFactors[team]

  proc towerPropName(tier: TowerTier): string =
    ## Returns the matching fort model for one tower tier.
    case tier
    of OuterTower:
      "tower_level1"
    of InnerTower:
      "tower_level2"
    of GateTower:
      "tower_level3"

  proc towerScale(tier: TowerTier): float32 =
    ## Returns the world scale for one tower tier.
    case tier
    of OuterTower:
      SmallTowerScale
    of InnerTower:
      TallTowerScale
    of GateTower:
      GateTowerScale

  proc wallHeight(placement: WallPlacement, width: float32): float32 =
    ## Embeds an upright wall model at the lowest ground under its footprint.
    let
      direction = vec2(cos(placement.rotation), sin(placement.rotation))
      across = vec2(-direction.y, direction.x)
      length =
        if placement.part == WallPanel: placement.length
        else: width
      steps = max(1, ceil(length / 0.25'f).int)
      edge = mapHalfSize() - 0.001'f
    result = float32.high
    for i in 0 .. steps:
      for j in -1 .. 1:
        let point = clamp(
          placement.position +
            direction * (length * (i.float32 / steps.float32 - 0.5'f)) +
            across * (width / 2 * j.float32),
          vec2(-edge),
          vec2(edge)
        )
        result = min(result,
          groundHeight(point.x, point.y) + groundOffset(point.x, point.y))
    result -= 0.05'f

  proc placeStaticStructures(packs: array[Team, PropPack]) =
    ## Places barracks beside gates and joined wall models on natural ground.
    for site in run.map.layout.barracks:
      packs[Team(site.team)].placeProp(
        "barracks",
        renderSite(site.position),
        arctan2(
          (site.facing.x - site.position.x).float32,
          (site.facing.z - site.position.z).float32
        ),
        BarracksScale
      )
    for placement in buildWalls(run.map.layout.walls):
      let
        pack = packs[Team(placement.team)]
        name = if placement.part == WallPillar: "pillar" else: "wall"
        size = pack.propSize(name)
        modelScale =
          if placement.part == WallPillar:
            WallPillarWidth / size.x
          else:
            WallSectionLength / size.x
        stretch =
          if placement.part == WallPanel:
            vec3(placement.length / WallSectionLength, 1, 1)
          else:
            vec3(1)
      pack.placeProp(
        name,
        vec3(
          placement.position.x,
          wallHeight(placement, size.z * modelScale),
          placement.position.y
        ),
        placement.rotation,
        modelScale,
        stretch = stretch
      )
  var
    towerPacks: array[Team, PropPack]
    decorPack: PropPack
  let brush = mixBrush(layers[GroundLayer], run.map.preset.seed)
  profileBlock "props":
    for team in Team:
      towerPacks[team] = loadPropPack(
        fortModelPaths(team.ord),
        textured = true,
        textureSize = FortTextureSize,
        mergeNodes = true
      )
      for name in FortModelNames:
        doAssert towerPacks[team].hasProp(name), "Missing fort model: " & name
    towerPacks.placeStaticStructures()
    decorPack = loadPropPack(
      arenaDecorPaths(), textured = true, textureSize = GotaDecorTextureSize)
    for nodes in ArenaDecorNodes:
      for name in nodes:
        doAssert decorPack.hasProp(name), "missing arena decoration: " & name
    let
      darkTreePack = loadPropPack(
        darkTreePaths(),
        textured = true,
        textureSize = FortTextureSize,
        mergeNodes = true
      )
      boulders = loadPropPack(
        propPaths(PaintedRockPath, GotaBoulderNames),
        only = @GotaBoulderNames,
        textured = true,
        repeatTexture = true,
        textureSize = GotaDecorTextureSize
      )
    treeTileBrightness = brush.trees
    darkTreePack.plantRocks(
      DarkTreeNames,
      ArenaRockKind,
      run.map.preset.seed,
      height = treeHeight,
      sizeRange = vec2(0.85'f, 1.3'f),
      burial = 0.03'f,
      mask = brush.darkTrees
    )
    boulders.plantRocks(
      GotaBoulderNames,
      ArenaRockKind,
      ArenaSeed,
      height = 1.6'f,
      sizeRange = vec2(0.5'f, 1.5'f),
      burial = 0.4'f,
      tint = CryptRockTint,
      mask = brush.darkRocks
    )
    boulders.plantRocks(
      GotaBoulderNames,
      TreeTile,
      ArenaSeed,
      height = 1.6'f,
      sizeRange = vec2(0.5'f, 1.5'f),
      burial = 0.4'f,
      mask = brush.lightRocks
    )
    for camp in run.map.layout.camps:
      let center = renderSite(camp)
      decorPack.placeProp("wood_crate_01a", center, scale = 0.6'f)
      decorPack.placeProp(
        "wood_barrel_01a", center + vec3(0.6'f, 0, 0.4'f), scale = 0.65'f
      )
  profileBlock "bake":
    bakeTerrain(rebuildWalkability = false)
    for i, color in run.map.minimap.mpairs:
      let tile = layers[GroundLayer].tiles[i]
      var tint = terrainTileColor(GroundLayer, i) * 1.25'f
      if layers[WaterLayer].tiles[i].exists:
        tint = vec3(69, 135, 161) / 255'f
      elif treeTileBrightness[i] > 0:
        tint = vec3(55, 83, 40) / 255'f * treeTileBrightness[i]
      elif brush.darkTrees[i]:
        tint = vec3(58, 35, 26) / 255'f
      elif tile.kind == ArenaRockKind:
        tint = terrainTileColor(GroundLayer, i) * 0.88'f
      elif tile.kind == TreeTile:
        # Light-side replacement rocks retain their natural gray color.
        tint = vec3(85, 85, 81) / 255'f
      color = uint32(clamp(tint.x * 255, 0'f, 255'f)) shl 16 or
        uint32(clamp(tint.y * 255, 0'f, 255'f)) shl 8 or
        uint32(clamp(tint.z * 255, 0'f, 255'f))
  drawSplash(sk, window, splash.name)

  type God = object
    team: Team
    position: Vec3
    facing: float32
    animTime: float32

  var gods = [
    God(team: RedTeam, facing: arctan2(1.0'f32, 1.0'f32)),
    God(team: BlueTeam, facing: arctan2(-1.0'f32, -1.0'f32)),
  ]
  for i, god in gods.mpairs:
    let offset =
      if god.team == RedTeam:
        vec3(-3.5, 0, -3.5)
      else:
        vec3(3.5, 0, 3.5)
    god.position = renderPoint(run.world.forts[i].center) + offset
    god.position.y = surfaceHeightNear(
      god.position.x,
      god.position.z,
      renderPoint(run.world.forts[i].center).y
    )

  proc godClip(god: God): int =
    ## Selects the god animation for the current game state.
    if not run.world.gameOver:
      idleClip
    elif god.team == run.world.winner:
      victoryClip
    else:
      deathClip

  proc heroSizeFactor(hero: Hero): float32 =
    ## Returns the small visual scale increase earned through hero levels.
    1.0'f32 + min(hero.level - 1, 10).float32 * 0.025'f32

  const
    SeekCheckpointTicks = TickRate * 10
    HeroWorldBarScale = 0.75'f
    HeroWorldBarWidth = 1.75'f * HeroWorldBarScale
    TowerWorldBarWidth = 2.4'f32
    FootmanWorldBarWidth = 0.95'f32

  type
    SeekCheckpoint = object
      tick: int
      world: World
      replayActionIndex: int
      hashCheck: ReplayHashCheck

    SelectionTarget = object
      found: bool
      position: Vec3
      focusHeight: float32

  var
    replayCheckpoints: seq[SeekCheckpoint]
    previousUnitPositions: Table[int32, Vec3]
    previousUnitFacings: Table[int32, float32]
    renderAlpha = 1.0'f32
    animationAlpha = 0.0'f32
    viewMode =
      if options.playerSlot > 0:
        int32(run.world.heroes[options.playerSlot - 1].team.ord) + 1
      else:
        0'i32
    terrainVisionTick = int32.low
    terrainVisionMode = int32.low

  proc captureUnitPositions() =
    ## Remembers all mobile poses before one authoritative tick.
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    for hero in run.world.heroes:
      previousUnitPositions[hero.id] = renderPoint(hero.position)
      previousUnitFacings[hero.id] = renderFacing(hero.facing)
    for footman in run.world.footmen:
      previousUnitPositions[footman.id] = renderPoint(footman.position)
      previousUnitFacings[footman.id] = renderFacing(footman.facing)

  proc unitRenderPoint(id: int32, position: WorldPoint): Vec3 =
    ## Interpolates one mobile unit between the latest simulation snapshots.
    let current = renderPoint(position)
    if not interpolateVisuals:
      return current
    mix(
      previousUnitPositions.getOrDefault(id, current),
      current,
      renderAlpha
    )

  proc unitRenderFacing(id: int32, facing: Heading): float32 =
    ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
    if not interpolateVisuals:
      return renderFacing(facing)
    let
      current = renderFacing(facing)
      previous = previousUnitFacings.getOrDefault(id, current)
    previous + shortestTurn(previous, current) * renderAlpha

  proc unitRenderTime(ticks: int32): float32 =
    ## Samples authoritative animation state continuously between ticks.
    (ticks.float32 + animationAlpha) / TickRate.float32

  proc holdClipTime(
      model: CharacterModel, clip: int, ticks: int32, hold: bool
  ): float32 =
    ## Samples animation time. One-shot clips hold the last pose; the
    ## sampler wraps with `mod`, so a death would otherwise loop. Held
    ## poses ignore the interpolant, or a corpse wiggles between ticks.
    if hold:
      min(
        ticks.float32 / TickRate.float32,
        clipDuration(model, clip)
      )
    else:
      unitRenderTime(ticks)

  proc visibleInView(team: Team, position: WorldPoint): bool =
    ## Applies the current omniscient or team visibility spectator mode.
    if viewMode == 0:
      return true
    let viewingTeam = Team(viewMode - 1)
    team == viewingTeam or visible(run.world, viewingTeam, position)

  proc updateTerrainVision() =
    ## Uploads softened terrain vision for the selected spectator team.
    if terrainVisionTick == run.world.tick and terrainVisionMode == viewMode:
      return
    terrainVisionTick = run.world.tick
    terrainVisionMode = viewMode
    var values = newSeq[uint8](mapTiles() * mapTiles())
    if viewMode == 0:
      for value in values.mitems:
        value = 255
    else:
      let team = int(viewMode - 1)
      for i in 0 ..< values.len:
        values[i] =
          if run.world.teamVisible[team][i] != 0: 255
          elif run.world.teamExplored[team][i] != 0: 48
          else: 0
    uploadTerrainVisibility(
      blurVisibility(values, mapTiles().int32, mapTiles().int32), mapTiles()
    )

  proc screenPosition(position: Vec3, viewProjection: Mat4): Vec2 =
    ## Projects a world position into window pixel coordinates.
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

  proc addPlayerNames() =
    ## Labels living visible heroes using their bot execution slot.
    for slot, hero in run.world.heroes:
      if slot >= run.config.players.len or hero.state == Dying or hero.hp <= 0 or
        not visibleInView(hero.team, hero.position):
          continue
      let anchor = unitRenderPoint(hero.id, hero.position) + vec3(0, 2.4'f, 0)
      worldBarRenderer.addText(
        playerLabels[slot],
        anchor
      )

  proc drawWorldUnitBars(
      renderer: var WorldBarRenderer,
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      dt: float32
  ) =
    ## Builds and draws attached hero, tower, and footman resource bars.
    damageTrails.beginFrame()
    renderer.clear()
    for hero in run.world.heroes:
      if hero.state == Dying or hero.hp <= 0 or
          not visibleInView(hero.team, hero.position):
        continue
      let
        health = max(hero.hp, 0'i32).float32
        maximumHealth = max(hero.maxHp, 1'i32).float32
        delayedHealth = damageTrails.delayedValue(
          hero.id,
          health,
          maximumHealth,
          dt
        )
        anchor = unitRenderPoint(hero.id, hero.position) +
          vec3(0, 2.2'f32, 0)
        bars = [
          WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.16'f * HeroWorldBarScale,
            color: teamHudColor(hero.team),
            showDamageTrail: true
          ),
          WorldResourceBar(
            value: max(hero.mana, 0'i32).float32,
            maximum: max(hero.maxMana, 1'i32).float32,
            delayedValue: max(hero.mana, 0'i32).float32,
            height: 0.1'f * HeroWorldBarScale,
            color: ManaColor
          )
        ]
      renderer.addResourceBars(
        anchor,
        HeroWorldBarWidth,
        bars,
        gap = DefaultGap * HeroWorldBarScale,
        border = DefaultBorder * HeroWorldBarScale
      )
    for tower in run.world.towers:
      if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
        continue
      let
        health = tower.hp.float32
        maximumHealth = tower.maxHp.float32
        delayedHealth = damageTrails.delayedValue(
          tower.id,
          health,
          maximumHealth,
          dt
        )
        anchor = renderPoint(tower.position) +
          vec3(0, towerScale(tower.tier) + 0.45'f32, 0)
        bars = [WorldResourceBar(
          value: health,
          maximum: maximumHealth,
          delayedValue: delayedHealth,
          height: 0.14'f32,
          color: teamHudColor(tower.team),
          showDamageTrail: true
        )]
      renderer.addResourceBars(anchor, TowerWorldBarWidth, bars)
    for footman in run.world.footmen:
      if footman.state == Dying or footman.hp <= 0 or
          not visibleInView(footman.team, footman.position):
        continue
      let
        health = footman.hp.float32
        maximumHealth = FootmanHp.float32
        delayedHealth = damageTrails.delayedValue(
          footman.id,
          health,
          maximumHealth,
          dt
        )
      if footman.hp < FootmanHp:
        let
          anchor = unitRenderPoint(footman.id, footman.position) +
            vec3(0, 1.38'f32, 0)
          bars = [WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.1'f32,
            color: teamHudColor(footman.team),
            showDamageTrail: true
          )]
        renderer.addResourceBars(anchor, FootmanWorldBarWidth, bars)
    damageTrails.finishFrame()
    addPlayerNames()
    renderer.draw(
      viewProjection,
      cameraRight,
      cameraUp,
      sk.atlasTextureId()
    )

  proc pickEntity(viewProjection: Mat4): int32 =
    ## Finds the closest visible mesh under the pointer by triangle hit.
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
    var bestDistance = -1.0'f32
    template consider(candidateId: int32, distance: float32) =
      if distance > 0 and (bestDistance < 0 or distance < bestDistance):
        bestDistance = distance
        result = candidateId
    for hero in run.world.heroes:
      if hero.state == Dying or not visibleInView(hero.team, hero.position):
        continue
      let
        model = heroModels[hero.class]
        clip = heroRenderClips[hero.animClip]
      consider(
        hero.id,
        pickCharacter(
          model,
          origin,
          dir,
          unitRenderPoint(hero.id, hero.position),
          unitRenderFacing(hero.id, hero.facing),
          clip,
          holdClipTime(
            model, clip, hero.animTicks, hero.state == Dying
          ),
          hero.heroSizeFactor()
        )
      )
    for footman in run.world.footmen:
      if footman.state == Dying or
          not visibleInView(footman.team, footman.position):
        continue
      let
        model = footmanModels[footman.team]
        clip = footmanRenderClips[footman.team][footman.animClip]
      consider(
        footman.id,
        pickCharacter(
          model,
          origin,
          dir,
          unitRenderPoint(footman.id, footman.position),
          unitRenderFacing(footman.id, footman.facing),
          clip,
          holdClipTime(
            model, clip, footman.animTicks, footman.state == Dying
          ),
          footmanSizeFactor(footman.team)
        )
      )
    for tower in run.world.towers:
      if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
        continue
      consider(
        tower.id,
        pickProp(
          towerPacks[tower.team],
          towerPropName(tower.tier),
          origin,
          dir,
          renderPoint(tower.position),
          renderFacing(tower.facing),
          towerScale(tower.tier)
        )
      )
    for i, god in gods:
      if not visibleInView(god.team, run.world.forts[i].center):
        continue
      let
        model = footmanModels[god.team]
        clip = footmanRenderClips[god.team][god.godClip]
      var animTime = god.animTime
      if run.world.gameOver and god.team != run.world.winner:
        animTime = min(animTime, clipDuration(model, clip))
      consider(
        run.world.forts[i].id,
        pickCharacter(
          model,
          origin,
          dir,
          god.position,
          god.facing,
          clip,
          animTime,
          2.6
        )
      )

  proc captureCheckpoint(): SeekCheckpoint =
    ## Captures simulation state for an exact seek restore.
    SeekCheckpoint(
      tick: int(run.world.tick),
      world: run.world.clone(),
      replayActionIndex:
        if run.replayPlayer != nil: run.replayPlayer.actionIndex else: 0,
      hashCheck: run.hashCheck
    )

  var
    cameraDistance = DefaultCameraDistance
    cameraTarget = vec3(0, 0, 0)
    panning = false
    minimapPanning = false
    cameraEye = vec3(0, 0, 0)
    primaryId = 0'i32
    selectedIds: seq[int32]
    selectionPressPosition = vec2(0)
    rightPressPosition = vec2(0)
    rightOrderStarted = false
    selectionStarted = false
    selectionAdditive = false
    humanInput: HumanInputState
    followSelection = false
    cameraEase: CameraEase
    focusPlayerHero = false
    groupCameraScale = 1.0'f32
    viewingDt = 0.0'f
    viewingSeeking = false
    actionCam = initActionCam(
      subjectMode = true,
      defaultDistance = DefaultCameraDistance,
      minDistance = 22,
      maxDistance = 150,
      tight = 0.72,
      followRate = 1.0,
      zoomRate = 0.7,
      holdSeconds = 2.8,
      mapSpan = mapHalfSize() * 2
    )
    transport = initPlayer(
      live = not run.replayMode,
      durationTicks =
        if run.replayMode:
          int32(run.replayData.hashes.len)
        else:
          options.maximumTicks,
      playing = not options.pauseOnStart,
      speed = options.speed,
      repeating = true
    )

  window.onButtonPress = proc(button: Button) =
    if not capturePlayPress(button):
      return
    if setupOpen:
      if button == KeyReturn:
        restartHumanGame(menuSlot)
      return
    if options.playerSlot > 0 and not run.replayMode:
      if button == KeyB:
        shopOpen = not shopOpen
        cancelPlayerAim()
        return
      if button == KeyEscape:
        shopOpen = false
        cancelPlayerAim()
        return
      if shopOpen and button != KeySpace:
        return
    if handleChromeKey(button):
      return
    if button == KeySpace:
      transport.handleKey(button)
    elif button == KeyC:
      actionCam.toggle(followSelection)
    elif button == KeyT:
      scene.toggleShading()
    elif button == KeyO:
      showOccludedCharacters = not showOccludedCharacters

  window.onButtonRelease = proc(button: Button) =
    capturePlayRelease(button)

  proc objectTeam(id: int32): int32 =
    ## Returns 1 for red, 2 for blue, or 0 when the id is unknown.
    let hero = heroById(run.world, id)
    if hero.id != 0:
      return int32(hero.team.ord + 1)
    let footman = footmanById(run.world, id)
    if footman.id != 0:
      return int32(footman.team.ord + 1)
    for tower in run.world.towers:
      if tower.id == id:
        return int32(tower.team.ord + 1)
    for fort in run.world.forts:
      if fort.id == id:
        return int32(fort.team.ord + 1)
    0

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one hero.
    options.playerSlot > 0 and not run.replayMode

  proc playerHeroId(): int32 =
    ## Returns the human hero identifier.
    run.world.heroes[options.playerSlot - 1].id

  if playerMode():
    actionCam.takeManual()
    primaryId = playerHeroId()
    selectedIds.add primaryId
    followSelection = false

  proc syncViewMode() =
    ## Shows one team's fog when the selection is one-sided.
    if playerMode():
      viewMode =
        int32(run.world.heroes[options.playerSlot - 1].team.ord) + 1
      return
    var mode = 0'i32
    for id in selectedIds:
      let team = objectTeam(id)
      if team == 0:
        continue
      if mode == 0:
        mode = team
      elif mode != team:
        viewMode = 0
        return
    viewMode = mode

  proc isSelected(id: int32): bool =
    ## Returns whether an object belongs to the current selection set.
    for selectedId in selectedIds:
      if selectedId == id:
        return true

  proc selectionTarget(id: int32): SelectionTarget =
    ## Returns current rendering and camera data for one selectable object.
    let hero = heroById(run.world, id)
    if hero.id != 0 and visibleInView(hero.team, hero.position):
      return SelectionTarget(
        found: true,
        position: unitRenderPoint(hero.id, hero.position),
        focusHeight: 0.9'f32
      )
    let footman = footmanById(run.world, id)
    if footman.id != 0 and visibleInView(footman.team, footman.position):
      return SelectionTarget(
        found: true,
        position: unitRenderPoint(footman.id, footman.position),
        focusHeight: 0.6'f32
      )
    for tower in run.world.towers:
      if tower.id == id and tower.hp > 0 and
          visibleInView(tower.team, tower.position):
        return SelectionTarget(
          found: true,
          position: renderPoint(tower.position),
          focusHeight: 2.5'f32
        )
    for i, god in gods:
      if run.world.forts[i].id == id and
          visibleInView(god.team, run.world.forts[i].center):
        return SelectionTarget(
          found: true,
          position: god.position,
          focusHeight: 1.3'f32
        )

  proc selectedTargetCount(): int =
    ## Returns the number of selected objects still present in the run.world.
    for id in selectedIds:
      if selectionTarget(id).found:
        inc result

  proc selectEntity(id: int32, additive = false) =
    ## Selects or toggles one object and activates selection following.
    if not selectionTarget(id).found:
      return
    if not additive:
      selectedIds.setLen(0)
    elif isSelected(id) and selectedIds.len > 1:
      for i in 0 ..< selectedIds.len:
        if selectedIds[i] == id:
          selectedIds.delete(i)
          break
      if primaryId == id:
        primaryId = selectedIds[0]
      followSelection = selectedTargetCount() > 0
      actionCam.takeManual()
      return
    if not isSelected(id):
      selectedIds.add id
    primaryId = id
    followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc selectAllHeroes() =
    ## Selects every hero and activates the group-follow camera.
    selectedIds.setLen(0)
    for hero in run.world.heroes:
      selectedIds.add hero.id
    if selectedIds.len > 0:
      if not isSelected(primaryId):
        primaryId = selectedIds[0]
      followSelection = true
      actionCam.takeManual()
      groupCameraScale = 1.0'f32

  proc pruneSelection() =
    ## Removes objects which no longer exist without changing valid choices.
    var i = selectedIds.high
    while i >= 0:
      if not selectionTarget(selectedIds[i]).found:
        selectedIds.delete(i)
      dec i
    if selectedIds.len == 0:
      followSelection = false
      primaryId = 0
    if selectedIds.len > 0 and not isSelected(primaryId):
      primaryId = selectedIds[0]

  proc clearSelection() =
    ## Clears the selection and leaves the camera free-floating.
    selectedIds.setLen(0)
    primaryId = 0
    followSelection = false
    actionCam.takeManual()

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all currently selected world objects.
    var count = 0
    for id in selectedIds:
      let target = selectionTarget(id)
      if target.found:
        result += target.position + vec3(0, target.focusHeight, 0)
        inc count
    if count > 0:
      result = result / count.float32

  proc selectedRadius(center: Vec3): float32 =
    ## Returns the largest planar distance from the selection midpoint.
    for id in selectedIds:
      let target = selectionTarget(id)
      if not target.found:
        continue
      let
        dx = target.position.x - center.x
        dz = target.position.z - center.z
      result = max(result, sqrt(dx * dx + dz * dz))

  proc drawOutlinedObject(
      id: int32,
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws one object's silhouette into the current outline mask.
    for hero in run.world.heroes:
      if hero.id != id:
        continue
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        heroModels[hero.class],
        unitRenderPoint(hero.id, hero.position),
        unitRenderFacing(hero.id, hero.facing),
        heroRenderClips[hero.animClip],
        holdClipTime(
          heroModels[hero.class],
          heroRenderClips[hero.animClip],
          hero.animTicks,
          hero.state == Dying
        ),
        sizeFactor = hero.heroSizeFactor()
      )
      finishCharacters(scene)
      return
    for footman in run.world.footmen:
      if footman.id != id:
        continue
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        footmanModels[footman.team],
        unitRenderPoint(footman.id, footman.position),
        unitRenderFacing(footman.id, footman.facing),
        footmanRenderClips[footman.team][footman.animClip],
        holdClipTime(
          footmanModels[footman.team],
          footmanRenderClips[footman.team][footman.animClip],
          footman.animTicks,
          footman.state == Dying
        ),
        sizeFactor = footmanSizeFactor(footman.team)
      )
      finishCharacters(scene)
      return
    for i, god in gods:
      if run.world.forts[i].id != id:
        continue
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        footmanModels[god.team],
        god.position,
        god.facing,
        footmanRenderClips[god.team][god.godClip],
        god.animTime,
        sizeFactor = 2.6
      )
      finishCharacters(scene)
      return
    for tower in run.world.towers:
      if tower.hp <= 0 or tower.id != id:
        continue
      towerPacks[tower.team].drawProp(
        towerPropName(tower.tier),
        renderPoint(tower.position),
        renderFacing(tower.facing),
        towerScale(tower.tier),
        viewProjection
      )
      return

  proc drawIdOutlines(
      ids: openArray[int32],
      color: Vec3,
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Composites one outline color around every id that still exists.
    var any = false
    for id in ids:
      if selectionTarget(id).found:
        any = true
        break
    if not any:
      return
    selectionOutline.beginMask(window.size)
    for id in ids:
      if selectionTarget(id).found:
        drawOutlinedObject(id, view, projection, viewProjection)
    selectionOutline.drawOutline(color)

  proc drawSelectedOutline(
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws the yellow selection outline and the red attack-target outline.
    if selectedIds.len > 0:
      drawIdOutlines(
        selectedIds,
        SelectionOutlineColor,
        view,
        projection,
        viewProjection
      )
    if playerMode():
      let targetId = heroById(run.world, playerHeroId()).attackObjectId
      if targetId != 0:
        drawIdOutlines(
          [targetId],
          AttackOutlineColor,
          view,
          projection,
          viewProjection
        )

  proc feedGotaActions(observeTick = false) =
    ## Refreshes real subjects and observes every simulated tick.
    if not actionCam.enabled:
      return
    var subjects: seq[Subject]
    for hero in run.world.heroes:
      subjects.add Subject(
        id: hero.id, owner: int32(hero.slot),
        position: unitRenderPoint(hero.id, hero.position),
        height: 0.9, radius: 1.2, visible: visibleInView(hero.team, hero.position),
        alive: hero.hp > 0 and hero.state != Dying,
        hp: hero.hp, maxHp: hero.maxHp, complete: true,
        participant: max(hero.targetHeroId, hero.targetTowerId),
        fighting: hero.state == Fighting, activity: hero.swingTicks,
        idleScore: (if hero.hasMoveTarget: 22.0'f else: 12.0'f),
        combatScore: 100
      )
    for footman in run.world.footmen:
      subjects.add Subject(
        id: footman.id, owner: int32(footman.team),
        position: unitRenderPoint(footman.id, footman.position),
        height: 0.8, radius: 1, visible: visibleInView(footman.team, footman.position),
        alive: footman.hp > 0 and footman.state != Dying,
        hp: footman.hp, maxHp: FootmanHp, complete: true,
        participant: max(footman.targetHeroId, footman.targetTowerId),
        fighting: footman.state == Fighting, activity: footman.swingTicks,
        idleScore: (if footman.state == Marching: 22.0'f else: 8.0'f),
        combatScore: 70
      )
    for tower in run.world.towers:
      subjects.add Subject(
        id: tower.id, owner: int32(tower.team),
        position: renderPoint(tower.position), height: 2.5, radius: 3,
        visible: visibleInView(tower.team, tower.position), alive: tower.hp > 0,
        hp: tower.hp, maxHp: tower.maxHp, complete: true,
        participant: tower.targetId, fighting: tower.targetId != 0,
        activity: tower.attackTicks, idleScore: 4, combatScore: 110
      )
    for i, fort in run.world.forts:
      subjects.add Subject(
        id: fort.id, owner: int32(fort.team), position: gods[i].position,
        height: 2.5, radius: 4, visible: visibleInView(fort.team, fort.center),
        alive: fort.hp > 0, hp: fort.hp, maxHp: FortHp, complete: true,
        damageOnly: true, combatScore: 165
      )
    # Approaching opponents deserve a shot anchored on an advancing hero.
    for subject in subjects.mitems:
      let other = heroById(run.world, subject.id)
      if other == nil or other.id == 0 or not subject.alive:
        continue
      for hero in run.world.heroes:
        if hero.id == subject.id or hero.hp <= 0:
          continue
        if other.team != hero.team and
            (renderPoint(hero.position) - subject.position).length < 14:
          subject.idleScore = 28
    if observeTick and not viewingSeeking:
      actionCam.director.observe(subjects)
    actionCam.director.refresh(subjects)

  proc playerHeroFrame(): Vec3 =
    ## Returns the look-at that frames the human hero over the HUD.
    let hero = heroById(run.world, playerHeroId())
    if hero.id == 0:
      return cameraTarget
    rtsFollowFrame(
      unitRenderPoint(hero.id, hero.position) + vec3(0, 0.9'f32, 0),
      cameraDistance,
      RtsGotaFollowLift
    )

  if playerMode():
    cameraTarget = playerHeroFrame()

  proc updateCamera(dt: float32) =
    ## Applies fixed-north RTS pan, zoom, and selection following.
    pruneSelection()
    syncViewMode()
    if shopOpen:
      selectionStarted = false
      rightOrderStarted = false
      minimapPanning = false
      return
    if focusPlayerHero:
      focusPlayerHero = false
      startCameraEase(cameraEase, cameraTarget)
    updateMinimapCamera(
      window,
      sk.mousePos,
      cameraTarget,
      minimapPanning,
      followSelection
    )
    if minimapPanning:
      actionCam.takeManual()
      cancelCameraEase(cameraEase)
    let overUi = mouseOverUi(window, sk.mousePos, primaryId)
    if window.buttonPressed[KeyA] and
        (window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]):
      selectAllHeroes()
    elif window.mousePressed(MouseLeft) and not overUi:
      selectionPressPosition = window.mousePos.vec2
      selectionStarted = true
      selectionAdditive =
        window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
    if window.mousePressed(MouseRight) and not overUi:
      rightPressPosition = window.mousePos.vec2
      rightOrderStarted = true
    if window.mousePressed(MouseMiddle) and
        (not overUi or controlPreset == MouseKeyControls):
      if not playerMode():
        followSelection = false
        actionCam.takeManual()
      cancelCameraEase(cameraEase)
    panning =
      window.mouseDown(MouseMiddle) and
        (not overUi or controlPreset == MouseKeyControls) or
      (not playerMode() and not overUi and window.mouseDown(MouseRight))

    let delta = window.mouseDelta.vec2
    if playerMode():
      if not overUi and window.scrollDelta.y != 0:
        cancelCameraEase(cameraEase)
        cameraDistance = clamp(
          cameraDistance * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          5.0'f32,
          400.0'f32
        )
      if panning:
        cancelCameraEase(cameraEase)
        let panSpeed = cameraDistance * 0.0015
        cameraTarget.x -= delta.x * panSpeed
        cameraTarget.z -= delta.y * panSpeed
        cameraTarget.x = clamp(cameraTarget.x, -mapHalfSize(), mapHalfSize())
        cameraTarget.z = clamp(cameraTarget.z, -mapHalfSize(), mapHalfSize())
      elif applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          mapHalfSize()
        ):
        cancelCameraEase(cameraEase)
      else:
        discard advanceCameraEase(
          cameraEase,
          cameraTarget,
          playerHeroFrame(),
          dt
        )
      return
    if panning:
      followSelection = false
      actionCam.takeManual()
      let
        panSpeed = cameraDistance * 0.0015
      cameraTarget.x -= delta.x * panSpeed
      cameraTarget.z -= delta.y * panSpeed
      cameraTarget.x = clamp(cameraTarget.x, -mapHalfSize(), mapHalfSize())
      cameraTarget.z = clamp(cameraTarget.z, -mapHalfSize(), mapHalfSize())
    if not minimapPanning and
        applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          mapHalfSize()
        ):
      followSelection = false
      actionCam.takeManual()
    if not overUi and window.scrollDelta.y != 0:
      actionCam.takeManual()
      if followSelection and selectedTargetCount() > 1:
        groupCameraScale = clamp(
          groupCameraScale * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          0.75'f32,
          3.0'f32
        )
      else:
        cameraDistance = clamp(
          cameraDistance * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          5.0'f32,
          400.0'f32
        )

    if actionCam.enabled:
      return
    let targetCount = selectedTargetCount()
    if followSelection and targetCount == 1:
      let target = selectionTarget(selectedIds[0])
      cameraTarget = mix(
        cameraTarget,
        target.position + vec3(0, target.focusHeight, 0),
        damping(5.0'f32, dt)
      )
    elif followSelection and targetCount > 1:
      let
        groupCenter = selectedCenter()
        groupDistance = clamp(
          12.0'f32 + selectedRadius(groupCenter) * 2.8'f32,
          20.0'f32,
          400.0'f32
        ) * groupCameraScale
      cameraTarget = mix(
        cameraTarget,
        groupCenter,
        damping(4.0'f32, dt)
      )
      cameraDistance = mix(
        cameraDistance,
        groupDistance,
        damping(2.0'f32, dt)
      )
    elif followSelection:
      followSelection = false

  proc issueGroundOrder(viewProjection: Mat4, attackMove: bool) =
    ## Walks or attack-moves the human hero onto the tile under the pointer.
    let heroId = playerHeroId()
    let hero = heroById(run.world, heroId)
    if hero.id == 0 or hero.state == Dying:
      return
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
      walk = pickWalkableTile(origin, dir)
    if not walk.hit:
      return
    let
      mapX = int32(layers[walk.layer].originX + walk.x - mapOrigin())
      mapY = int32(layers[walk.layer].originZ + walk.z - mapOrigin())
    if attackMove:
      queueAttackMove(heroId, mapX, mapY)
    else:
      queueWalkTo(heroId, mapX, mapY)
    selectEntity(heroId)
    clickMarks.emitClickMark(tileCenter(walk.layer, walk.x, walk.z))

  proc playerAimAt(viewProjection: Mat4): PlayerAim =
    ## Reads the walkable tile and object under the pointer.
    if mouseOverUi(window, sk.mousePos, primaryId):
      return
    result.pickedId = pickEntity(viewProjection)
    let
      (origin, direction) = mouseRay(
        window.mousePos.vec2, window.size.vec2, viewProjection
      )
      ground = pickWalkableTile(origin, direction)
    if ground.hit:
      result.onMap = true
      result.x = int32(layers[ground.layer].originX + ground.x - mapOrigin())
      result.y = int32(layers[ground.layer].originZ + ground.z - mapOrigin())

  proc updatePlayerSpells(viewProjection: Mat4) =
    ## Applies this frame's human keys through the shared input handler.
    if not playerMode() or shopOpen or setupOpen:
      return
    let aim = playerAimAt(viewProjection)
    let accepts = transport.playing and not historyOpen and
      not run.world.gameOver and run.world.tick < options.maximumTicks
    if not accepts:
      resetPlayerCommands()
    humanInput.handlePlayerKeys(
      window, run.world, playerHeroId(), primaryId, aim, accepts
    )

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Selects a clicked world unit, or attacks it in player mode.
    if not window.mouseReleased(MouseLeft):
      return
    if selectionStarted and
        (window.mousePos.vec2 - selectionPressPosition).length <=
          6.0'f32 and
        not mouseOverUi(window, sk.mousePos, primaryId):
      let picked = pickEntity(viewProjection)
      if playerMode() and armedAbility >= 0:
        let aim = playerAimAt(viewProjection)
        discard confirmPlayerAbility(
          run.world, playerHeroId(), armedAbility, picked, aim.x, aim.y
        )
      elif playerMode() and attackMoveArmed:
        let heroId = playerHeroId()
        if picked != 0 and objectTeam(picked) != objectTeam(heroId):
          queueAttackTarget(heroId, picked)
        else:
          issueGroundOrder(viewProjection, true)
        attackMoveArmed = false
      elif picked != 0:
        selectEntity(picked, selectionAdditive)
        if playerMode() and objectTeam(picked) != objectTeam(playerHeroId()):
          queueAttackTarget(playerHeroId(), picked)
      elif not selectionAdditive:
        clearSelection()
    selectionStarted = false

  proc updatePlayerOrder(viewProjection: Mat4) =
    ## Turns a right-click into a walk or chase, or cancels an armed action.
    if not playerMode():
      return
    if not window.mouseReleased(MouseRight):
      return
    if not rightOrderStarted:
      return
    rightOrderStarted = false
    if mouseOverUi(window, sk.mousePos, primaryId):
      return
    if (window.mousePos.vec2 - rightPressPosition).length > 6.0'f32:
      return
    if armedAbility >= 0 or attackMoveArmed:
      cancelPlayerAim()
      return
    let
      heroId = playerHeroId()
      picked = pickEntity(viewProjection)
    if picked != 0 and objectTeam(picked) != objectTeam(heroId):
      queueAttackTarget(heroId, picked)
      return
    issueGroundOrder(viewProjection, false)

  proc cameraView(): Mat4 =
    ## Updates the camera eye and returns its view matrix.
    cameraEye = rtsCameraEye(cameraTarget, cameraDistance)
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  ## Frame

  const SimulationStep = 1.0'f32 / TickRate.float32

  var lastFrameTime = epochTime()

  proc particleTargetPosition(id: int32): tuple[
      found: bool,
      position: Vec3
  ] =
    ## Returns the presentation-space center of one combat target.
    let hero = heroById(run.world, id)
    if hero.id != 0:
      return (
        true,
        renderPoint(hero.position) + vec3(0, 0.85'f32, 0)
      )
    let footman = footmanById(run.world, id)
    if footman.id != 0:
      return (
        true,
        renderPoint(footman.position) + vec3(0, 0.65'f32, 0)
      )
    let tower = towerById(run.world, id)
    if tower.id != 0:
      return (
        true,
        renderPoint(tower.position) +
          vec3(0, towerScale(tower.tier) * 0.55'f32, 0)
      )
    for i, fort in run.world.forts:
      if fort.id == id:
        return (true, gods[i].position + vec3(0, 1.0'f32, 0))

  proc emitAttackParticles(
      style: HeroAttackStyle,
      origin,
      target: Vec3
  ) =
    ## Converts one landed hero attack into its presentation effect.
    case style
    of MeleeAttack:
      particles.emitParticleBurst(CombatSparks, target)
    of RangedAttack:
      particles.emitParticleProjectile(
        ArrowWake,
        CombatSparks,
        origin,
        target,
        clamp(
          (target - origin).length / 18.0'f32,
          0.08'f32,
          0.38'f32
        )
      )
    of MagicAttack:
      particles.emitParticleProjectile(
        MagicBolt,
        MagicBurst,
        origin,
        target,
        clamp(
          (target - origin).length / 13.0'f32,
          0.12'f32,
          0.48'f32
        )
      )

  proc emitTickParticles(
      oldHeroLanded: seq[bool],
      oldFootmanLanded: Table[int32, bool],
      oldTowerTicks: seq[int32]
  ) =
    ## Emits each authoritative attack transition exactly once.
    for i, hero in run.world.heroes:
      if i >= oldHeroLanded.len or oldHeroLanded[i] or
          not hero.damageLanded:
        continue
      let target = particleTargetPosition(hero.attackObjectId)
      if not target.found:
        continue
      let origin = renderPoint(hero.position) + vec3(0, 0.9'f32, 0)
      emitAttackParticles(
        hero.class.heroSpec.attackStyle,
        origin,
        target.position
      )
    for footman in run.world.footmen:
      if oldFootmanLanded.getOrDefault(footman.id, false) or
          not footman.damageLanded:
        continue
      let targetId =
        if footman.targetId != 0:
          footman.targetId
        elif footman.targetHeroId != 0:
          footman.targetHeroId
        elif footman.targetTowerId != 0:
          footman.targetTowerId
        elif footman.team == RedTeam:
          run.world.forts[1].id
        else:
          run.world.forts[0].id
      let target = particleTargetPosition(targetId)
      if target.found:
        particles.emitParticleBurst(
          CombatSparks,
          target.position
        )
    for i, tower in run.world.towers:
      if i >= oldTowerTicks.len or tower.targetId == 0 or
          oldTowerTicks[i] != TowerAttackTicks - 1 or
          tower.attackTicks != 0:
        continue
      let target = particleTargetPosition(tower.targetId)
      if not target.found:
        continue
      let origin = renderPoint(tower.position) +
        vec3(0, towerScale(tower.tier) * 0.72'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target.position,
        clamp(
          (target.position - origin).length / 14.0'f32,
          0.14'f32,
          0.5'f32
        )
      )

  proc advanceRenderedSimulation() =
    ## Advances one simulation tick and starts any new god animation.
    let wasGameOver = run.world.gameOver
    var
      oldHeroLanded = newSeq[bool](run.world.heroes.len)
      oldFootmanLanded: Table[int32, bool]
      oldTowerTicks = newSeq[int32](run.world.towers.len)
    for i, hero in run.world.heroes:
      oldHeroLanded[i] = hero.damageLanded
    for footman in run.world.footmen:
      oldFootmanLanded[footman.id] = footman.damageLanded
    for i, tower in run.world.towers:
      oldTowerTicks[i] = tower.attackTicks
    captureUnitPositions()
    advanceGame()
    feedGotaActions(observeTick = true)
    emitTickParticles(
      oldHeroLanded,
      oldFootmanLanded,
      oldTowerTicks
    )
    if int(run.world.tick) mod SeekCheckpointTicks == 0 or
        int32(run.world.tick) == transport.timelineEnd:
      if replayCheckpoints.len == 0 or
          replayCheckpoints[^1].tick < int(run.world.tick):
        replayCheckpoints.add captureCheckpoint()
    if run.world.gameOver and not wasGameOver:
      for god in gods.mitems:
        god.animTime = 0

  proc restoreTo(targetTick: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    var checkpointIndex = 0
    for i, checkpoint in replayCheckpoints:
      if checkpoint.tick > targetTick:
        break
      checkpointIndex = i
    let checkpoint = replayCheckpoints[checkpointIndex]
    run.world.restore(checkpoint.world)
    if run.recorder != nil and run.replayPlayer != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = checkpoint.hashCheck
    run.historyPlayback = true
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    particles.clearParticles()
    renderAlpha = 1
    animationAlpha = 0
    for god in gods.mitems:
      god.animTime = 0
    while int32(run.world.tick) < targetTick:
      advanceGame()
      if int(run.world.tick) mod SeekCheckpointTicks == 0 or
          int32(run.world.tick) == transport.timelineEnd:
        if replayCheckpoints.len == 0 or
            replayCheckpoints[^1].tick < int(run.world.tick):
          replayCheckpoints.add captureCheckpoint()

  if not run.replayMode:
    startReplayRecording(uint32(transport.durationTicks))
  replayCheckpoints = @[captureCheckpoint()]

  let cleanScreenshot =
    when defined(takeScreenshot): existsEnv("CLEAN_SCREENSHOT")
    else: false
  when defined(takeScreenshot):
    var screenshotFrame = 0
    let screenshotPath =
      if existsEnv("SCREENSHOT_PATH"):
        getEnv("SCREENSHOT_PATH")
      else:
        "examples/gods_of_the_arena/gota_shot.png"
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"): cameraTarget.x = getEnv("CAM_X").parseFloat.float32
    if existsEnv("CAM_Z"): cameraTarget.z = getEnv("CAM_Z").parseFloat.float32
    if existsEnv("SHOW_EDGES"): showTiles = getEnv("SHOW_EDGES") != "0"
    if run.replayMode and existsEnv("REPLAY_TICK"):
      transport.seekTo(int32(getEnv("REPLAY_TICK").parseInt))
    if existsEnv("SIM_SECONDS"):
      # Fast-forward the battle deterministically before the first frame.
      let simSeconds = getEnv("SIM_SECONDS").parseFloat
      for i in 0 ..< int(simSeconds * TickRate.float64):
        advanceGame()
    if existsEnv("PARTICLE_DEMO"):
      let
        origin = cameraTarget + vec3(-2.5'f32, 4.0'f32, 0)
        target = cameraTarget + vec3(2.5'f32, 4.0'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target,
        0.42'f32
      )
      particles.emitParticleBurst(
        HealingAura,
        cameraTarget + vec3(0, 3.5'f32, 0)
      )
    if not playerMode():
      for hero in run.world.heroes:
        if hero.class == Arcanist and hero.state != Dying:
          primaryId = hero.id
          selectedIds = @[hero.id]
          followSelection = true
          break
      if primaryId == 0:
        for hero in run.world.heroes:
          if hero.state != Dying:
            primaryId = hero.id
            selectedIds = @[hero.id]
            followSelection = true
            break
    else:
      primaryId = playerHeroId()
      selectedIds = @[primaryId]
      followSelection = false
      cameraTarget = playerHeroFrame()

    if existsEnv("SELECT_ID"):
      selectEntity(getEnv("SELECT_ID").parseInt.int32)
    if existsEnv("SELECT_ALL"):
      selectAllHeroes()
    if cleanScreenshot:
      primaryId = 0
      selectedIds.setLen(0)
      followSelection = false
      viewMode = 0
    if existsEnv("CAM_X") or existsEnv("CAM_Z"):
      followSelection = false
      actionCam.takeManual()

  var
    viewingClock: ViewingClock
    cameraSeekSerial = -1

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime)
      viewingDt = viewingClock.viewingDelta(window)
      viewingSeeking = transport.targetTick >= 0 or transport.restoreTick >= 0
      if not transport.playing or viewingSeeking:
        viewingDt = 0
      if cameraSeekSerial != transport.seekSerial:
        actionCam.resetDirector(transport.automaticSeek)
        cameraSeekSerial = transport.seekSerial
      sk.uiScale = gameUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      pollBrowserKeys(window)
      beginPlayInputFrame()
      profileBlock "camera":
        updateCamera(dt)
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        else: int32(run.replayPlayer.data.hashes.len)
      transport.sync(int32(run.world.tick), recorded, run.world.gameOver)
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(int32(run.world.tick), recorded, run.world.gameOver)
      feedGotaActions(observeTick = true)
      transport.startFrame(dt, TickRate)
      let frameStart = epochTime()
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(
              int32(run.world.tick),
              transport.durationTicks,
              transport.live
          ):
            break
          run.historyPlayback = transport.inHistory
          advanceRenderedSimulation()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            else: int32(run.replayPlayer.data.hashes.len)
          transport.sync(int32(run.world.tick), recordedNow, run.world.gameOver)
      let active = simulationActive(transport)
      if active:
        renderAlpha = clamp(
          transport.accumulator / SimulationStep,
          0.0'f32,
          1.0'f32
        )
        animationAlpha = renderAlpha
      else:
        renderAlpha = 1
        animationAlpha = 0
      if active:
        particles.advanceParticles(dt)
        clickMarks.advanceClickMarks(dt)
        for god in gods.mitems:
          god.animTime += dt
          if run.world.gameOver and god.team != run.world.winner:
            god.animTime = min(
              god.animTime,
              clipDuration(
                footmanModels[god.team], footmanRenderClips[god.team][deathClip])
            )

      feedGotaActions()
      actionCam.direct(
        cameraTarget, cameraDistance, viewingDt,
        run.world.gameOver or transport.tick >= transport.timelineEnd,
        transport.repeating,
        window.size.x.float32 / max(window.size.y.float32, 1),
        RtsGotaFollowLift
      )
      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        view = cameraView()
        projection = perspective(45.0'f32, aspect, 0.1'f32, 1000.0'f32)
        viewProjection = projection * view
        cameraForward = normalize(cameraTarget - cameraEye)
        barCameraRight = normalize(cross(cameraForward, vec3(0, 1, 0)))
        barCameraUp = normalize(cross(barCameraRight, cameraForward))

      updateWorldSelection(viewProjection)
      if not setupOpen:
        updatePlayerSpells(viewProjection)
        updatePlayerOrder(viewProjection)

      profileBlock "drawWorld":
        # One clock for the whole frame: the palette, the sun's position,
        # and its shadow map all follow the in-game hour. The fractional
        # tick keeps the sun gliding between simulation steps instead of
        # visibly stepping shadow positions a few times a second.
        scene.setToonHour(
          clockHour(float32(run.world.tick) + renderAlpha, TickRate))
        setEnvironmentPalette(scene.toon)

        proc drawWorldCharacters(livingOnly = false) =
          ## Uses identical poses for shadows, occlusion masks, and the camera.
          for footman in run.world.footmen:
            if not visibleInView(footman.team, footman.position):
              continue
            if livingOnly and (footman.hp <= 0 or footman.state == Dying):
              continue
            let
              model = footmanModels[footman.team]
              clip = footmanRenderClips[footman.team][footman.animClip]
            drawCharacter(
              scene, model, unitRenderPoint(footman.id, footman.position),
              unitRenderFacing(footman.id, footman.facing),
              clip,
              holdClipTime(
                model, clip, footman.animTicks, footman.state == Dying),
              sizeFactor = footmanSizeFactor(footman.team)
            )
          for hero in run.world.heroes:
            if not visibleInView(hero.team, hero.position):
              continue
            if livingOnly and (hero.hp <= 0 or hero.state == Dying):
              continue
            var
              animation = hero.animClip
              ticks = hero.animTicks
            if hero.hp > 0 and hero.state != Dying:
              for spell in run.world.casts:
                let age = run.world.tick - spell.started
                if spell.heroId == hero.id and age >= 0 and age < 12:
                  animation = heroAttackClips[0]
                  ticks = age * 2
            let clip = heroRenderClips[animation]
            drawCharacter(
              scene,
              heroModels[hero.class],
              unitRenderPoint(hero.id, hero.position),
              unitRenderFacing(hero.id, hero.facing),
              clip,
              holdClipTime(
                heroModels[hero.class],
                clip,
                ticks,
                hero.state == Dying
              ),
              sizeFactor = hero.heroSizeFactor()
            )
          for god in gods:
            if not visibleInView(
                god.team, run.world.forts[god.team.ord].center):
              continue
            if livingOnly and run.world.forts[god.team.ord].hp <= 0:
              continue
            let
              model = footmanModels[god.team]
              clip = footmanRenderClips[god.team][god.godClip]
            var animTime = god.animTime
            if run.world.gameOver and god.team != run.world.winner:
              animTime = min(animTime, clipDuration(model, clip))
            drawCharacter(
              scene, model, god.position, god.facing,
              clip, animTime, sizeFactor = 2.6)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          for tower in run.world.towers:
            if tower.hp <= 0:
              continue
            towerPacks[tower.team].drawPropSunDepth(
              towerPropName(tower.tier),
              renderPoint(tower.position),
              renderFacing(tower.facing),
              towerScale(tower.tier)
            )
          scene.sunDepthPass = true
          drawWorldCharacters()
          scene.sunDepthPass = false
        when not defined(emscripten):
          glEnable(GL_MULTISAMPLE)
        glClearColor(0.05, 0.06, 0.09, 1.0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        scene.toon.drawBackground()
        updateTerrainVision()
        drawTerrain(viewProjection, showTiles)
        for tower in run.world.towers:
          if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
            continue
          towerPacks[tower.team].drawProp(
            towerPropName(tower.tier),
            renderPoint(tower.position),
            renderFacing(tower.facing),
            towerScale(tower.tier),
            viewProjection
          )

        if showOccludedCharacters:
          occlusionOutline.beginMask(window.size)
          beginCharacters(scene, window, view, projection, cameraEye)
          drawWorldCharacters(livingOnly = true)
          finishCharacters(scene)
          # Only opaque scenery is in the window depth buffer at this point.
          occlusionOutline.drawOutline(OccludedOutlineColor)

        beginCharacters(scene, window, view, projection, cameraEye)
        drawWorldCharacters()
        finishCharacters(scene)

        let waterTime =
          (run.world.tick.float32 + renderAlpha) / TickRate.float32
        drawWater(
          viewProjection,
          cameraEye,
          offset = vec2(waterTime * 0.25'f, 0),
          opacity = 0.5'f,
          highlightOpacity = 0.0'f
        )
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward
        )
        spellEffects.drawSpells(
          run.world, viewProjection, animationAlpha, viewMode
        )
        clickMarks.drawClickMarks(viewProjection)
        if showPaths:
          worldShapes.clear()
          for hero in run.world.heroes:
            if hero.state == Dying or hero.hp <= 0:
              continue
            if hero.movePathIndex >= hero.movePath.len:
              continue
            let color =
              if hero.team == RedTeam:
                rgbx(210, 72, 64, 255)
              else:
                rgbx(64, 120, 220, 255)
            var points: seq[Vec3]
            let now = unitRenderPoint(hero.id, hero.position)
            points.add vec3(now.x, now.y + 0.2'f32, now.z)
            for i in hero.movePathIndex ..< hero.movePath.len:
              let p = renderPoint(hero.movePath[i])
              points.add vec3(p.x, p.y + 0.2'f32, p.z)
            if points.len >= 2:
              worldShapes.addPolyline(points, color)
          worldShapes.draw(viewProjection)
        if not cleanScreenshot:
          drawWorldUnitBars(
            worldBarRenderer,
            viewProjection,
            barCameraRight,
            barCameraUp,
            dt
          )
          drawSelectedOutline(view, projection, viewProjection)

      profileBlock "ui":
        if not cleanScreenshot:
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
            viewMode,
            primaryId,
            selectedIds,
            followSelection,
            actionCam,
            focusPlayerHero
          )
          sk.endUi()
          drawStatsOverlay(sk, window)
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          30,
          screenshotPath
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

  if not run.replayMode:
    saveRecording()
  particles.closeParticles()
  spellEffects.closeSpellRenderer()
  selectionOutline.closeSelectionOutline()
  occlusionOutline.closeSelectionOutline()
  finishGameProfile()
