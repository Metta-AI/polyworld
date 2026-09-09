import
  std/[math, os, osproc, strformat, strutils, tables, times, wordwrap],
  bumpy, chroma, opengl, silky, vmath,
  polyworld/[characters, common, pathing, quadterrain, shapes, shadows,
    terrainsurfaces, toon, viewers, visions],
  buildings, edits, mapfiles, maps, sim

const
  RepositoryRoot = currentSourcePath().parentDir.parentDir.parentDir
  BuildCompiler = getCurrentCompilerExe()
  EditorTitle {.strdefine.} = "GotA Map Editor"
  PanelWidth = 400
  PanelHeaderHeight = 42
  PanelCloseSize = 30
  DefaultMapPath {.strdefine.} =
    "examples/gods_of_the_arena/maps/arena.json"
  FortTextures = ["mossy-building-stone-1", "dry-stacked-stone-1"]
  LevelColors = [
    rgbx(65, 152, 205, 115), rgbx(127, 164, 88, 115),
    rgbx(218, 184, 88, 115), rgbx(225, 134, 87, 115),
    rgbx(174, 127, 215, 115)
  ]

type
  EditorTab = enum SculptTab, BuildTab, InspectTab, FileTab
  PendingAction = enum NoAction, LoadAction, GenerateAction, QuitAction
  Pick = object
    hit: bool
    x, z: int
  Editor = object
    window: Window
    sk: Silky
    shapes: ShapeRenderer
    history: EditHistory
    brush: MapBrush
    pack: PropPack
    scene: CharacterScene
    godModels: array[2, CharacterModel]
    buildingKind: BuildingKind
    team, lane, tier, rotation, selected, wallRadius, wallHeight: int
    lastSmooth: float64
    tab: EditorTab
    pending: PendingAction
    level, radius, material, seed, generatorSeed: int
    name, path, documentPath, status: string
    issues: seq[string]
    dirty, needsBake, showEdges, showLevels, showLanes: bool
    closeArmed, quitRequested: bool
    dragging, rotating, panning: bool
    start, previous, hover, pathStart: Pick
    route: seq[Vec3]
    walker: float32
    vision: seq[uint8]
    visionHeights, visionBlockers: seq[int16]
    yaw, pitch, distance: float32
    target, eye, right, up: Vec3
    lastTime, lastBake: float64
    compiler: Process
    playProcess: Process
    playMapPath: string
    frame: int

proc prepareBuildings() =
  ## Converts generated structures to editable placements when opening a map.
  ensureWallLayer()
  computeWalkable()
  if not authoredBuildings:
    mapBuildings = defaultBuildings()
    authoredBuildings = true

proc selectedBuilding(app: Editor, pick: Pick): MapBuilding =
  ## Builds the placement preview from the active structure palette.
  MapBuilding(
    kind: app.buildingKind, team: app.team, lane: app.lane, tier: app.tier,
    x: pick.x, z: pick.z, layer: buildingLayerAt(pick.x, pick.z),
    rotation: app.rotation
  )

proc viewProjection(app: var Editor): Mat4 =
  ## Builds the terrain viewport camera independently of the control panel.
  app.eye = app.target + vec3(
    sin(app.yaw) * cos(app.pitch), sin(app.pitch),
    cos(app.yaw) * cos(app.pitch)
  ) * app.distance
  let forward = normalize(app.target - app.eye)
  app.right = normalize(cross(forward, vec3(0, 1, 0)))
  app.up = normalize(cross(app.right, forward))
  let panelPixels = int(PanelWidth.float32 * app.sk.uiScale)
  let aspect = max(app.window.size.x.int - panelPixels, 1).float32 /
    max(app.window.size.y, 1).float32
  perspective(45.0'f, aspect, 0.1'f, 700.0'f) *
    lookAt(app.eye, app.target, vec3(0, 1, 0))

proc rayTriangle(origin, direction, a, b, c: Vec3): float32 =
  ## Returns the positive ray intersection distance or a negative miss.
  let
    edge1 = b - a
    edge2 = c - a
    p = cross(direction, edge2)
    determinant = dot(edge1, p)
  if abs(determinant) < 0.000001:
    return -1
  let
    inverse = 1.0'f / determinant
    offset = origin - a
    u = dot(offset, p) * inverse
    q = cross(offset, edge1)
    v = dot(direction, q) * inverse
  if u < 0 or v < 0 or u + v > 1:
    return -1
  dot(edge2, q) * inverse

proc pickTile(app: var Editor, matrix: Mat4): Pick =
  ## Picks editable ground even beneath trees and shallow water.
  let
    pointer = app.window.mousePos
    panelPixels = int(PanelWidth.float32 * app.sk.uiScale)
    width = max(app.window.size.x.int - panelPixels, 1)
    x = 2.0'f * (pointer.x.int - panelPixels).float32 / width.float32 - 1
    y = 1.0'f - 2.0'f * pointer.y.float32 /
      max(app.window.size.y, 1).float32
    inverse = inverse(matrix)
    nearPoint = inverse * vec4(x, y, -1, 1)
    farPoint = inverse * vec4(x, y, 1, 1)
    origin = nearPoint.xyz / nearPoint.w
    direction = normalize(farPoint.xyz / farPoint.w - origin)
    ground = layers[GroundLayer]
  var nearest = float32.high
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        heights = ground.tiles[z * GridTiles + x].tops.unpack()
        x0 = x.float32 - HalfGrid
        z0 = z.float32 - HalfGrid
        a = vec3(x0, heights[0], z0)
        b = vec3(x0 + 1, heights[1], z0)
        c = vec3(x0, heights[2], z0 + 1)
        d = vec3(x0 + 1, heights[3], z0 + 1)
      for distance in [
        rayTriangle(origin, direction, a, b, c),
        rayTriangle(origin, direction, b, d, c)
      ]:
        if distance > 0 and distance < nearest:
          nearest = distance
          result = Pick(hit: true, x: x, z: z)

proc overUi(app: Editor): bool =
  ## Reserves the sidebar and any moved control window for UI input.
  if app.window.mousePos.x.float32 < PanelWidth.float32 * app.sk.uiScale:
    return true
  for state in subWindowStates.values:
    let pointer = app.window.mousePos.vec2 / app.sk.uiScale
    if state.visible and pointer.x >= state.pos.x and
      pointer.y >= state.pos.y and pointer.x < state.pos.x + state.size.x and
      pointer.y < state.pos.y + state.size.y:
        return true
  false

proc typing(): bool =
  ## Returns whether a text field currently owns ordinary keyboard input.
  for state in textBoxStates.values:
    if state.focused:
      return true
  false

proc invalidate(app: var Editor) =
  ## Marks derived terrain, inspection results, and document state stale.
  app.needsBake = true
  app.dirty = true
  app.route.setLen(0)
  app.pathStart = Pick()
  app.issues.setLen(0)
  app.vision.setLen(0)
  showAllTerrain()

proc rebuild(app: var Editor) =
  ## Rebakes the edited map with the same terrain renderer as the game.
  seed = app.seed
  bakeTerrain()
  app.needsBake = false
  app.lastBake = epochTime()

proc save(app: var Editor, path = ""): bool =
  ## Saves authored terrain and leaves the document dirty if writing fails.
  try:
    let target =
      if path.len > 0: path
      else: app.path
    writeMap(target, captureDocument(app.name, app.seed.int32))
    app.documentPath = target
    app.dirty = false
    app.status = "Saved " & target.extractFilename
    result = true
  except GotaMapError as error:
    app.status = error.msg
    app.tab = FileTab

proc perform(app: var Editor, action: PendingAction) =
  ## Loads, regenerates, or exits after the document discard decision.
  try:
    case action
    of LoadAction:
      let document = readMap(app.path)
      discard installMap(document)
      app.name = document.name
      app.seed = document.seed.int
      app.generatorSeed = app.seed
      app.documentPath = app.path
      app.status = "Loaded " & app.path.extractFilename
    of GenerateAction:
      app.seed = app.generatorSeed
      discard generateMap(app.seed.int32)
      app.name = "Arena " & $app.seed
      app.status = "Generated a starting map."
    of QuitAction:
      app.quitRequested = true
      return
    of NoAction:
      return
    prepareBuildings()
    app.selected = -1
    app.history = EditHistory()
    app.invalidate()
    app.dirty = action == GenerateAction
    app.rebuild()
  except GotaMapError as error:
    app.status = error.msg

proc requestAction(app: var Editor, action: PendingAction) =
  ## Keeps unsaved work until the user chooses save, discard, or cancel.
  if app.history.active:
    if app.history.commitEdit():
      app.invalidate()
    app.dragging = false
  if app.dirty:
    app.pending = action
    if EditorTitle in frameStates:
      frameStates[EditorTitle].scrollPos = vec2(0)
  else:
    app.perform(action)

proc validate(app: var Editor): bool =
  ## Checks all fixed battle lanes and base access after terrain changes.
  if app.needsBake:
    app.rebuild()
  app.issues = arenaIssues()
  result = app.issues.len == 0
  app.status =
    if result: "All three lanes and both bases are reachable."
    else: "Blocked routes: " & $app.issues.len

proc startPlaytest(app: var Editor) =
  ## Saves and compiles the game asynchronously before launching this map.
  if app.compiler != nil:
    return
  if not app.validate():
    app.tab = InspectTab
    return
  if not app.save():
    return
  if app.playProcess != nil:
    if app.playProcess.running:
      app.status = "Close the running playtest before starting another."
      return
    app.playProcess.close()
    app.playProcess = nil
  try:
    app.playMapPath = absolutePath(app.path)
    let compiler =
      if fileExists(BuildCompiler): BuildCompiler
      else: findExe("nim")
    app.compiler = startProcess(
      compiler,
      args = @[
        "c", "--hints:off", "-o:tmp/gota-playtest",
        "examples/gods_of_the_arena/gota.nim"
      ],
      options = {poParentStreams}
    )
    app.status = "Building playtest..."
  except OSError as error:
    app.status = "Could not start compiler: " & error.msg

proc pollPlaytest(app: var Editor) =
  ## Launches the game only when its background compile succeeds.
  if app.compiler == nil or app.compiler.running:
    return
  let exitCode = app.compiler.peekExitCode()
  app.compiler.close()
  app.compiler = nil
  if exitCode != 0:
    app.status = "Playtest build failed. See the terminal output."
    return
  try:
    app.playProcess = startProcess(
      absolutePath("tmp/gota-playtest"),
      args = @[
        "--map", app.playMapPath, "--player",
        "--bot:examples/gods_of_the_arena/players/base.bas:9",
        "--windowSize", "1280x800"
      ],
      options = {poParentStreams}
    )
    app.status = "Playtest opened with your saved map."
  except OSError as error:
    app.status = "Could not start playtest: " & error.msg

proc inspectPath(app: var Editor, picked: Pick) =
  ## Finds a real game path between two clicks and animates a marker on it.
  if app.needsBake:
    app.rebuild()
  if not app.pathStart.hit:
    app.pathStart = picked
    app.status = "Path start set. Click a destination."
    app.route.setLen(0)
    return
  app.route = findPath(
    GroundLayer, app.pathStart.x, app.pathStart.z,
    GroundLayer, picked.x, picked.z
  )
  app.walker = 0
  app.pathStart = Pick()
  app.status =
    if app.route.len == 0: "No walkable route connects those tiles."
    else: "Path found: " & $app.route.len & " tiles."

proc inspectVision(app: var Editor) =
  ## Previews terrain and tree occlusion from the current picked ground tile.
  if not app.hover.hit:
    return
  let cells = GridTiles * GridTiles
  app.visionHeights = newSeq[int16](cells)
  app.visionBlockers = newSeq[int16](cells)
  for i, tile in layers[GroundLayer].tiles:
    app.visionHeights[i] = int16(
      (tile.tops[0].int + tile.tops[1].int +
        tile.tops[2].int + tile.tops[3].int) div 4
    )
    if tile.kind == TreeTile:
      app.visionBlockers[i] = 24
    let wall = layers[WallLayer].tiles[i]
    if wall.exists:
      app.visionHeights[i] = max(app.visionHeights[i], max(wall.tops))
  revealVision(
    app.vision, GridTiles, GridTiles, app.visionHeights, app.visionBlockers,
    [VisionSource(x: app.hover.x.int32, z: app.hover.z.int32, radius: 20,
      eyeHeight: 14)]
  )
  uploadTerrainVisibility(app.vision)
  app.status = "Ground vision preview. Press V again to clear."

proc pickBuilding(app: Editor, matrix: Mat4): int =
  ## Picks the closest projected structure body, including tall towers.
  let
    panelPixels = PanelWidth.float32 * app.sk.uiScale
    width = app.window.size.x.float32 - panelPixels
    height = app.window.size.y.float32
    pointer = app.window.mousePos.vec2
  var nearest = 24.0'f * app.sk.uiScale
  result = -1
  for i, building in mapBuildings:
    let
      bottom = building.buildingPosition()
      size = if building.kind == GodBuilding: 3.0'f
        else: building.buildingScale()
    for sample in 0 .. 4:
      let clip = matrix * vec4(
        bottom + vec3(0, size * sample.float32 / 4, 0), 1
      )
      if clip.w <= 0:
        continue
      let
        ndc = clip.xyz / clip.w
        screen = vec2(
          panelPixels + (ndc.x + 1) * width / 2,
          (1 - ndc.y) * height / 2
        )
        distance = (screen - pointer).length
      if distance < nearest:
        nearest = distance
        result = i

proc selectBuilding(app: var Editor, index: int) =
  ## Loads an existing structure into the palette for moving or rotating.
  if index notin 0 ..< mapBuildings.len:
    return
  let building = mapBuildings[index]
  app.selected = index
  app.buildingKind = building.kind
  app.team = building.team
  app.lane = building.lane
  app.tier = building.tier
  app.rotation = building.rotation
  app.brush = BuildingBrush
  app.status = "Selected. Click terrain to move it. R rotates the preview."

proc placeSelected(app: var Editor) =
  ## Places one structure on a walkable tile and keeps edits atomic.
  let
    building = app.selectedBuilding(app.hover)
    stop = building.buildingStop()
  computeWalkable()
  if not isWalkable(stop.layer, stop.x, stop.z):
    app.status = "Choose open ground. Clear trees or erase walls first."
    return
  for existing in mapBuildings:
    if existing.x == building.x and existing.z == building.z and
      not existing.sameRole(building):
        app.status = "That tile already contains a building."
        return
  app.history.placeBuilding(building)
  for i, existing in mapBuildings:
    if existing.sameRole(building):
      app.selected = i
  app.invalidate()
  app.status = "Placed " & ["tower", "barracks", "god"][building.kind.ord] & "."

proc input(app: var Editor, dt: float32) =
  ## Handles camera gestures, keyboard shortcuts, and undoable paint strokes.
  let
    window = app.window
    ui = app.overUi()
    shortcut = window.buttonDown[KeyLeftControl] or
      window.buttonDown[KeyRightControl] or window.buttonDown[KeyLeftSuper] or
      window.buttonDown[KeyRightSuper]
  if not app.history.active and shortcut and window.buttonPressed[KeyS]:
    discard app.save()
  if app.pending != NoAction:
    if window.buttonPressed[KeyEscape]:
      app.pending = NoAction
    return
  if not typing():
    if window.buttonPressed[KeyEscape]:
      if app.history.active:
        discard app.history.cancelEdit()
        app.dragging = false
        app.needsBake = true
      else:
        app.requestAction(QuitAction)
    if not app.history.active and shortcut:
      if window.buttonPressed[KeyZ]:
        let changed =
          if window.buttonDown[KeyLeftShift] or
            window.buttonDown[KeyRightShift]: app.history.redo()
          else: app.history.undo()
        if changed:
          app.invalidate()
      if window.buttonPressed[KeyY] and app.history.redo():
        app.invalidate()
    for i, key in [Key1, Key2, Key3, Key4, Key5]:
      if not app.history.active and window.buttonPressed[key]:
        app.level = i
        app.brush = ElevationBrush
    if window.buttonPressed[KeyR] and app.brush == BuildingBrush:
      app.rotation = (app.rotation + 90) mod 360
    if window.buttonPressed[KeyV]:
      if app.vision.len > 0:
        app.vision.setLen(0)
        showAllTerrain()
      else:
        app.inspectVision()
  if window.buttonPressed[MouseRight] and not ui:
    app.rotating = true
  if window.buttonPressed[MouseMiddle] and not ui:
    app.panning = true
  if not window.buttonDown[MouseRight]:
    app.rotating = false
  if not window.buttonDown[MouseMiddle]:
    app.panning = false
  let delta = window.mouseDelta.vec2
  if app.rotating:
    app.yaw -= delta.x * 0.006'f
    app.pitch = clamp(app.pitch + delta.y * 0.006'f, 0.25'f, 1.56'f)
  if app.panning:
    app.target -= app.right * delta.x * app.distance * 0.0012'f
    app.target += app.up * delta.y * app.distance * 0.0012'f
    app.target.y = 0
  if not ui and window.scrollDelta.y != 0:
    app.distance = clamp(
      app.distance * pow(0.9'f, window.scrollDelta.y), 12.0'f, 240.0'f
    )
  let matrix = app.viewProjection()
  app.hover =
    if ui: Pick()
    else: app.pickTile(matrix)
  if window.buttonPressed[MouseLeft] and not ui and not shortcut:
    if app.brush == SelectBuildingBrush:
      app.selectBuilding(app.pickBuilding(matrix))
    elif app.brush == EraseBuildingBrush:
      let index = app.pickBuilding(matrix)
      if index >= 0:
        app.history.beginEdit()
        app.history.removeBuilding(index)
        discard app.history.commitEdit()
        app.selected = -1
        app.invalidate()
        app.status = "Removed structure. Undo restores it."
    elif app.hover.hit:
      if app.brush == PathBrush:
        app.inspectPath(app.hover)
      else:
        app.start = app.hover
        app.previous = app.hover
        app.history.beginEdit()
        app.dragging = true
  if app.dragging and window.buttonDown[MouseLeft] and app.hover.hit:
    case app.brush
    of RampBrush, BuildingBrush:
      discard
    of SmoothBrush:
      if epochTime() - app.lastSmooth >= 0.1:
        let count = max(abs(app.hover.x - app.previous.x),
          abs(app.hover.z - app.previous.z))
        for i in 0 .. count:
          let
            x = app.previous.x +
              (app.hover.x - app.previous.x) * i div max(count, 1)
            z = app.previous.z +
              (app.hover.z - app.previous.z) * i div max(count, 1)
          app.history.smoothTerrain(
            x, z, app.radius
          )
        app.lastSmooth = epochTime()
        app.previous = app.hover
        app.invalidate()
    of WallBrush, EraseWallBrush:
      app.history.paintWallStroke(
        app.previous.x, app.previous.z, app.hover.x, app.hover.z,
        app.wallRadius, app.wallHeight, app.team, app.brush == EraseWallBrush
      )
      app.previous = app.hover
      app.invalidate()
    else:
      app.history.paintStroke(
        app.previous.x, app.previous.z, app.hover.x, app.hover.z,
        app.radius, app.brush, app.level, app.material.uint32
      )
      app.previous = app.hover
      app.invalidate()
  if app.dragging and not window.buttonDown[MouseLeft]:
    if app.hover.hit:
      if app.brush == BuildingBrush:
        app.placeSelected()
      elif app.brush == RampBrush:
        if app.history.paintRamp(
          app.start.x, app.start.z, app.hover.x, app.hover.z, app.radius
        ):
          app.invalidate()
          app.status = "Ramp placed. Use Path to check the crossing."
        else:
          app.status = "Ramp needs different heights, length, or clear space."
    discard app.history.commitEdit()
    app.dragging = false
  app.walker += dt * 5

proc tileOverlay(app: var Editor, x, z: int, color: ColorRGBX) =
  ## Draws a tinted tile footprint conforming to the ground surface.
  if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
    return
  let
    tile = layers[GroundLayer].tiles[z * GridTiles + x]
    water = layers[WaterLayer].tiles[z * GridTiles + x]
    x0 = x.float32 - HalfGrid
    z0 = z.float32 - HalfGrid
  var h = tile.tops.unpack()
  for i in 0 .. 3:
    if water.exists:
      h[i] = max(h[i], water.tops[i].float32 / 8)
    if layers.len > WallLayer:
      let wall = layers[WallLayer].tiles[z * GridTiles + x]
      if wall.exists:
        h[i] = max(h[i], wall.tops[i].float32 / 8)
    h[i] += 0.08'f
  app.shapes.addQuad(
    vec3(x0, h[0], z0), vec3(x0 + 1, h[1], z0),
    vec3(x0 + 1, h[3], z0 + 1), vec3(x0, h[2], z0 + 1), color
  )

proc drawOverlays(app: var Editor, matrix: Mat4) =
  ## Shows elevation regions, lane anchors, brush footprint, and test paths.
  app.shapes.clear()
  if app.showLevels:
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let tile = layers[GroundLayer].tiles[z * GridTiles + x]
        let level = clamp((tile.tops[0].int + 12) div 8, 0, 4)
        app.tileOverlay(x, z, LevelColors[level])
  if app.showLanes:
    for stops in battleRoutes():
      for stop in stops:
        app.tileOverlay(stop.x, stop.z, rgbx(240, 204, 73, 200))
      for i in 0 ..< stops.len - 1:
        let
          a = tileCenter(stops[i].layer, stops[i].x, stops[i].z)
          b = tileCenter(stops[i + 1].layer, stops[i + 1].x, stops[i + 1].z)
        app.shapes.addLine(a + vec3(0, 0.2, 0), b + vec3(0, 0.2, 0),
          rgbx(240, 204, 73, 170), 0.14)
  for i, building in mapBuildings:
    let tint = if i == app.selected: rgbx(245, 213, 112, 220)
      elif building.team == 0: rgbx(228, 98, 77, 150)
      else: rgbx(75, 158, 239, 150)
    app.shapes.addSquare(
      building.buildingPosition() + vec3(0, 0.1, 0), 1.5, tint
    )
  if app.hover.hit:
    if app.dragging and app.brush == RampBrush:
      let bounds = rampBounds(
        app.start.x, app.start.z, app.hover.x, app.hover.z, app.radius
      )
      for z in bounds.z0 .. bounds.z1:
        for x in bounds.x0 .. bounds.x1:
          app.tileOverlay(x, z, rgbx(240, 209, 106, 160))
    else:
      let radius =
        if app.brush in {WallBrush, EraseWallBrush}: app.wallRadius
        elif app.brush in {
          BuildingBrush, SelectBuildingBrush, EraseBuildingBrush
        }: 0
        else: app.radius
      for dz in -radius .. radius:
        for dx in -radius .. radius:
          if dx * dx + dz * dz <= radius * radius:
            let
              x = app.hover.x + dx
              z = app.hover.z + dz
              color =
                if app.tab == BuildTab or editableTile(x, z):
                  rgbx(210, 238, 245, 160)
                else: rgbx(236, 75, 65, 180)
            app.tileOverlay(x, z, color)
  for i in 0 ..< app.route.len - 1:
    app.shapes.addLine(
      app.route[i] + vec3(0, 0.3, 0), app.route[i + 1] + vec3(0, 0.3, 0),
      rgbx(76, 224, 212, 230), 0.16
    )
  if app.route.len > 0:
    let i = app.walker.int mod app.route.len
    app.shapes.addSquare(app.route[i] + vec3(0, 0.35, 0), 0.7,
      rgbx(248, 238, 174, 240))
  app.shapes.draw(matrix)

proc drawBuildings(app: var Editor, matrix: Mat4) =
  ## Renders saved structures and a translucent placement preview.
  for building in mapBuildings:
    if building.kind != GodBuilding:
      app.pack.drawProp(
        building.buildingModel(), building.buildingPosition(),
        building.buildingRotation(), building.buildingScale(), matrix
      )
  if app.hover.hit and app.brush == BuildingBrush:
    let preview = app.selectedBuilding(app.hover)
    if preview.kind != GodBuilding:
      app.pack.drawProp(
        preview.buildingModel(), preview.buildingPosition(),
        preview.buildingRotation(), preview.buildingScale(), matrix,
        vec4(0.7, 1, 0.85, 0.45)
      )
  let view = lookAt(app.eye, app.target, vec3(0, 1, 0))
  app.scene.beginCharacters(app.window, view, matrix * inverse(view), app.eye)
  let panelPixels = int(PanelWidth.float32 * app.sk.uiScale)
  glViewport(panelPixels.GLint, 0,
    max(app.window.size.x.int - panelPixels, 1).GLsizei, app.window.size.y)
  for building in mapBuildings:
    if building.kind == GodBuilding:
      let model = app.godModels[building.team]
      app.scene.drawCharacter(
        model, building.buildingPosition(), building.buildingRotation(),
        model.clipIndex("Idle"), app.walker / 5, sizeFactor = 2.6
      )
  if app.hover.hit and app.brush == BuildingBrush and
    app.buildingKind == GodBuilding:
      let
        preview = app.selectedBuilding(app.hover)
        model = app.godModels[preview.team]
      app.scene.drawCharacter(
        model, preview.buildingPosition(), preview.buildingRotation(),
        model.clipIndex("Idle"), 0, tint = color(0.6, 1, 0.7, 1),
        sizeFactor = 2.6
      )

proc drawPending(app: var Editor) =
  ## Presents the unsaved-change decision before any scrollable editor tools.
  let
    sk = app.sk
    window = app.window
    action = app.pending
  text(if action == QuitAction: "Close map editor?" else: "Unsaved map changes")
  text("Save your changes before continuing?")
  group "discard decision":
    box PanelWidth - 35, 32
    layout LeftToRight
    button(if action == QuitAction: "Save and close" else: "Save first"):
      let path = if action == LoadAction: app.documentPath else: app.path
      if app.save(path):
        app.pending = NoAction
        app.perform(action)
    button(if action == QuitAction: "Discard and close" else: "Discard"):
      app.pending = NoAction
      app.perform(action)
    button("Cancel"):
      app.pending = NoAction
  text("Escape cancels and keeps your map open.")
  for line in app.status.wrapWords(46).splitLines():
    text(line)

proc drawPanel(app: var Editor) =
  ## Draws the current decision or the regular map-editing controls.
  let
    sk = app.sk
    window = app.window
  if app.pending != NoAction:
    app.drawPending()
    return
  text(app.name & (if app.dirty: " *" else: ""))
  group "quick actions":
    box PanelWidth - 35, 32
    layout LeftToRight
    button("Save"):
      discard app.save()
    button("Undo"):
      if not app.history.active and app.history.undo():
        app.invalidate()
    button("Redo"):
      if not app.history.active and app.history.redo():
        app.invalidate()
  let oldTab = app.tab
  group "tabs":
    box PanelWidth - 35, 32
    layout LeftToRight
    radioButton("Terrain", app.tab, SculptTab)
    radioButton("Build", app.tab, BuildTab)
    radioButton("Inspect", app.tab, InspectTab)
    radioButton("File", app.tab, FileTab)
  if app.tab != oldTab:
    if app.tab == SculptTab:
      app.brush = ElevationBrush
    elif app.tab == BuildTab:
      app.brush = BuildingBrush
  for line in app.status.wrapWords(46).splitLines():
    text(line)
  case app.tab
  of SculptTab:
    text("Paint tool")
    group "terrain tools":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Level", app.brush, ElevationBrush)
      radioButton("Surface", app.brush, SurfaceBrush)
      radioButton("Ramp", app.brush, RampBrush)
    group "water tools":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Water", app.brush, WaterBrush)
      radioButton("Dry", app.brush, DryBrush)
      radioButton("Smooth", app.brush, SmoothBrush)
    group "forest tools":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Trees", app.brush, TreeBrush)
      radioButton("Clear trees", app.brush, ClearBrush)
    group "collision tools":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Block", app.brush, BlockBrush)
      radioButton("Open", app.brush, OpenBrush)
    text("Elevation (keys 1-5)")
    group "levels":
      box PanelWidth - 35, 32
      layout LeftToRight
      for i in 0 .. 4:
        radioButton("L" & $(i + 1), app.level, i)
    text("Height: " & $(ElevationHeights[app.level].float32 / 8) & " tiles")
    text("Brush radius: " & $app.radius & " tiles")
    scrubber("radius", app.radius, 0, 12, "")
    text("Ramp width: " & $(app.radius * 2 + 1) & " tiles")
    text("Surface")
    group "surfaces one":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Grass", app.material, 0)
      radioButton("Road", app.material, 1)
      radioButton("Rock", app.material, 2)
    group "surfaces two":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Marsh", app.material, 3)
      radioButton("Stone", app.material, 4)
    group "height operations":
      box PanelWidth - 35, 32
      layout LeftToRight
      button("Half height"):
        if not app.history.active:
          app.history.beginEdit()
          discard app.history.scaleHeights(1, 2)
          discard app.history.commitEdit()
          app.invalidate()
          app.status = "All terrain heights halved. Undo restores them."
      button("Double height"):
        if not app.history.active:
          app.history.beginEdit()
          if app.history.scaleHeights(2, 1):
            discard app.history.commitEdit()
            app.invalidate()
            app.status = "All terrain heights doubled. Undo restores them."
          else:
            discard app.history.cancelEdit()
            app.status = "Doubling would exceed the map height limit."
    text("Smooth: drag or hold to soften slopes.")
    text("Ramp: drag between terrace levels.")
    text("Height buttons rescale the whole map.")
  of BuildTab:
    text("Team")
    group "teams":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Red", app.team, 0)
      radioButton("Blue", app.team, 1)
    text("Castle walls")
    group "wall tools":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Draw wall", app.brush, WallBrush)
      radioButton("Erase wall", app.brush, EraseWallBrush)
    text("Wall height: " & $(app.wallHeight.float32 / 8) & " tiles")
    scrubber("wall height", app.wallHeight, 4, 48, "")
    text("Wall width: " & $(app.wallRadius * 2 + 1) & " tiles")
    scrubber("wall width", app.wallRadius, 0, 2, "")
    text("Drag to draw. Erase openings for gates.")
    text("Buildings")
    group "building kinds":
      box PanelWidth - 35, 32
      layout LeftToRight
      button("Tower"):
        app.buildingKind = TowerBuilding
        app.brush = BuildingBrush
      button("Barracks"):
        app.buildingKind = BarracksBuilding
        app.brush = BuildingBrush
      button("God"):
        app.buildingKind = GodBuilding
        app.brush = BuildingBrush
    text("Placing: " & ["Tower", "Barracks", "God"][app.buildingKind.ord])
    if app.buildingKind != GodBuilding:
      text("Lane")
      group "building lanes":
        box PanelWidth - 35, 32
        layout LeftToRight
        radioButton("Top", app.lane, 0)
        radioButton("Middle", app.lane, 1)
        radioButton("Bottom", app.lane, 2)
    if app.buildingKind == TowerBuilding:
      text("Tower tier")
      group "tower tiers":
        box PanelWidth - 35, 32
        layout LeftToRight
        radioButton("Outer", app.tier, 0)
        radioButton("Inner", app.tier, 1)
        radioButton("Gate", app.tier, 2)
    group "building tools":
      box PanelWidth - 35, 32
      layout LeftToRight
      radioButton("Place", app.brush, BuildingBrush)
      radioButton("Select", app.brush, SelectBuildingBrush)
      radioButton("Remove", app.brush, EraseBuildingBrush)
    button("Rotate 90 degrees (R)"):
      app.rotation = (app.rotation + 90) mod 360
    text("Facing: " & $app.rotation & " degrees")
    text("Click to place. Select, then click to move.")
    text("One god and three barracks per team.")
  of InspectTab:
    checkBox("Show elevation colors", app.showLevels)
    checkBox("Show walkable edges", app.showEdges)
    checkBox("Show lane anchors", app.showLanes)
    button("Test a path (two clicks)"):
      app.brush = PathBrush
      app.pathStart = Pick()
      app.status = "Click a start tile, then a destination."
    button("Check all battle routes"):
      discard app.validate()
    button("Playtest saved map"):
      app.startPlaytest()
    text("Point at terrain and press V")
    text("to preview ground vision.")
    for issue in app.issues:
      for line in issue.wrapWords(34).splitLines():
        text(line)
  of FileTab:
    text("Map name")
    let oldName = app.name
    textInput("map name", app.name)
    if oldName != app.name:
      app.dirty = true
    text("JSON path")
    textInput("map path", app.path)
    group "file actions":
      box PanelWidth - 35, 32
      layout LeftToRight
      button("Save JSON"):
        discard app.save()
      button("Load JSON"):
        app.requestAction(LoadAction)
    text("Generator seed: " & $app.generatorSeed)
    scrubber("seed", app.generatorSeed, 1, 999999, "")
    button("Generate starting map"):
      app.requestAction(GenerateAction)
    text("JSON v2, 128 x 128 terrain.")
    text("Heights use exact 1/8 tile units.")
    text("Includes walls and building placements.")
  group "camera buttons":
    box PanelWidth - 35, 32
    layout LeftToRight
    button("Top view"):
      app.pitch = 1.56
      app.yaw = 0
    button("Game view"):
      app.pitch = 0.92
      app.yaw = 0
    button("Fit map"):
      app.target = vec3(0)
      app.distance = 190
  sk.textStyle = "Hud"
  text("Right drag: orbit. Middle drag: pan.")
  text("Wheel: zoom. Ctrl/Cmd S: save.")
  text("Ctrl/Cmd Z: undo. Shift Z: redo.")
  if app.hover.hit:
    text(&"Tile {app.hover.x}, {app.hover.z}")
  sk.textStyle = "Default"

proc drawUi(app: var Editor) =
  ## Draws a fixed dock with an explicit press-and-release close control.
  let
    sk = app.sk
    window = app.window
    closeRect = rect(PanelWidth - PanelCloseSize - 8, 6,
      PanelCloseSize, PanelCloseSize)
    pointer = window.mousePos.vec2 / sk.uiScale
    overClose = pointer.overlaps(closeRect)
  when defined(editorInputTrace):
    if window.buttonPressed[MouseLeft] or window.buttonReleased[MouseLeft]:
      writeFile(TmpRoot & "/gota-editor-input-trace.txt",
        $window.mousePos & " scale=" & $sk.uiScale & " close=" & $overClose &
        " press=" & $window.buttonPressed[MouseLeft] &
        " release=" & $window.buttonReleased[MouseLeft])
  if window.buttonPressed[MouseLeft]:
    app.closeArmed = overClose
  if window.buttonReleased[MouseLeft]:
    let close = app.closeArmed and overClose
    app.closeArmed = false
    if close:
      app.requestAction(QuitAction)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
  sk.beginUi(window, window.size)
  sk.textStyle = "Hud"
  sk.draw9Patch("window.9patch", sk.theme.windowPatch,
    vec2(0), vec2(PanelWidth, window.size.y.float32 / sk.uiScale))
  sk.draw9Patch("header.9patch", sk.theme.headerPatch,
    vec2(6), vec2(PanelWidth - 12, PanelHeaderHeight - 12))
  discard sk.drawText("Hud", EditorTitle, vec2(16, 14),
    sk.theme.defaultTextColor)
  if overClose:
    sk.draw9Patch("header.hover.9patch", sk.theme.headerPatch,
      closeRect.xy, closeRect.wh)
  let iconSize = sk.getImageSize("close")
  sk.drawImage("close", closeRect.xy + (closeRect.wh - iconSize) / 2)
  frame(EditorTitle, vec2(6, PanelHeaderHeight),
    vec2(PanelWidth - 12,
      max(1.0'f, window.size.y.float32 / sk.uiScale - PanelHeaderHeight - 6))):
    app.drawPanel()
  sk.endUi()

proc main() =
  ## Opens the native map editor with an optional authored JSON map path.
  setCurrentDir(RepositoryRoot)
  createDir(TmpRoot)
  var app = Editor(
    name: "Arena 2026", path: DefaultMapPath, documentPath: DefaultMapPath,
    seed: 2026, generatorSeed: 2026,
    level: 1, radius: 2, pitch: 0.92, distance: 190,
    wallHeight: 16, selected: -1,
    status: "Paint terrain, then save and playtest.", lastTime: epochTime()
  )
  when defined(takeScreenshot):
    app.tab = BuildTab
    app.brush = WallBrush
    app.target = vec3(-22, 0, -22)
    app.distance = 105
  let arguments = commandLineParams()
  if arguments.len > 1:
    raise newException(GotaMapError, "Usage: editor [path/to/map.json]")
  if arguments.len == 1:
    app.path = arguments[0]
  if arguments.len == 1 or fileExists(app.path):
    app.documentPath = app.path
    let document = readMap(app.path)
    discard installMap(document)
    app.name = document.name
    app.seed = document.seed.int
    app.generatorSeed = app.seed
  else:
    discard generateMap(app.seed.int32)
    app.dirty = true
  prepareBuildings()
  let builder = newHudAtlas(4096)
  builder.addDefaultFonts()
  builder.write(TmpRoot & "/gota-editor.atlas.png")
  (app.window, app.sk) = initGameWindow(
    EditorTitle, TmpRoot & "/gota-editor.atlas.png", ivec2(1500, 940)
  )
  initTerrain(DenseTrees, GeneratedTerrain, PaintedRocks, FortTextures)
  for i, kind in [RedFortKind, BlueFortKind]:
    let material = (SurfaceNames.len + i).float32
    setTileMaterial(kind.int, material, material, vec3(1), vec3(0.9), 6)
  treeHeight = 6
  treeWidth = 0
  var environment = newToonContext()
  environment.setPalette(paletteAtHour(11))
  setEnvironmentPalette(environment)
  applySunHour(11)
  showAllTerrain()
  app.shapes = initShapeRenderer()
  app.pack = loadPropPack(DataRoot & "/terrain/tower_defense_kit.glb")
  app.scene = newCharacterScene(app.window)
  app.scene.useToonShading()
  app.scene.setToonHour(11)
  for team in 0 .. 1:
    app.godModels[team] = loadCharacterModel(GodModels[team], 1.15)

  app.rebuild()
  while not app.quitRequested:
    pollEvents()
    if app.window.closeRequested:
      app.window.closeRequested = false
      app.requestAction(QuitAction)
    if app.quitRequested:
      break
    let
      now = epochTime()
      dt = clamp(now - app.lastTime, 0.0, 0.1).float32
    app.sk.uiScale = max(1.0'f, min(
      app.window.size.x.float32 / 1500, app.window.size.y.float32 / 940
    ))
    app.lastTime = now
    app.input(dt)
    app.pollPlaytest()
    if app.needsBake and (not app.dragging or now - app.lastBake > 0.18):
      app.rebuild()
    let matrix = app.viewProjection()
    glViewport(0, 0, app.window.size.x, app.window.size.y)
    glClearColor(0.12, 0.16, 0.19, 1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    let panelPixels = int(PanelWidth.float32 * app.sk.uiScale)
    glViewport(panelPixels.GLint, 0,
      max(app.window.size.x.int - panelPixels, 1).GLsizei, app.window.size.y)
    drawTerrain(matrix, app.showEdges)
    drawWater(matrix, app.eye)
    app.drawBuildings(matrix)
    app.drawOverlays(matrix)
    glViewport(0, 0, app.window.size.x, app.window.size.y)
    app.drawUi()
    captureScreenshot(app.window, app.frame, 3, TmpRoot & "/gota-editor.png")
    app.window.presentFrame()
  if app.compiler != nil:
    app.compiler.close()
  if app.playProcess != nil:
    app.playProcess.close()
  app.window.close()

main()
