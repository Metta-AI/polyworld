## Light vs Dark spectator viewer.
##
## Reads the simulation and never writes it. The renderer interpolates body
## poses between ticks and samples terrain height for the vertical. None of
## that can flow back into `World`.
##
## Fog is presentation too. All three view modes read the same world; only
## what gets drawn changes.

import
  std/[math, os, strformat, strutils, tables, times, unicode],
  chroma, fixxy, opengl, pixie, vmath, windy, silky,
  polyworld/[actioncam, assets, characters, chargen, chrome, clickmarks, common,
    inputs, lighting, particles, particleshaders, pathing, player, profiles, gameuis,
    quadterrain, rtscameras, selectionoutlines, shapes, shadows, tapes, toon,
    viewers, visions, worldbars, worldtexts, menus, connections, roomclients, rooms, displays],
  appearances, assets, backpacks, buildings, content, factions, groves,
  resourcepacks, symbols, treeorders,
  sim, maps,
  game,
  replays,
  ui,
  controls, homes, lobbies, multiplayer, attackorders, layouts, linemoves,
  networkpresentation, shortcutsettings, unitselection, orderfeedback,
  constructionpresentation, targetfeedback, rendervisibility,
  harvestpresentation, woodcuttingpresentation

const
  DefaultCameraDistance = 17.0'f
  WindowTitle = "Light vs Dark"
  AtlasPath = TmpRoot & "/lvd.atlas.png"
  SeekCheckpointTicks = TickRate * 10
    ## One saved world every ten seconds, so a seek re-simulates at most
    ## that much.
  RebakeFrameGap = 30
    ## Batches nearby harvest and construction changes into one scene update.
  SelectionDragPixels = 6.0'f32
    ## Pointer travel that turns a click into a box select.

type
  MatchMenuPage = enum
    HiddenMatchMenu, PauseMenu, MatchSettings
  GraphicsError = object of CatchableError
  SeekCheckpoint = object
    world: World
    actionIndex: int
    hashCheck: ReplayHashCheck
  SelectionTarget = object
    found: bool
    position: Vec3

var
  window*: Window
  sk*: Silky
  cameraDistance* = DefaultCameraDistance
  cameraTarget* = vec3(0, 0, 0)
  cameraEye = vec3(0, 0, 0)
  panning = false
  minimapPanning* = false
  viewMode* =
    if options.playerSlot > 0: options.playerSlot
    else: options.viewMode
  primaryId* = NoEntity
  selectedIds*: seq[int32]
  followSelection* = false
  selectionPressPosition = vec2(0)
  selectionStarted = false
  selectionAdditive = false
  lineGesture: LineGesture
  rightOrderStarted = false
  targetFlash: TargetFeedback
  groupCameraScale = 1.0'f32
  seekCheckpoints: seq[SeekCheckpoint]
  transport*: player.Player
  placedEditCount = 0
  placedBuildingKey = ""
  sceneDirty = false
  edgesDirty = false
  framesSinceRebake = 0
  frameAlpha = 0.0'f32
  previousUnitPositions: Table[int32, Vec3]
  previousUnitFacings: Table[int32, float32]
  unitPoses: seq[CharacterPose]
  woodAxeModels: seq[CharacterModel]
  resourceModels: seq[array[ResourcePack, array[bool, CharacterModel]]]
  outlinePose: CharacterPose
  terrainVisionTick = int32.low
  terrainVisionMode = int32.low
  terrainReady = false
  shortcutState: ShortcutState
  shortcutHeldButtons, shortcutFrameButtons: set[Button]

## Presentation helpers

proc cancelGameplayGestures() =
  ## Menu input must not leave a half-finished battlefield gesture behind.
  shortcutState.cancelShortcut()
  selectionStarted = false
  selectionAdditive = false
  panning = false
  minimapPanning = false
  rightOrderStarted = false
  lineGesture.cancelLine()

proc selectedBuildWorker(): int32 =
  ## Use the same first eligible selected worker for preview and submission.
  if options.playerSlot <= 0 or run.replayMode: return NoEntity
  for id in selectedIds:
    if id.isUnitId and run.world.hasUnit(id):
      let unit = run.world.units[run.world.unitIndex(id)]
      if unit.owner == options.playerSlot - 1 and unit.kind == PeonUnit and
          unit.hp > 0 and unit.state notin {UnitDying, UnitInMine}:
        return id
  NoEntity

proc refreshPendingBuild(): bool =
  ## Cancel only presentation intent, never a site or the worker's orders.
  if pendingBuild >= 0 and selectedBuildWorker() == NoEntity:
    pendingBuild = -1
    attackMoveArmed = false
    cancelGameplayGestures()
    return true

proc attackMinimapArea*(layout: GameUiLayout): GameUiPanel =
  ## Use the same stacked map rectangle as the HUD, not its clock/buttons.
  layout.panel(GameUiRegion.TopRight, PanelMinimap).minimapPanels().map

proc attackMinimapTile*(layout: GameUiLayout, mouse: Vec2, side: int32): Tile2 =
  let area = attackMinimapArea(layout)
  if not area.contains(mouse) or side <= 0:
    return NoTile
  let relative = (mouse - area.origin) / area.size
  tile2(clamp(int32(relative.x * side.float32), 0, side - 1),
    clamp(int32(relative.y * side.float32), 0, side - 1))

proc mapHalf(): float32 =
  ## Returns the map's world-space radius for drawing and camera bounds.
  run.world.map.side.float32 / 2

proc addHudIcons(builder: AtlasBuilder, factions: openArray[Faction]) =
  ## Packs grayscale unit symbols, building portraits, and the theme logo.
  builder.addThemeLogo(LogoPath)
  let badges = loadUnitSymbols()
  for kind in UnitKind:
    if not builder.addImage(unitSymbolKey(kind), badges[kind]):
      raise newException(
        GraphicsError,
        "The UI atlas is too small for unit symbols."
      )
  for player in 0'i32 ..< int32(min(factions.len, FactionFiles.len)):
    for kind in BuildingKind:
      if kind == GoldMineBuilding and player != LightPlayer:
        continue
      if not builder.addImage(
          buildingPortraitKey(player, kind),
          readImage(buildingPortraitPath(factions[player], kind))
        ):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for building portraits"
        )

proc tileCentreXZ(tile: Tile2): Vec2 =
  ## Converts a tile coordinate to the world-space centre of that tile.
  vec2(float32(tile.x) - mapHalf() + 0.5'f32,
       float32(tile.y) - mapHalf() + 0.5'f32)

proc unitWorldPoint(unit: Unit): Vec3 =
  ## Converts a tile-space body into a render position.
  let
    x = toFloat32(unit.body.pos.x) - mapHalf()
    z = toFloat32(unit.body.pos.y) - mapHalf()
  vec3(x, surfaceHeight(x, z), z)

proc unitYaw(unit: Unit): float32 =
  ## Turns body facing into the renderer's yaw convention.
  let dir = direction(unit.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc renderPoint(unit: Unit): Vec3 =
  ## Interpolates one unit between the latest simulation snapshots.
  let work = run.world.constructionPresentation(unit)
  if work.active:
    let x = work.tilePoint.x - mapHalf()
    let z = work.tilePoint.y - mapHalf()
    return vec3(x, surfaceHeight(x, z) + work.floorLift, z)
  let current = unitWorldPoint(unit)
  if not interpolateVisuals:
    return current
  mix(
    previousUnitPositions.getOrDefault(unit.id, current),
    current,
    frameAlpha
  )

proc renderFacing(unit: Unit): float32 =
  ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
  let work = run.world.constructionPresentation(unit)
  if work.active: return work.yaw
  if not interpolateVisuals:
    return unitYaw(unit)
  let
    current = unitYaw(unit)
    previous = previousUnitFacings.getOrDefault(unit.id, current)
  previous + shortestTurn(previous, current) * frameAlpha

proc renderAnimation(unit: Unit): AnimationSlot =
  ## Uses the construction work pose while a worker is building.
  let work = run.world.constructionPresentation(unit)
  if work.active: work.animation else: unit.animation

proc captureUnitPoses() =
  ## Remembers mobile poses before one authoritative tick.
  previousUnitPositions.clear()
  previousUnitFacings.clear()
  for unit in run.world.units:
    previousUnitPositions[unit.id] = unitWorldPoint(unit)
    previousUnitFacings[unit.id] = unitYaw(unit)

proc renderTime(ticks: int32): float32 =
  ## Converts animation ticks into seconds for the clip sampler.
  (float32(ticks) + frameAlpha) / float32(TickRate)

proc renderUnitModel(unit: Unit, ordinary: CharacterModel): CharacterModel =
  ## Reuses one cargo outfit for the world, shadows and selection outline.
  let pack = carriedPack(unit.kind, unit.hp, unit.carryGold, unit.carryWood)
  if pack != NoPack and unit.owner >= 0 and unit.owner < resourceModels.len:
    let model = resourceModels[unit.owner][pack][unit.woodAxeVisible]
    if model != nil:
      return model
  if unit.woodAxeVisible and unit.owner >= 0 and
    unit.owner < woodAxeModels.len and woodAxeModels[unit.owner] != nil:
      return woodAxeModels[unit.owner]
  ordinary

proc renderUnitClip(unit: Unit, model: CharacterModel, ordinary: int): int =
  ## Overrides only the tree-chopping clip, preserving combat and construction.
  if unit.woodAxeVisible and unit.state == UnitChopping:
    model.clipIndex(unit.woodAnimationClip(""))
  else:
    ordinary

proc buildingCentre(structure: Building): Vec3 =
  ## Returns the world centre of a structure's footprint.
  let
    x = structure.origin.x.float32 +
      structure.footprint.width.float32 * 0.5'f - mapHalf()
    z = structure.origin.y.float32 +
      structure.footprint.depth.float32 * 0.5'f - mapHalf()
  vec3(x, surfaceHeight(x, z), z)

proc initialCameraTarget*(world: World, playerSlot, selectedId: int32): Vec3 =
  ## Frames a human's opening selection once, after terrain is available.
  ## Spectators start at the map centre and retain the action camera.
  if playerSlot > 0:
    let half = world.map.side.float32 / 2
    for unit in world.units:
      if unit.id == selectedId and unit.owner == playerSlot - 1 and
          unit.state notin {UnitDying, UnitInMine}:
        let
          x = toFloat32(unit.body.pos.x) - half
          z = toFloat32(unit.body.pos.y) - half
        return vec3(x, surfaceHeight(x, z), z)
    for preferred in [selectedId, NoEntity]:
      for structure in world.buildings:
        if structure.owner != playerSlot - 1 or structure.state == BuildingDying:
          continue
        if (preferred != NoEntity and structure.id == preferred) or
            (preferred == NoEntity and structure.kind == TownHallBuilding):
          let
            x = structure.origin.x.float32 +
              structure.footprint.width.float32 / 2 - half
            z = structure.origin.y.float32 +
              structure.footprint.depth.float32 / 2 - half
          return vec3(x, surfaceHeight(x, z), z)
  vec3(0, surfaceHeight(0, 0), 0)

proc isSelected*(id: int32): bool =
  ## Returns whether one entity belongs to the RTS selection set.
  for candidate in selectedIds:
    if candidate == id:
      return true

proc shownUnit*(unit: Unit): bool =
  ## Returns whether fog of war currently reveals this unit.
  run.world.renderUnitVisible(viewMode, unit)

proc shownBuilding*(structure: Building): bool =
  ## Returns whether fog of war currently reveals this structure.
  run.world.renderBuildingVisible(viewMode, structure)

proc buildUiAtlas(factions: openArray[Faction]): AtlasBuilder =
  result = newHudAtlas(4096)
  addHudIcons(result, factions)
  result.addDefaultFonts()
  result.addLobbyFonts()
  result.addHomeAssets()
  result.addFont(DefaultFontPath, "WorldName", 32.0)

proc initializeGraphics*() =
  ## Creates one application window without constructing a hidden match.
  if window != nil: return
  let builder = buildUiAtlas(factionOrder(DefaultSeed.int64))
  builder.write(AtlasPath)
  (window, sk) = initGameWindow(WindowTitle, AtlasPath,
    gameWindowSize(options.windowWidth, options.windowHeight),
    options.vsync, msaa = msaa4x)

proc runGraphics*(network: NetworkMatch = nil,
    connection: Connection = nil): bool {.discardable.} =
  ## Owns match resources; the application window survives returning home.
  initializeGraphics()
  window.onFrame = nil
  window.onButtonPress = nil
  window.onButtonRelease = nil
  window.onRune = nil
  window.onFocusChange = nil
  window.runeInputEnabled = false
  shortcutState.resetShortcut()
  shortcutHeldButtons = {}
  shortcutFrameButtons = {}
  endShortcutEditing()
  hudNetwork = network
  resetHudTooltips()
  resetHumanCommunication()
  defer:
    hudNetwork = nil
    resetHudTooltips()
    resetHumanCommunication()
    window.onFrame = nil
    window.onButtonPress = nil
    window.onButtonRelease = nil
    window.onRune = nil
    window.onFocusChange = nil
    window.runeInputEnabled = false
  startGameProfile()
  var
    leaveMatch, quitToMenu, leaveRequested: bool
    matchMenu = HiddenMatchMenu
    preferences = readLvdPreferences()
    saveError: string
  preferences.applyPreferences(window)
  let previousBindings = customBindingsEnabled
  customBindingsEnabled = true
  bindingCapture = false
  defer:
    customBindingsEnabled = previousBindings
    bindingCapture = false
  viewMode = if options.playerSlot > 0: options.playerSlot else: options.viewMode
  primaryId = NoEntity
  lineGesture.cancelLine()
  rightOrderStarted = false
  selectedIds.setLen(0)
  seekCheckpoints.setLen(0)
  previousUnitPositions.clear()
  previousUnitFacings.clear()
  unitPoses.setLen(0)
  terrainVisionTick = int32.low
  terrainVisionMode = int32.low
  pendingBuild = -1
  attackMoveArmed = false
  selectionStarted = false
  panning = false
  minimapPanning = false
  followSelection = false
  cameraDistance = DefaultCameraDistance
  cameraTarget = vec3(0)
  placedEditCount = 0
  placedBuildingKey = ""
  framesSinceRebake = 0
  frameAlpha = 0
  clearPlayerCommands()
  targetFlash = TargetFeedback()
  transport = initPlayer(live = not run.replayMode,
    durationTicks = run.maximumTicks, playing = not options.pauseOnStart,
    speed = options.speed,
    repeating = network == nil and (run.replayMode or options.playerSlot == 0))
  let order = factionOrder(run.mapSeed.int64)
  var playerFactions = newSeq[Faction](run.world.players.len)
  for player in 0 ..< run.world.players.len:
    playerFactions[player] = order[Faction(player mod FactionFiles.len)]
  let builder = buildUiAtlas(playerFactions)
  sk.builder = builder
  sk.image = builder.atlasImage
  sk.atlas = builder.atlas
  sk.uploadAtlas()
  if options.playerSlot > 0 and not run.replayMode:
    let player = options.playerSlot - 1
    for unit in run.world.units:
      if unit.owner == player and unit.state != UnitDying:
        selectedIds.add unit.id
        primaryId = unit.id
        followSelection = false
        break
  let splash = startSplash(sk, window)
  profileBlock "terrain":
    seed = run.mapSeed
    clearProps()
    if not terrainReady:
      initTerrain(
        NoTrees, GeneratedTerrain, NoRocks, LvdTerrainTiles,
        settings = LvdTerrainAssets
      )
      terrainReady = true
    setTileMaterial(
      RockTile.int,
      LvdRockSurface,
      LvdRockSurface,
      vec3(1),
      vec3(0.85),
      4
    )
    setTileMaterial(
      StoneTile.int,
      LvdStoneSurface,
      LvdRockSurface,
      vec3(1),
      vec3(0.85),
      6
    )

  ## Players share the approved CharGen equipment and CC0 animations.
  var
    unitModels = newSeq[array[UnitKind, CharacterModel]](run.world.players.len)
    unitClips = newSeq[array[UnitKind, array[AnimationSlot, int]]](
      run.world.players.len
    )
    teamColors = newSeq[ColorRGBX](run.world.players.len)
    unitModelCache: UnitModelCache
  woodAxeModels = newSeq[CharacterModel](run.world.players.len)
  resourceModels = newSeq[array[ResourcePack, array[bool, CharacterModel]]](
    run.world.players.len
  )
  profileBlock "models":
    let
      manifest = readManifest(ChargenLibrary)
      roster = readCharacterRoster(playerFactions)
    for player in 0 ..< run.world.players.len:
      # UI and every summoned body identify their owning faction.
      teamColors[player] = FactionColors[roster.factions[player]]
      if player >= FactionFiles.len:
        unitModels[player] = unitModels[player mod FactionFiles.len]
        unitClips[player] = unitClips[player mod FactionFiles.len]
        woodAxeModels[player] = woodAxeModels[player mod FactionFiles.len]
        resourceModels[player] = resourceModels[player mod FactionFiles.len]
        continue
      for kind in UnitKind:
        let model = unitModelCache.loadUnitModel(
          manifest, roster.players[player][kind.ord], kind
        )
        unitModels[player][kind] = model
        for slot in AnimationSlot:
          unitClips[player][kind][slot] = model.clipIndex(kind.unitClip(slot))
      woodAxeModels[player] = unitModelCache.loadUnitModel(
        manifest, roster.players[player][PeonUnit.ord], PeonUnit, woodAxe = true
      )
      for pack in WoodPack .. GoldPack:
        for axe in false .. true:
          resourceModels[player][pack][axe] = unitModelCache.loadBackpackModel(
            manifest,
            roster.players[player][PeonUnit.ord],
            pack,
            woodAxe = axe
          )
  drawSplash(sk, window, splash.name)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  setEnvironmentPalette(scene.toon)
  var
    attackClickMarks = initClickMarks(orderMarkSettings(attack = true))
    particles = initParticleSystem()
    harvesting: HarvestPresentation
    harvestBars = initWorldBarRenderer()
    currentSight: seq[uint8]
    clickMarks = initClickMarks(orderMarkSettings(attack = false))
    worldShapes = initShapeRenderer()
    worldBarRenderer = initWorldBarRenderer()
    playerLabels = layoutNames(
      sk.atlas.fonts["WorldName"],
      sk.atlas.size,
      run.config.players
    )
    damageTrails: DamageTrailTracker
    selectionOutline = initSelectionOutline()

  var
    grove: Grove
    buildingArt: BuildingArt
  let scenery = grovePlacements(
    run.world.treeWood, run.mapSeed, run.world.map.forestRocks
  )
  profileBlock "props":
    profileBlock "grove models":
      grove = generateGrove(run.mapSeed, {LightTree, LightRock})
    profileBlock "building models":
      buildingArt = loadBuildingArt(grove, factions = playerFactions)

  proc buildingKey(): string =
    ## Detects changes to displayed construction stages and building lifetimes.
    result = $run.world.terrainEdits.len & ":view=" & $viewMode
    for structure in run.world.buildings:
      result.add &"|{structure.id}:{structure.state.ord}:{shownBuilding(structure)}"
      if structure.state == BuildingUnderConstruction:
        result.add &":{structure.constructionStage().ord}"

  proc placeSceneProps() {.measure.} =
    ## Submits desired placements while the renderer retains unchanged groups.
    clearProps()
    grove.plantGrove(scenery, run.world.treeWood)
    for structure in run.world.buildings:
      if not shownBuilding(structure): continue
      for part in buildingArt.buildingParts(
        structure, buildingCentre(structure)
      ):
        # Baked props use the opposite yaw to the standalone outline pass.
        part.pack.placeProp(
          part.name,
          part.position,
          -part.rotation,
          part.scale,
          group = structure.id
        )

  proc applyTerrainEdits(): bool {.measure.} =
    ## Reports actual ground changes, including trees restored by replay seeks.
    for placement in scenery:
      if placement.kind == LightTree:
        let kind =
          if placement.visible(run.world.treeWood):
            TreeTile
          else:
            GrassTile
        if layers[0].tiles[placement.tile].kind != kind:
          layers[0].tiles[placement.tile].kind = kind
          result = true

  proc rebakeScene(initial = false) =
    ## Refreshes changed props and rebuilds ground only for terrain edits.
    let groundChanged = applyTerrainEdits()
    placeSceneProps()
    if initial or groundChanged:
      # Rendering never recomputes authoritative movement walkability.
      bakeTerrain(
        rebuildWalkability = false,
        blockers = [run.world.blocker]
      )
      edgesDirty = false
    else:
      bakeProps()
      edgesDirty = true
    placedEditCount = run.world.terrainEdits.len
    placedBuildingKey = buildingKey()
    sceneDirty = false
    framesSinceRebake = 0

  profileBlock "bake":
    rebakeScene(initial = true)

  proc liveWalkable(layer, x, z: int): bool {.nimcall.} =
    ## Supplies current blockers when the optional movement grid is visible.
    layer == 0 and run.world.tileOpen(int32(x), int32(z))
  cameraTarget = initialCameraTarget(run.world,
    if run.replayMode: 0'i32 else: options.playerSlot, primaryId)
  var
    viewingDt = 0.0'f
    viewingSeeking = false
    actionCam = initActionCam(
      subjectMode = true,
      defaultDistance = DefaultCameraDistance,
      minDistance = 40,
      maxDistance = 240,
      tight = 0.4,
      followRate = 1.0,
      zoomRate = 0.7,
      holdSeconds = 2.8,
      mapSpan = mapHalf() * 2,
      closeScale = 0.5
    )

  ## Replay scaffolding

  seekCheckpoints.add SeekCheckpoint(
    world: run.world.clone(),
    actionIndex: 0,
    hashCheck: run.hashCheck
  )

  proc captureCheckpoint() =
    if run.world.tick div SeekCheckpointTicks < seekCheckpoints.len:
      return
    seekCheckpoints.add SeekCheckpoint(
      world: run.world.clone(),
      actionIndex: run.replayPlayer.actionIndex,
      hashCheck: run.hashCheck
    )

  proc restoreTo(target: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    let wanted = clamp(target, 0'i32, transport.timelineEnd)
    var slot = min(
      int(wanted) div SeekCheckpointTicks,
      seekCheckpoints.len - 1
    )
    while slot > 0 and seekCheckpoints[slot].world.tick > wanted:
      dec slot
    run.world.restore(seekCheckpoints[slot].world)
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = seekCheckpoints[slot].hashCheck
    run.historyPlayback = true
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    sceneDirty = true
    particles.clearParticles()
    harvesting.clearHarvest()
    terrainVisionTick = -1
    terrainVisionMode = -1
    while run.world.tick < wanted:
      advanceGame()
      if network == nil: captureCheckpoint()

  ## Camera and input

  proc selectionTarget(id: int32): SelectionTarget =
    ## Returns the current render position of a selectable entity.
    if id.isUnitId and run.world.hasUnit(id):
      let unit = run.world.units[run.world.unitIndex(id)]
      if unit.state notin {UnitDying, UnitInMine} and shownUnit(unit):
        return SelectionTarget(found: true, position: renderPoint(unit))
    elif id.isBuildingId and run.world.hasBuilding(id):
      let structure = run.world.buildings[run.world.buildingIndex(id)]
      if structure.state != BuildingDying and shownBuilding(structure):
        return SelectionTarget(
          found: true,
          position: buildingCentre(structure)
        )

  proc selectedCount(): int =
    ## Returns the number of valid selected entities.
    for id in selectedIds:
      if selectionTarget(id).found:
        inc result

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one side.
    options.playerSlot > 0 and not run.replayMode

  if playerMode():
    actionCam.takeManual()

  proc selectEntity(id: int32, additive = false) =
    ## Selects or toggles one entity. Spectator mode follows the selection.
    if not selectionTarget(id).found:
      return
    if not additive:
      selectedIds.setLen(0)
    elif isSelected(id) and selectedIds.len > 1:
      for i in 0 ..< selectedIds.len:
        if selectedIds[i] == id:
          selectedIds.delete(i)
          break
      primaryId = selectedIds[0]
      if not playerMode():
        followSelection = true
      actionCam.takeManual()
      return
    if not isSelected(id):
      selectedIds.add id
    primaryId = id
    if not playerMode():
      followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc clearSelection() =
    ## Clears the selection and leaves the camera free-floating.
    let hadSelection =
      selectedIds.len > 0 or
      primaryId != NoEntity or
      followSelection
    selectedIds.setLen(0)
    primaryId = NoEntity
    followSelection = false
    if hadSelection:
      actionCam.takeManual()

  proc selectAllUnits() =
    ## Selects all living mobile units for group following.
    selectedIds.setLen(0)
    let owner =
      if options.playerSlot > 0 and not run.replayMode:
        options.playerSlot - 1
      else:
        -1'i32
    for unit in run.world.units:
      if unit.state notin {UnitDying, UnitInMine} and shownUnit(unit):
        if owner >= 0 and unit.owner != owner:
          continue
        selectedIds.add unit.id
    if selectedIds.len > 0:
      primaryId = selectedIds[0]
      if not playerMode():
        followSelection = true
      actionCam.takeManual()
      groupCameraScale = 1.0'f32

  proc pruneSelection() =
    ## Removes entities that have died or left the selectable world.
    var i = selectedIds.high
    while i >= 0:
      if not selectionTarget(selectedIds[i]).found:
        selectedIds.delete(i)
      dec i
    if selectedIds.len == 0:
      primaryId = NoEntity
      followSelection = false
    elif not isSelected(primaryId):
      primaryId = selectedIds[0]

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all valid selected entities.
    var count = 0
    for id in selectedIds:
      let target = selectionTarget(id)
      if target.found:
        result += target.position
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
        x = target.position.x - center.x
        z = target.position.z - center.z
      result = max(result, sqrt(x * x + z * z))

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

  proc addPlayerNames() =
    ## Labels each visible living town hall with its owner's name.
    for structure in run.world.buildings:
      if structure.kind != TownHallBuilding or structure.hp <= 0 or
        structure.owner < 0 or structure.owner >= run.config.players.len or
        not shownBuilding(structure):
          continue
      let anchor = buildingCentre(structure) +
        vec3(0, buildingArt.heights[TownHallBuilding] + 0.4'f, 0)
      worldBarRenderer.addText(
        playerLabels[structure.owner],
        anchor
      )

  proc pickEntity(viewProjection: Mat4): int32 =
    ## Finds the nearest visible unit or structure under the pointer.
    var bestDistance = 28.0'f32
    template consider(id: int32, position: Vec3, height: float32) =
      block:
        let distance = (
          screenPosition(position + vec3(0, height, 0), viewProjection) -
          window.mousePos.vec2
        ).length
        if distance < bestDistance:
          bestDistance = distance
          result = id
    for unit in run.world.units:
      if unit.state in {UnitDying, UnitInMine} or
          not shownUnit(unit):
        continue
      consider(unit.id, renderPoint(unit), UnitHeights[unit.kind] * 0.5'f32)
    if result == NoEntity:
      let (origin, direction) = mouseRay(
        window.mousePos.vec2, window.size.vec2, viewProjection
      )
      var nearest = float32.high
      for structure in run.world.buildings:
        if structure.state == BuildingDying or not shownBuilding(structure):
          continue
        for part in buildingArt.buildingParts(
          structure, buildingCentre(structure)
        ):
          let distance = part.pack.pickProp(
            part.name, origin, direction, part.position,
            part.rotation, part.scale
          )
          if distance > 0 and distance < nearest:
            nearest = distance
            result = structure.id
      if result != NoEntity:
        return
    for structure in run.world.buildings:
      if structure.state == BuildingDying or
          not shownBuilding(structure):
        continue
      consider(structure.id, buildingCentre(structure), 1.4'f32)
      for y in 0'i32 ..< structure.footprint.depth:
        for x in 0'i32 ..< structure.footprint.width:
          let
            tileX = int32(structure.origin.x) + x
            tileY = int32(structure.origin.y) + y
            world = tileCentreXZ(tile2(tileX, tileY))
          consider(
            structure.id,
            vec3(world.x, surfaceHeight(world.x, world.y), world.y),
            0.6'f32
          )

  proc structureAtTile(x, y: int32): int32 =
    ## Standing structure whose footprint contains this tile.
    result = NoEntity
    if not run.world.map.inGrid(x, y):
      return
    for structure in run.world.buildings:
      if structure.state == BuildingDying or
          not shownBuilding(structure):
        continue
      if covers(structure.origin, structure.footprint, x, y):
        return structure.id

  proc insideBox(point, origin, size: Vec2): bool =
    ## Returns whether a screen point lies inside a drag rectangle.
    point.x >= origin.x and
      point.y >= origin.y and
      point.x <= origin.x + size.x and
      point.y <= origin.y + size.y

  proc boxedUnits(viewProjection: Mat4): seq[int32] =
    ## Returns visible units whose screens fall inside the drag box.
    let
      press = selectionPressPosition
      current = window.mousePos.vec2
      origin = vec2(min(press.x, current.x), min(press.y, current.y))
      size = vec2(abs(current.x - press.x), abs(current.y - press.y))
      ownerFilter =
        if viewMode == 0: -1'i32
        else: viewMode - 1
    for unit in run.world.units:
      if unit.state in {UnitDying, UnitInMine}:
        continue
      if ownerFilter >= 0 and unit.owner != ownerFilter:
        continue
      if not shownUnit(unit):
        continue
      let point = screenPosition(
        renderPoint(unit) +
          vec3(0, UnitHeights[unit.kind] * 0.5'f32, 0),
        viewProjection
      )
      if insideBox(point, origin, size):
        result.add unit.id

  proc selectBox(ids: seq[int32], additive: bool) =
    ## Replaces or extends the selection with boxed units.
    if ids.len == 0:
      if not additive:
        clearSelection()
      return
    if not additive:
      selectedIds.setLen(0)
    for id in ids:
      if not isSelected(id):
        selectedIds.add id
    primaryId = ids[0]
    if not playerMode():
      followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc feedLvdActions(observeTick = false) =
    ## Refreshes real subjects and observes every simulated tick.
    if not actionCam.enabled:
      return
    var subjects: seq[Subject]
    for unit in run.world.units:
      subjects.add Subject(
        id: unit.id, owner: unit.owner, position: renderPoint(unit),
        height: 0.9, radius: 1.5, visible: shownUnit(unit) and unit.state != UnitInMine,
        alive: unit.hp > 0 and unit.state != UnitDying,
        hp: unit.hp, maxHp: unitOf(unit.owner, unit.kind).hp,
        complete: true, participant: unit.targetId,
        fighting: unit.state == UnitAttacking, activity: unit.cooldown,
        progress: int32(unit.state), gold: unit.carryGold + unit.carryWood,
        idleScore: (if unit.state == UnitIdle: 8.0'f else: 22.0'f),
        combatScore: 90
      )
    for building in run.world.buildings:
      subjects.add Subject(
        id: building.id, owner: building.owner,
        position: buildingCentre(building), height: 2,
        radius: float32(max(building.footprint.width,
          building.footprint.depth)) * 0.7'f, visible: shownBuilding(building),
        alive: building.hp > 0 and building.state != BuildingDying,
        hp: building.hp, maxHp: building.maxHp,
        complete: building.state == BuildingComplete,
        progress: building.queueLength,
        idleScore: (if building.state == BuildingUnderConstruction: 24.0'f
          else: 4.0'f),
        combatScore: (if building.kind == TownHallBuilding: 165.0'f
          else: 105.0'f)
      )
    if observeTick and not viewingSeeking:
      actionCam.director.observe(subjects)
    actionCam.director.refresh(subjects)

  proc updateCamera(dt: float32, focused = window.focused) =
    ## Applies fixed-north RTS pan, zoom, and selection following.
    if refreshPendingBuild(): return
    if not focused:
      shortcutState.resetShortcut()
      shortcutHeldButtons = {}
      shortcutFrameButtons = {}
      cancelHumanCommunicationInput()
      window.runeInputEnabled = false
    if not focused or matchMenu != HiddenMatchMenu or bindingCapture or
        humanCommunicationBlocksGameplay():
      cancelGameplayGestures()
      return
    pruneSelection()
    if attackMoveArmed:
      minimapPanning = false
    else:
      updateMinimapCamera(
        window, sk.mousePos, cameraTarget, minimapPanning, followSelection
      )
    if minimapPanning:
      actionCam.takeManual()
    let overUi = mouseOverUi(window, sk.mousePos)
    if window.buttonPressed[KeyA] and
        window.actionDown(ControlInput):
      attackMoveArmed = false
      selectAllUnits()
    elif window.mousePressed(MouseLeft) and not overUi and not attackMoveArmed and
        pendingBuild < 0:
      selectionPressPosition = window.mousePos.vec2
      selectionStarted = true
      selectionAdditive =
        window.actionDown(ShiftInput)
    if window.mousePressed(MouseMiddle) and
        (not overUi or window.keyboardPanPressed()):
      panning = true
    if not window.mouseDown(MouseMiddle):
      panning = false
    let delta = window.mouseDelta.vec2
    if panning:
      followSelection = false
      actionCam.takeManual()
      let
        speed = cameraDistance * 0.0015
      cameraTarget.x -= delta.x * speed
      cameraTarget.z -= delta.y * speed
      cameraTarget.x = clamp(cameraTarget.x, -mapHalf(), mapHalf())
      cameraTarget.z = clamp(cameraTarget.z, -mapHalf(), mapHalf())
    if not minimapPanning and
        applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          mapHalf()
        ):
      followSelection = false
      actionCam.takeManual()
    if not overUi and window.scrollDelta.y != 0:
      actionCam.takeManual()
      if followSelection and selectedCount() > 1:
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
          8.0'f32,
          400.0'f32
        )
    if actionCam.enabled:
      return
    let count = selectedCount()
    if followSelection and count == 1:
      let focus = selectionTarget(selectedIds[0]).position
      cameraTarget = mix(
        cameraTarget,
        focus,
        damping(5.0'f32, dt)
      )
    elif followSelection and count > 1:
      let
        center = selectedCenter()
        distance = clamp(
          14.0'f32 + selectedRadius(center) * 2.8'f32,
          24.0'f32,
          400.0'f32
        ) * groupCameraScale
      cameraTarget = mix(
        cameraTarget,
        center,
        damping(4.0'f32, dt)
      )
      cameraDistance = mix(
        cameraDistance,
        distance,
        damping(2.0'f32, dt)
      )
    elif followSelection:
      clearSelection()

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Windy raises DoubleClick on the second left press, not its release.
    if refreshPendingBuild(): return
    if window.buttonPressed[DoubleClick]:
      # Consume the second release even when a modal/HUD/command owns input.
      selectionStarted = false
      if matchMenu != HiddenMatchMenu or not transport.playing or
          mouseOverUi(window, sk.mousePos) or pendingBuild >= 0 or
          attackMoveArmed or bindingCapture:
        return
      let owner =
        if playerMode(): options.playerSlot - 1
        elif viewMode > 0: viewMode - 1
        else: -1'i32
      let ids = run.world.matchingUnitIds(pickEntity(viewProjection), owner)
      if ids.len > 0:
        selectBox(ids, window.actionDown(ShiftInput))
        # The consumed press must not collapse back to a single selection.
        return
    if not window.mouseReleased(MouseLeft):
      return
    if not selectionStarted:
      return
    let
      drag = (
        window.mousePos.vec2 - selectionPressPosition
      ).length
      overUi = mouseOverUi(window, sk.mousePos)
    if drag > SelectionDragPixels:
      selectBox(
        boxedUnits(viewProjection),
        selectionAdditive
      )
    elif not overUi:
      if not (playerMode() and pendingBuild >= 0):
        let picked = pickEntity(viewProjection)
        if picked != NoEntity:
          selectEntity(picked, selectionAdditive)
        elif not selectionAdditive:
          clearSelection()
    selectionStarted = false

  proc buildGhostOrigin(viewProjection: Mat4): (int32, int32) =
    ## Snaps the pending footprint so the cursor sits on its centre tile.
    let
      kind = BuildingKind(pendingBuild)
      size = BuildingTable[kind].footprint
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, mapHalf(), run.world.map.side)
    (tile[0] - size.width div 2, tile[1] - size.depth div 2)

  proc queuePendingBuild(x, y: int32) =
    ## Sends the first selected peon to raise the pending structure.
    let id = selectedBuildWorker()
    if id != NoEntity:
      queueBuild(options.playerSlot - 1, id, pendingBuild, x, y)
      pendingBuild = -1
    else:
      discard refreshPendingBuild()

  proc clickTilePoint(x, y: int32): Vec3 =
    ## Returns the render centre of one map tile.
    let xz = tileCentreXZ(tile2(x, y))
    vec3(xz.x, surfaceHeight(xz.x, xz.y), xz.y)

  proc issueSelectedMove(player, x, y: int32, append = false): bool =
    ## Moves every selected owned unit, or rallies a selected building.
    if not run.world.map.inGrid(x, y) or not run.world.terrainOpen(x, y):
      return false
    for id in selectedIds:
      if id.isUnitId and run.world.unitOwner(id) == player:
        if run.world.hasUnit(id):
          let unit = run.world.units[run.world.unitIndex(id)]
          if unit.hp <= 0 or unit.state == UnitDying or
              (unit.state == UnitInMine and not append):
            continue
        queueMove(player, id, x, y, append = append)
        result = true
    if not result:
      for id in selectedIds:
        if id.isBuildingId and run.world.buildingOwner(id) == player:
          queueSetRally(player, id, x, y)
          result = true

  proc updatePlayerOrder(viewProjection: Mat4, focused = window.focused) =
    ## A + primary targets an enemy or attack-moves combat-capable units.
    ## Keep arming through secondary press for the line-order gesture adapter.
    if refreshPendingBuild(): return
    if not playerMode() or hudTooltipContains(sk.mousePos):
      lineGesture.cancelLine()
      rightOrderStarted = false
      return
    let
      rightOrder = window.mouseReleased(MouseRight)
      buildClick = pendingBuild >= 0 and window.mousePressed(MouseLeft)
      attackClick = pendingBuild < 0 and attackMoveArmed and window.mousePressed(MouseLeft)
      player = options.playerSlot - 1
      inside = window.mousePos.x >= 0 and window.mousePos.y >= 0 and
        window.mousePos.x < window.size.x and window.mousePos.y < window.size.y
      overUi = mouseOverUi(window, sk.mousePos)
      onMinimap = attackMinimapTile(currentLayout(window), sk.mousePos,
        run.world.map.side) != NoTile and not window.buttonDown[KeyTab]
    if window.mousePressed(MouseRight):
      rightOrderStarted = inside and (not overUi or onMinimap)
      if rightOrderStarted and not overUi and not onMinimap and pendingBuild < 0:
        let ground = pickGroundPoint(window.mousePos.vec2, window.size.vec2,
          viewProjection, cameraTarget.y)
        lineGesture.beginLine(run.world, player, selectedIds,
          linePoint(ground.x + mapHalf(), ground.z + mapHalf()),
          linePoint(window.mousePos.x, window.mousePos.y), attackMoveArmed)
    if lineGesture.active:
      if not inside or not focused or pendingBuild >= 0:
        lineGesture.cancelLine()
        rightOrderStarted = false
      else:
        let ground = pickGroundPoint(window.mousePos.vec2, window.size.vec2,
          viewProjection, cameraTarget.y)
        # A drawn preview is a promise: release commits its exact snapshot,
        # rather than reallocating slots after the simulation advanced.
        if not rightOrder or not lineGesture.dragging:
          lineGesture.updateLine(run.world, selectedIds,
            linePoint(ground.x + mapHalf(), ground.z + mapHalf()),
            linePoint(window.mousePos.x, window.mousePos.y))
        if not lineGesture.active:
          rightOrderStarted = false
        elif rightOrder:
          let wasAttack = lineGesture.attackMove
          let targets = lineGesture.targets
          let outcome = lineGesture.releaseLine(run.world, selectedIds,
            inside = inside and not overUi,
            append = window.actionDown(ShiftInput))
          if outcome != LineClick:
            rightOrderStarted = false
            if outcome == LineCommitted:
              for target in targets:
                if wasAttack:
                  attackClickMarks.emitClickMark(clickTilePoint(target.tile.x.int32,
                    target.tile.y.int32))
                else:
                  clickMarks.emitClickMark(clickTilePoint(target.tile.x.int32,
                    target.tile.y.int32))
              attackMoveArmed = false
            return
        elif not window.mouseDown(MouseRight):
          lineGesture.cancelLine()
          rightOrderStarted = false
    if not rightOrder and not attackClick and not buildClick:
      return
    if rightOrder:
      if not rightOrderStarted or not inside: return
      rightOrderStarted = false
      attackMoveArmed = false
    if pendingBuild >= 0:
      # Placement owns this press and its release, including invalid sites.
      # HUD chooses a blueprint after this pass; only a fresh world press places it.
      selectionStarted = false
      minimapPanning = false
      if not inside or overUi or onMinimap: return
      let origin = buildGhostOrigin(viewProjection)
      if run.world.canPlace(player, BuildingKind(pendingBuild), origin[0], origin[1],
          selectedBuildWorker()):
        queuePendingBuild(origin[0], origin[1])
        clickMarks.emitClickMark(clickTilePoint(origin[0], origin[1]))
      return
    # Minimap orders must precede generic HUD rejection. Tab owns its overlay.
    let mini = attackMinimapTile(currentLayout(window), sk.mousePos,
      run.world.map.side)
    if mini != NoTile and not window.buttonDown[KeyTab]:
      if attackClick and not rightOrder:
        selectionStarted = false
        minimapPanning = false
        if run.world.queueArmedAttackMove(player, selectedIds,
            mini.x.int32, mini.y.int32, append = window.actionDown(ShiftInput)):
          attackClickMarks.emitClickMark(clickTilePoint(mini.x.int32, mini.y.int32))
      elif pendingBuild < 0 and issueSelectedMove(player, mini.x.int32, mini.y.int32, append = window.actionDown(ShiftInput)):
        clickMarks.emitClickMark(clickTilePoint(mini.x.int32, mini.y.int32))
      return
    if mouseOverUi(window, sk.mousePos):
      return
    if attackClick and not rightOrder:
      selectionStarted = false
      let picked = pickEntity(viewProjection)
      if picked != NoEntity:
        if run.world.queueFeedbackAttack(player, selectedIds, picked,
            append = window.actionDown(ShiftInput)):
          targetFlash.flashTarget(AttackEntityFlash, picked, player)
          attackMoveArmed = false
          if run.world.hasUnit(picked):
            attackClickMarks.emitClickMark(renderPoint(run.world.units[run.world.unitIndex(picked)]))
          elif run.world.hasBuilding(picked):
            attackClickMarks.emitClickMark(buildingCentre(run.world.buildings[run.world.buildingIndex(picked)]))
        # Friendly/neutral/invalid entity clicks never become ground orders.
        return
      let ground = pickGroundPoint(window.mousePos.vec2, window.size.vec2,
        viewProjection, cameraTarget.y)
      let tile = groundTile(ground, mapHalf(), run.world.map.side)
      if run.world.queueArmedAttackMove(player, selectedIds, tile[0], tile[1], append = window.actionDown(ShiftInput)):
        attackClickMarks.emitClickMark(clickTilePoint(tile[0], tile[1]))
      return
    let
      picked = pickEntity(viewProjection)
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, mapHalf(), run.world.map.side)
      tree = grove.pickHarvestTree(
        scenery, run.world.treeWood, window.mousePos.vec2, window.size.vec2,
        viewProjection, cameraTarget.y
      )
      under = structureAtTile(tile[0], tile[1])
      target =
        if under != NoEntity:
          under
        else:
          picked
    if target != NoEntity:
      if run.world.hasBuilding(target):
        let structure = run.world.buildings[run.world.buildingIndex(target)]
        if structure.owner == player and structure.state == BuildingUnderConstruction:
          for id in run.world.eligibleLineUnits(player, selectedIds):
            let unit = run.world.units[run.world.unitIndex(id)]
            if unit.kind == PeonUnit:
              queueBuild(player, id, structure.kind.ord.int32,
                structure.origin.x.int32, structure.origin.y.int32)
              clickMarks.emitClickMark(buildingCentre(structure))
              return
          return
        if structure.kind == GoldMineBuilding:
          if run.world.queueFeedbackHarvest(player, selectedIds, target, tree = false,
              append = window.actionDown(ShiftInput)):
            targetFlash.flashTarget(HarvestEntityFlash, target, player)
            clickMarks.emitClickMark(buildingCentre(structure))
          attackMoveArmed = false
          return
        if structure.owner != player:
          if run.world.queueFeedbackAttack(player, selectedIds, target,
              append = window.actionDown(ShiftInput)):
            targetFlash.flashTarget(AttackEntityFlash, target, player)
            attackClickMarks.emitClickMark(buildingCentre(structure))
          attackMoveArmed = false
          return
      elif run.world.hasUnit(target) and
          run.world.unitOwner(target) != player:
        if run.world.queueFeedbackAttack(player, selectedIds, target,
            append = window.actionDown(ShiftInput)):
          targetFlash.flashTarget(AttackEntityFlash, target, player)
          attackClickMarks.emitClickMark(renderPoint(run.world.units[run.world.unitIndex(target)]))
        attackMoveArmed = false
        return
    if tree >= 0:
      if run.world.queueFeedbackHarvest(player, selectedIds, tree, tree = true,
          append = window.actionDown(ShiftInput)):
        targetFlash.flashTarget(HarvestTreeFlash, tree, player)
        clickMarks.emitClickMark(clickTilePoint(
          tree mod run.world.map.side, tree div run.world.map.side
        ))
      attackMoveArmed = false
      return
    if issueSelectedMove(player, tile[0], tile[1], append = window.actionDown(ShiftInput)):
      clickMarks.emitClickMark(clickTilePoint(tile[0], tile[1]))
    attackMoveArmed = false

  proc cameraView(): Mat4 =
    ## Returns the shared fixed-north RTS view matrix.
    cameraEye = rtsCameraEye(cameraTarget, cameraDistance)
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  proc drawBuildingOutline(
      structure: Building,
      viewProjection: Mat4
  ) =
    ## Draws one structure's props into the current selection mask.
    for part in buildingArt.buildingParts(
      structure, buildingCentre(structure)
    ):
      part.pack.drawProp(
        part.name,
        part.position,
        part.rotation,
        part.scale,
        viewProjection
      )

  proc drawSelectedOutline(
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws selected units and buildings into one yellow silhouette.
    var
      anyUnit = false
      anyBuilding = false
    for id in selectedIds:
      if id.isUnitId and run.world.hasUnit(id):
        let unit = run.world.units[run.world.unitIndex(id)]
        if shownUnit(unit) and unit.state != UnitDying:
          anyUnit = true
      elif id.isBuildingId and run.world.hasBuilding(id):
        let structure = run.world.buildings[run.world.buildingIndex(id)]
        if shownBuilding(structure) and
            structure.state != BuildingDying:
          anyBuilding = true
    if not anyUnit and not anyBuilding:
      return
    selectionOutline.beginMask(window.size)
    if anyUnit:
      beginCharacters(scene, window, view, projection, cameraEye)
      for id in selectedIds:
        if not id.isUnitId or not run.world.hasUnit(id):
          continue
        let unit = run.world.units[run.world.unitIndex(id)]
        if not shownUnit(unit) or unit.state == UnitDying:
          continue
        let
          model = renderUnitModel(unit, unitModels[unit.owner][unit.kind])
          clip = renderUnitClip(
            unit, model, unitClips[unit.owner][unit.kind][renderAnimation(unit)]
          )
        var animTime = unit.woodAnimationTime(
          renderTime(unit.animationTicks), frameAlpha
        )
        if unit.animation == DeathAnimation or
            unit.animation == VictoryAnimation:
          animTime = min(animTime, clipDuration(model, clip))
        scene.prepareCharacter(
          outlinePose,
          model,
          renderPoint(unit),
          renderFacing(unit),
          clip,
          animTime
        )
        scene.drawCharacter(outlinePose)
      finishCharacters(scene)
    if anyBuilding:
      for id in selectedIds:
        if not id.isBuildingId or not run.world.hasBuilding(id):
          continue
        let structure = run.world.buildings[run.world.buildingIndex(id)]
        if not shownBuilding(structure) or
            structure.state == BuildingDying:
          continue
        drawBuildingOutline(structure, viewProjection)
    selectionOutline.drawOutline()

  proc drawTargetOutline(view, projection, viewProjection: Mat4) =
    ## Separate mask/composite keeps the ordinary selected silhouette intact.
    if not targetFlash.targetFlashVisible(run.world): return
    selectionOutline.beginMask(window.size)
    let target = targetFlash.target
    if targetFlash.kind == HarvestTreeFlash:
      for placement in scenery:
        if placement.kind == LightTree and placement.tile == target:
          grove.trees.drawProp(modelName(placement.kind, placement.variant),
            placement.position, -placement.rotation, placement.scale, viewProjection)
          break
    elif run.world.hasBuilding(target):
      drawBuildingOutline(run.world.buildings[run.world.buildingIndex(target)], viewProjection)
    elif run.world.hasUnit(target):
      let unit = run.world.units[run.world.unitIndex(target)]
      let model = renderUnitModel(unit, unitModels[unit.owner][unit.kind])
      let clip = renderUnitClip(unit, model,
        unitClips[unit.owner][unit.kind][renderAnimation(unit)])
      var animTime = unit.woodAnimationTime(renderTime(unit.animationTicks), frameAlpha)
      if unit.animation in {DeathAnimation, VictoryAnimation}:
        animTime = min(animTime, clipDuration(model, clip))
      beginCharacters(scene, window, view, projection, cameraEye)
      scene.prepareCharacter(outlinePose, model, renderPoint(unit),
        renderFacing(unit), clip, animTime)
      scene.drawCharacter(outlinePose)
      finishCharacters(scene)
    selectionOutline.drawOutline(targetFlash.targetFlashColor())

  proc drawBuildGhost(viewProjection: Mat4) =
    ## Follows the pointer with a transparent building while placing.
    if refreshPendingBuild(): return
    if not playerMode() or pendingBuild < 0:
      return
    let
      kind = BuildingKind(pendingBuild)
      size = BuildingTable[kind].footprint
      origin = buildGhostOrigin(viewProjection)
    let
      valid = run.world.canPlace(options.playerSlot - 1, kind, origin[0], origin[1],
        selectedBuildWorker())
      x = float32(origin[0]) + float32(size.width) * 0.5'f32 - mapHalf()
      z = float32(origin[1]) + float32(size.depth) * 0.5'f32 - mapHalf()
      centre = vec3(x, surfaceHeight(x, z), z)
      name = BuildingProps[kind]
      tint =
        if valid:
          vec4(0.55, 0.95, 0.65, 0.42)
        else:
          vec4(0.95, 0.28, 0.22, 0.42)
    buildingArt.buildingPack(options.playerSlot - 1).drawProp(
      name,
      centre,
      0.0'f32,
      BuildingScale,
      viewProjection,
      tint
    )

  proc updateTerrainVision() {.measure.} =
    ## Uploads the selected team's softened visible and explored terrain.
    if terrainVisionMode == viewMode and
      (viewMode == 0 or terrainVisionTick == run.world.tick):
        return
    terrainVisionTick = run.world.tick
    terrainVisionMode = viewMode
    var values = newSeq[uint8](run.world.map.side * run.world.map.side)
    if viewMode == 0:
      for value in values.mitems:
        value = 255
      uploadTerrainVisibility(values, int(run.world.map.side))
    else:
      let player = viewMode - 1
      for y in 0 ..< run.world.map.side:
        for x in 0 ..< run.world.map.side:
          let index = run.world.map.tileIndex(x, y)
          values[index] =
            if run.world.visible(player, x, y): 255
            elif run.world.explored(player, x, y): 48
            else: 0
      uploadTerrainVisibility(
        blurVisibility(values, run.world.map.side, run.world.map.side),
        int(run.world.map.side)
      )

  proc harvestAnchor(site: HarvestSite): Vec3 =
    if site.kind == MineSparks:
      let index = run.world.buildingIndex(site.id)
      return buildingCentre(run.world.buildings[index]) +
        vec3(0, 0.30'f32, buildingArt.heights[GoldMineBuilding] / 1.4'f32)
    let x = site.tilePoint.x - mapHalf()
    let z = site.tilePoint.y - mapHalf()
    vec3(x, surfaceHeight(x, z) + 1.1'f32, z)

  proc drawWorldBars(
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      dt: float32
  ) =
    ## Always draws owner-colored health bars above visible living units.
    damageTrails.beginFrame()
    worldBarRenderer.clear()
    for unit in run.world.units:
      if not shownUnit(unit) or unit.state == UnitDying or unit.hp <= 0:
        continue
      let
        maximum = max(unitOf(unit.owner, unit.kind).hp, 1'i32).float32
        health = unit.hp.float32
        delayed = damageTrails.delayedValue(
          unit.id,
          health,
          maximum,
          dt
        )
        anchor = renderPoint(unit) +
          vec3(0, UnitHeights[unit.kind] + 0.32'f32, 0)
        width = 0.82'f32 + UnitHeights[unit.kind] * 0.18'f32
        bars = [WorldResourceBar(
          value: health,
          maximum: maximum,
          delayedValue: delayed,
          height: 0.1'f32,
          color: teamColors[unit.owner],
          showDamageTrail: true
        )]
      worldBarRenderer.addResourceBars(anchor, width, bars)
    damageTrails.finishFrame()
    addPlayerNames()
    worldBarRenderer.draw(
      viewProjection,
      cameraRight,
      cameraUp,
      sk.atlasTextureId()
    )

  proc particleTargetPosition(id: int32): tuple[
      found: bool,
      position: Vec3
  ] =
    ## Returns the visible presentation center of one combat target.
    if id.isUnitId:
      let index = run.world.unitIndex(id)
      if index >= 0 and shownUnit(run.world.units[index]):
        let unit = run.world.units[index]
        return (
          true,
          renderPoint(unit) +
            vec3(0, UnitHeights[unit.kind] * 0.55'f32, 0)
        )
    elif id.isBuildingId:
      let index = run.world.buildingIndex(id)
      if index >= 0 and shownBuilding(run.world.buildings[index]):
        return (
          true,
          buildingCentre(run.world.buildings[index]) + vec3(0, 0.8'f32, 0)
        )

  proc expectedTowerTargets(): Table[int32, int32] =
    ## Predicts this tick's tower choices from the pre-tick simulation state.
    let nextTick = run.world.tick + 1
    for structure in run.world.buildings:
      let stats = BuildingTable[structure.kind]
      if stats.damage <= 0 or structure.state != BuildingComplete or
          structure.cooldown > 0 or
          (nextTick + structure.id) mod TowerStagger != 0:
        continue
      var
        target = NoEntity
        best = int32.high
      for unit in run.world.units:
        if not run.world.atWar(structure.owner, unit.owner) or
            unit.state == UnitDying or
            unit.state == UnitInMine:
          continue
        var distance = int32.high
        for y in int32(structure.origin.y) ..<
            int32(structure.origin.y) + structure.footprint.depth:
          for x in int32(structure.origin.x) ..<
              int32(structure.origin.x) + structure.footprint.width:
            distance = min(
              distance,
              tileDistance(unit.tile, tile2(x, y))
            )
        if distance > stats.rangeTiles:
          continue
        if distance < best or
            (distance == best and unit.id < target):
          best = distance
          target = unit.id
      if target != NoEntity:
        result[structure.id] = target

  proc emitTickParticles(
      oldUnitCooldowns: Table[int32, int32],
      towerTargets: Table[int32, int32]
  ) =
    ## Emits each unit and tower attack exactly once after its simulation tick.
    for unit in run.world.units:
      if not shownUnit(unit) or unit.state != UnitAttacking:
        continue
      let stats = unitOf(unit.owner, unit.kind)
      if unit.cooldown != stats.cooldownTicks or
          oldUnitCooldowns.getOrDefault(unit.id, -1) == unit.cooldown:
        continue
      let target = particleTargetPosition(unit.targetId)
      if not target.found:
        continue
      let origin = renderPoint(unit) +
        vec3(0, UnitHeights[unit.kind] * 0.62'f32, 0)
      case unit.kind
      of ArcherUnit:
        particles.emitParticleProjectile(
          ArrowWake,
          CombatSparks,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 17.0'f32,
            0.08'f32,
            0.42'f32
          ),
          owner = unit.owner
        )
      of MageUnit, ClericUnit:
        particles.emitParticleProjectile(
          MagicBolt,
          MagicBurst,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 12.0'f32,
            0.12'f32,
            0.5'f32
          ),
          owner = unit.owner
        )
      of CatapultUnit, SummonUnit:
        particles.emitParticleProjectile(
          Fireball,
          FireBurst,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 13.0'f32,
            0.14'f32,
            0.52'f32
          ),
          owner = unit.owner
        )
      of PeonUnit, SoldierUnit, KnightUnit:
        particles.emitParticleBurst(
          CombatSparks, target.position, owner = unit.owner)
    for structure in run.world.buildings:
      if not shownBuilding(structure) or structure.id notin towerTargets:
        continue
      let stats = BuildingTable[structure.kind]
      if structure.cooldown != stats.cooldownTicks:
        continue
      let target = particleTargetPosition(towerTargets[structure.id])
      if not target.found:
        continue
      let origin = buildingCentre(structure) +
        vec3(0, buildingArt.heights[structure.kind] * 0.7'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target.position,
        clamp(
          (target.position - origin).length / 13.0'f32,
          0.14'f32,
          0.52'f32
        ),
        owner = structure.owner
      )

  ## Frame

  var
    lastFrameTime = epochTime()
  const Step = 1.0'f32 / float32(TickRate)

  proc advanceRenderedMatch(packet = RoomMessage()) =
    ## Advances one tick and converts its combat transitions into particles.
    var oldUnitCooldowns: Table[int32, int32]
    for unit in run.world.units:
      oldUnitCooldowns[unit.id] = unit.cooldown
    let towerTargets = expectedTowerTargets()
    captureUnitPoses()
    if network == nil: advanceGame()
    else:
      network.applyPacket(packet)
      observeHumanCommunication(network, packet)
    feedLvdActions(observeTick = true)
    emitTickParticles(oldUnitCooldowns, towerTargets)
    if network == nil: captureCheckpoint()

  when defined(takeScreenshot):
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"):
      cameraTarget.x = getEnv("CAM_X").parseFloat.float32 - mapHalf()
    if existsEnv("CAM_Z"):
      cameraTarget.z = getEnv("CAM_Z").parseFloat.float32 - mapHalf()
    if existsEnv("VIEW_MODE"):
      viewMode = int32(getEnv("VIEW_MODE").parseInt)
    if existsEnv("SHOW_TILES"):
      showTiles = getEnv("SHOW_TILES").parseBool
    if existsEnv("SIM_SECONDS"):
      let wanted = int32(getEnv("SIM_SECONDS").parseFloat * TickRate.float64)
      while run.world.tick < wanted and
          run.world.tick < run.maximumTicks and not run.world.over:
        advanceGame()
      sceneDirty = true
    if primaryId == NoEntity:
      for structure in run.world.buildings:
        if structure.owner == LightPlayer and
            structure.kind == TownHallBuilding and
            structure.state != BuildingDying:
          primaryId = structure.id
          break
      selectedIds.setLen(0)
      if primaryId != NoEntity:
        selectedIds.add primaryId
      for unit in run.world.units:
        if selectedIds.len >= 10:
          break
        if unit.owner == LightPlayer and
            unit.state notin {UnitDying, UnitInMine}:
          selectedIds.add unit.id
    var screenshotFrame = 0

  var
    viewingClock: ViewingClock
    cameraSeekSerial = -1
    networkPresentation: NetworkPresentation

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime, Step)
      viewingDt = viewingClock.viewingDelta(window)
      viewingSeeking = transport.targetTick >= 0 or transport.restoreTick >= 0
      if not transport.playing or viewingSeeking:
        viewingDt = 0
      if cameraSeekSerial != transport.seekSerial:
        actionCam.resetDirector(transport.automaticSeek)
        cameraSeekSerial = transport.seekSerial
      sk.uiScale = gameUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      let gameplayBindings = inputBindings
      inputBindings = maskShortcutBindings(gameplayBindings,
        shortcutHeldButtons + shortcutFrameButtons)
      profileBlock "camera":
        updateCamera(dt)
      inputBindings = gameplayBindings
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        else: int32(run.replayPlayer.data.hashes.len)
      transport.sync(run.world.tick, recorded, run.world.over)
      if network != nil:
        connection.stats.tickRate = int(TickRate)
        connection.pump()
        if network.reopenedLobby():
          leaveMatch = true
          return
        if quitToMenu:
          if network.client.snapshot.room.len == 0:
            leaveMatch = true
          elif not leaveRequested and network.client.snapshot.phase in {rooms.Ended, Desynced}:
            network.client.send(RoomMessage(kind: LeaveRoom))
            leaveRequested = true
        transport.playing = not network.finished and network.client.snapshot.phase == rooms.Playing
        transport.speedIndex = 0
        run.historyPlayback = false
        networkPresentation.startFrame(dt)
        try:
          network.flushSubmissions()
          var packet: RoomMessage
          let started = epochTime()
          while not network.finished and connection.takeTick(packet, int(TickRate)):
            advanceRenderedMatch(packet)
            inc connection.stats.playedTicks
            networkPresentation.appliedTick()
            if epochTime() - started > 0.012: break
        except RoomsError as error:
          network.abort(error.msg)
        connection.pump()
        transport.sync(run.world.tick, run.world.tick, run.world.over)
      else:
        let restoreTick = transport.takeRestore()
        if restoreTick >= 0:
          restoreTo(restoreTick)
          transport.sync(run.world.tick, recorded, run.world.over)
        feedLvdActions(observeTick = true)
        transport.startFrame(dt, TickRate)
        let frameStart = epochTime()
        run.historyPlayback = transport.inHistory
        profileBlock "simulate":
          while transport.shouldTick(frameStart):
            if atLiveTickCap(run.world.tick, run.maximumTicks, transport.live):
              break
            run.historyPlayback = transport.inHistory
            advanceRenderedMatch()
            let recordedNow =
              if run.recorder != nil: int32(run.recorder.data.hashes.len)
              else: int32(run.replayPlayer.data.hashes.len)
            transport.sync(run.world.tick, recordedNow, run.world.over)
      let active = simulationActive(transport)
      harvesting.updateHarvest(run.world, dt, viewer = -1, paused = not active)
      currentSight = run.world.renderVisibilityValues(viewMode, CurrentSightMask)
      pruneSelection()
      frameAlpha =
        if network != nil:
          networkPresentation.frameAlpha(
            connection.playback, connection.stats, networkTime(), int(TickRate))
        elif active:
          clamp(transport.accumulator / Step, 0.0'f32, 1.0'f32)
        else:
          0.0'f32
      targetFlash.advanceTargetFeedback(dt)
      if active:
        particles.advanceParticles(dt)
        clickMarks.advanceClickMarks(dt)
        attackClickMarks.advanceClickMarks(dt)
      inc framesSinceRebake
      if run.world.terrainEdits.len != placedEditCount or
          buildingKey() != placedBuildingKey:
        sceneDirty = true
      if sceneDirty and
        (showTiles or buildingKey() != placedBuildingKey or framesSinceRebake >= RebakeFrameGap):
          profileBlock "rebake":
            rebakeScene()
      if showTiles and edgesDirty:
        updateTerrainEdges(liveWalkable)
        edgesDirty = false
      feedLvdActions()
      actionCam.direct(
        cameraTarget, cameraDistance, viewingDt,
        run.world.over or transport.tick >= transport.timelineEnd,
        transport.repeating,
        window.size.x.float32 / max(window.size.y.float32, 1),
        RtsFollowLift
      )
      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        view = cameraView()
        projection = perspective(45.0'f32, aspect, 0.1'f32, 1000.0'f32)
        viewProjection = projection * view
        cameraForward = normalize(cameraTarget - cameraEye)
        barCameraRight = normalize(cross(cameraForward, vec3(0, 1, 0)))
        barCameraUp = normalize(cross(barCameraRight, cameraForward))
      inputBindings = maskShortcutBindings(gameplayBindings,
        shortcutHeldButtons + shortcutFrameButtons)
      if matchMenu == HiddenMatchMenu and window.focused and not bindingCapture and
          not humanCommunicationBlocksGameplay():
        updateWorldSelection(viewProjection)
        updatePlayerOrder(viewProjection)
      else:
        cancelGameplayGestures()
      inputBindings = gameplayBindings
      shortcutFrameButtons = {}
      profileBlock "drawWorld":
        # Match GotA's short palette fades and fixed light direction.
        scene.toon.setArenaHour(
          clockHour(float32(run.world.tick) + frameAlpha, TickRate))
        setEnvironmentPalette(scene.toon)

        profileBlock "prepare unit poses":
          var count = 0
          for unit in run.world.units:
            if not shownUnit(unit):
              continue
            let
              model = renderUnitModel(unit, unitModels[unit.owner][unit.kind])
              clip = renderUnitClip(
                unit, model, unitClips[unit.owner][unit.kind][renderAnimation(unit)]
              )
            var animTime = unit.woodAnimationTime(
              renderTime(unit.animationTicks), frameAlpha
            )
            # Hold one-shot clips at their final pose instead of looping.
            if unit.animation == DeathAnimation or
                unit.animation == VictoryAnimation:
              animTime = min(animTime, clipDuration(model, clip))
            if count == unitPoses.len:
              unitPoses.add CharacterPose()
            scene.prepareCharacter(
              unitPoses[count],
              model,
              renderPoint(unit),
              renderFacing(unit),
              clip,
              animTime
            )
            inc count
          unitPoses.setLen(count)

        proc drawWorldUnits() {.measure.} =
          ## Reuses each unit's pose for both shadow maps and the main view.
          for pose in unitPoses.mitems:
            scene.drawCharacter(pose)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          scene.sunDepthPass = true
          drawWorldUnits()
          scene.sunDepthPass = false
        when not defined(emscripten):
          glEnable(GL_MULTISAMPLE)
        glClearColor(0.05, 0.06, 0.09, 1.0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        scene.toon.drawBackground()
        updateTerrainVision()
        drawTerrain(viewProjection, showTiles)
        beginCharacters(scene, window, view, projection, cameraEye)
        drawWorldUnits()
        finishCharacters(scene)
        drawSelectedOutline(view, projection, viewProjection)
        drawTargetOutline(view, projection, viewProjection)
        drawBuildGhost(viewProjection)
        drawWater(
          viewProjection,
          cameraEye,
          opacity = 0.5'f,
          highlightOpacity = 0.0'f
        )
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward,
          (if viewMode == 0: @[] else: currentSight),
          run.world.map.side.int, vec2(-mapHalf()), visibilityPadding = 5,
          viewer = viewMode - 1
        )
        harvestBars.clear()
        harvestBars.addHarvestBillboards(harvesting, run.world, -1, harvestAnchor)
        harvestBars.draw(viewProjection, barCameraRight, barCameraUp)
        clickMarks.drawClickMarks(viewProjection)
        attackClickMarks.drawClickMarks(viewProjection)
        if lineGesture.active and lineGesture.dragging:
          worldShapes.clear()
          let color = orderFeedbackColor(lineGesture.attackMove)
          var strokePoints: seq[Vec3]
          for point in lineGesture.stroke:
            let x = point.x.float32 - mapHalf()
            let z = point.y.float32 - mapHalf()
            strokePoints.add vec3(x, surfaceHeight(x,z) + 0.10'f32, z)
          worldShapes.addPolyline(strokePoints, color, 0.035'f32)
          for target in lineGesture.targets:
            let point = target.destinationPoint()
            let x = point.x.float32 - mapHalf()
            let z = point.y.float32 - mapHalf()
            worldShapes.addCircle(vec3(x, surfaceHeight(x,z) + 0.14'f32, z),
              0.30'f32, color)
          worldShapes.draw(viewProjection)
        if showPaths:
          worldShapes.clear()
          for unit in run.world.units:
            if unit.id == 0 or unit.state == UnitDying or not shownUnit(unit):
              continue
            if unit.pathIndex >= int32(unit.path.len):
              continue
            let color = teamColors[unit.owner]
            var points: seq[Vec3]
            let now = renderPoint(unit)
            points.add vec3(now.x, now.y + 0.2'f32, now.z)
            for i in int(unit.pathIndex) ..< unit.path.len:
              let tile = unit.path[i]
              let xz = tileCentreXZ(tile)
              points.add vec3(
                xz.x,
                surfaceHeight(xz.x, xz.y) + 0.2'f32,
                xz.y
              )
            if points.len >= 2:
              worldShapes.addPolyline(points, color)
          worldShapes.draw(viewProjection)
        drawWorldBars(
          viewProjection,
          barCameraRight,
          barCameraUp,
          dt
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
        let beforeHud = transport
        if matchMenu == HiddenMatchMenu:
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
            teamColors,
            if connection != nil: connection.stats else: nil
          )
          if attackMoveArmed:
            if pendingBuild >= 0:
              attackMoveArmed = false
            else:
              let at = vec2(max(12.0'f, window.size.x.float32 / sk.uiScale / 2 - 220), 78)
              sk.drawRect(at, vec2(440, 40), rgbx(40, 8, 8, 225))
              sk.menuLabel("ATTACK: click or right-drag / Shift queues / Esc cancels", at + vec2(8, 4), 424)
          drawSelectionBox(
            sk,
            window,
            selectionPressPosition,
            selectionStarted
          )
        if network != nil: transport = beforeHud
        if matchMenu != HiddenMatchMenu:
          resetHudTooltips()
          sk.pushLayer(PopupsLayer)
          let view = window.size.vec2 / sk.uiScale
          sk.drawRect(vec2(0), view, rgbx(0, 0, 0, 170))
          let origin = (view - vec2(if matchMenu == MatchSettings: 720 else: 464,
            if matchMenu == MatchSettings: 700 else: 440)) * 0.5'f
          sk.lobbyPanel(origin - vec2(24),
            vec2(if matchMenu == MatchSettings: 768 else: 512,
              if matchMenu == MatchSettings: 748 else: 488))
          try:
            if quitToMenu:
              sk.menuLabel("Leaving match...", origin, 464)
            elif matchMenu == MatchSettings:
              if sk.lvdSettingsPanel(window, preferences, "Polyworld LvD", origin):
                matchMenu = PauseMenu
            else:
              let paused = if network == nil: not transport.playing
                else: network.client.snapshot.flag
              let activeMatch = network == nil or
                network.client.snapshot.phase in {rooms.Playing, Waiting}
              var controller = network == nil
              if network != nil:
                for seat in network.client.snapshot.seats:
                  if seat.owner == network.client.participant: controller = true
              sk.menuLabel(if matchResultsVisible(): "Match ended"
                elif paused: "Match paused" else: "Match running", origin, 464)
              if sk.lobbyButton(if matchResultsVisible(): "View results" else: "Return to game",
                origin + vec2(0, 52), 464):
                matchMenu = HiddenMatchMenu
              if sk.lobbyButton(if paused: "Resume match" else: "Pause match",
                origin + vec2(0, 108), 464,
                enabled = controller and activeMatch and not matchResultsVisible()):
                if network == nil: transport.togglePlay()
                else:
                  network.client.send(RoomMessage(kind: PauseMatch,
                    match: network.client.match, flag: not paused))
              if sk.lobbyButton("Settings", origin + vec2(0, 164), 464):
                matchMenu = MatchSettings
              if network == nil or network.client.snapshot.phase in {rooms.Ended, Desynced, Lobby}:
                if sk.lobbyButton(if network == nil: "Return to Home" else: "Return to lobby",
                  origin + vec2(0, 220), 464):
                  leaveMatch = returnToMatchLobby(network)
              if network != nil and sk.lobbyButton("Quit to main menu",
                origin + vec2(0, if activeMatch: 220 else: 276), 464):
                quitToMenu = true
                if network == nil: leaveMatch = true
                elif controller and activeMatch:
                  network.abort("Match ended by a player quitting to the main menu")
                else:
                  network.client.send(RoomMessage(kind: LeaveRoom))
                  leaveRequested = true
              sk.menuLabel(if network == nil: "Use Pause match to stop the game."
                else: "Quitting as a player ends the match for everyone.",
                origin + vec2(0, 332), 464)
              sk.menuLabel("Drag: select group / Shift: add / Ctrl+A: all units",
                origin + vec2(0, 368), 464)
              sk.menuLabel("Right drag: formation / A: attack / Shift: queue",
                origin + vec2(0, 404), 464)
          except CatchableError as error:
            saveError = error.msg
          if saveError.len > 0: sk.menuLabel(saveError, origin + vec2(0, 340), 464)
          sk.popLayer()
        sk.endUi()
        if matchMenu == HiddenMatchMenu:
          drawStatsOverlay(sk, window, teamColors)
        # Silky ends rune capture when no editable field was submitted. Restore
        # chat capture after ALL UI passes, without interfering with Settings.
        if matchMenu == HiddenMatchMenu:
          window.runeInputEnabled = humanCommunicationTyping() and window.focused
        if humanCommunicationBlocksGameplay(): cancelGameplayGestures()
      finishHumanCommunicationFrame()
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          3,
          "light_vs_dark.png"
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

  window.onButtonPress = proc(button: Button) =
    if bindingCapture: return
    if matchMenu == HiddenMatchMenu and humanCommunicationKey(button):
      shortcutState.resetShortcut()
      cancelGameplayGestures()
      pendingBuild = -1
      attackMoveArmed = false
      window.runeInputEnabled = humanCommunicationTyping()
      return
    if matchMenu == HiddenMatchMenu and humanCommunicationBlocksGameplay():
      cancelGameplayGestures()
      return
    # Combat owns its configured attack key whenever eligible units are selected,
    # even with Units open (whose Archer command defaults to A).
    if matchMenu == HiddenMatchMenu and playerMode() and
        AttackMoveInput.matches(button) and not window.scaleModifier and
        not window.actionDown(ControlInput) and
        not window.buttonDown[KeyLeftAlt] and not window.buttonDown[KeyRightAlt] and
        run.world.armSelectedAttackMove(options.playerSlot - 1, selectedIds):
      shortcutState.cancelShortcut()
      selectionStarted = false
      minimapPanning = false
      return
    let key = shortcutKey(button)
    if key != '\0':
      let matched = shortcutState.pressShortcut(currentShortcuts, key, epochTime(),
        gameplay = matchMenu == HiddenMatchMenu and playerMode(),
        modified = window.scaleModifier or window.actionDown(ControlInput) or
          window.buttonDown[KeyLeftAlt] or window.buttonDown[KeyRightAlt])
      if matched.consumed:
        if matched.action >= 0:
          commandTab = if ShortcutAction(matched.action) <= BuildBlacksmithShortcut: 0 else: 1
        elif button == KeyB: commandTab = 0
        elif button == KeyT: commandTab = 1
        shortcutHeldButtons.incl button
        shortcutFrameButtons.incl button
        if matched.action >= 0 and run.world.performShortcut(options.playerSlot - 1,
            selectedIds, ShortcutAction(matched.action)):
          selectionStarted = false
          minimapPanning = false
          lineGesture.cancelLine()
          rightOrderStarted = false
        return
    if window.scaleKey(button, preferences, sk.uiScale, "Polyworld LvD"): return
    if MenuInput.matches(button):
      if lineGesture.active:
        lineGesture.cancelLine()
        rightOrderStarted = false
        attackMoveArmed = false
        return
      rightOrderStarted = false
      if matchMenu == HiddenMatchMenu and (pendingBuild >= 0 or attackMoveArmed):
        pendingBuild = -1
        attackMoveArmed = false
        return
      matchMenu = if matchMenu == HiddenMatchMenu: PauseMenu
        elif matchMenu == MatchSettings: PauseMenu else: HiddenMatchMenu
      if matchMenu != HiddenMatchMenu:
        resetHudTooltips()
        cancelGameplayGestures()
      return
    if FullscreenInput.matches(button):
      window.setFullscreen(not window.isFullscreen)
      return
    if handleChromeKey(button): return
    if matchMenu != HiddenMatchMenu: return
    if window.scaleModifier or window.actionDown(ControlInput) or
        window.buttonDown[KeyLeftAlt] or window.buttonDown[KeyRightAlt]:
      return
    if playerMode() and button in {KeyB, KeyT}:
      commandTab = if button == KeyB: 0 else: 1
      shortcutHeldButtons.incl button
      shortcutFrameButtons.incl button
      return
    if AttackMoveInput.matches(button) and not window.actionDown(ControlInput) and
        not window.scaleModifier:
      if playerMode() and run.world.armSelectedAttackMove(options.playerSlot - 1, selectedIds):
        selectionStarted = false
        minimapPanning = false
      return
    if PauseInput.matches(button):
      if network == nil: transport.togglePlay()
    elif CameraInput.matches(button): actionCam.toggle(followSelection)
    elif ShadingInput.matches(button): scene.toggleShading()
    elif StopInput.matches(button):
      lineGesture.cancelLine()
      rightOrderStarted = false
      if playerMode():
        let player = options.playerSlot - 1
        for id in selectedIds:
          if run.world.unitOwner(id) == player or
              run.world.buildingOwner(id) == player:
            queueCancel(player, id)
        pendingBuild = -1
        attackMoveArmed = false
    elif button == KeyE: showTiles = not showTiles
    elif button == KeyV and not playerMode():
      viewMode = (viewMode + 1) mod int32(run.world.players.len + 1)

  window.onButtonRelease = proc(button: Button) =
    humanCommunicationRelease(button)
    shortcutState.releaseShortcut(shortcutKey(button))
    shortcutHeldButtons.excl button

  window.onRune = proc(rune: Rune) =
    if matchMenu == HiddenMatchMenu:
      discard humanCommunicationRune(rune)

  window.onFocusChange = proc() =
    if not window.focused:
      resetHudTooltips()
      cancelHumanCommunicationInput()
      shortcutState.resetShortcut()
      shortcutHeldButtons = {}
      shortcutFrameButtons = {}
      cancelGameplayGestures()
      window.runeInputEnabled = false

  while not window.closeRequested and not leaveMatch:
    pollEvents()
    waitForDisplay()
  window.onFrame = nil
  window.onButtonPress = nil
  clearPlayerCommands()
  window.onButtonRelease = nil
  shortcutState.resetShortcut()
  endShortcutEditing()
  saveRecording()
  clickMarks.closeClickMarks()
  attackClickMarks.closeClickMarks()
  worldShapes.closeShapeRenderer()
  worldBarRenderer.closeWorldBarRenderer()
  selectionOutline.closeSelectionOutline()
  particles.closeParticles()
  harvestBars.closeWorldBarRenderer()
  finishGameProfile()
  result = quitToMenu
