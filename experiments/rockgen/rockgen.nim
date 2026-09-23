import
  std/[math, os, random, strutils, times],
  bumpy, chroma, gltf, pixie, silky, vmath,
  polyworld/[rockgen, shadows, toon],
  views

const
  ReferencePresets = [4, 5, 6, 3, 2, 1, 0, 7, 8]
  WindowSize = ivec2(1440, 940)
  PanelWidth = 372.0'f
  PanelPosition = vec2(12, 12)
  RowWidth = 330
  UiAtlas = ExperimentDirectory / "../../tmp/rockgen.atlas.png"
  ThemeDirectory = ExperimentDirectory / "../../../polyworld_art/themes/main"

type
  PanelTab = enum
    Shape, Surface, Colors
  Options = object
    preset, seed, frames, fillSubdivisions: int
    yaw, pitch: float32
    screenshot, exportPath, loadPath: string
    gallery, regions, wireframe, noPanel, sheet: bool
  RockApp = object
    sk: Silky
    toon: ToonContext
    settings, built: RockSettings
    geometry: RockGeometry
    materials: RockMaterials
    node, ground: Node
    variants: seq[Node]
    tab: PanelTab
    presetName, status: string
    showPanel, gallery, builtGallery, wireframe, rotating: bool
    regions, builtRegions, orbiting, panning: bool
    yaw, pitch, distance: float32
    target: Vec3
    frame: int
    rng: Rand

proc optionsFromArgs(): Options =
  ## Parses reproducible startup, export, and hidden capture options.
  result.seed = 42
  result.fillSubdivisions = -1
  result.yaw = 0.55'f
  result.pitch = 0.5'f
  try:
    for argument in commandLineParams():
      if argument == "--smoke":
        result.frames = 4
      elif argument == "--gallery":
        result.gallery = true
      elif argument == "--regions":
        result.regions = true
      elif argument == "--wireframe":
        result.wireframe = true
      elif argument == "--no-panel":
        result.noPanel = true
      elif argument == "--sheet":
        result.sheet = true
        result.noPanel = true
        result.frames = 4
      elif argument.startsWith("--preset="):
        result.preset = argument[9 .. ^1].parseInt
      elif argument.startsWith("--seed="):
        result.seed = argument[7 .. ^1].parseInt
      elif argument.startsWith("--frames="):
        result.frames = argument[9 .. ^1].parseInt
      elif argument.startsWith("--fill-subdivisions="):
        result.fillSubdivisions = argument[20 .. ^1].parseInt
        if result.fillSubdivisions notin 0 .. 2:
          raise newException(RockgenError, "Fill subdivisions must be 0 to 2")
      elif argument.startsWith("--yaw="):
        result.yaw = argument[6 .. ^1].parseFloat.float32
      elif argument.startsWith("--pitch="):
        result.pitch = argument[8 .. ^1].parseFloat.float32
      elif argument.startsWith("--screenshot="):
        result.screenshot = argument[13 .. ^1]
      elif argument.startsWith("--export="):
        result.exportPath = argument[9 .. ^1]
      elif argument.startsWith("--load="):
        result.loadPath = argument[7 .. ^1]
      else:
        raise newException(RockgenError, "Unknown argument: " & argument)
  except ValueError:
    raise newException(RockgenError, "Expected a numeric argument: " &
      getCurrentExceptionMsg())
  if result.preset notin 0 .. PresetNames.high or result.frames < 0:
    raise newException(RockgenError, "Preset or frame count is out of range")
  if not (result.yaw >= -Tau and result.yaw <= Tau and
    result.pitch >= -0.2'f and result.pitch <= 1.5'f):
      raise newException(RockgenError, "Camera angle is out of range")
  if result.screenshot.len > 0 and result.frames == 0:
    result.frames = 4

proc geometryKey(settings: RockSettings): RockSettings =
  ## Excludes tint controls from geometry rebuilds.
  result = settings
  result.tint = vec3(0)

proc releaseRocks(app: var RockApp) =
  ## Releases GPU buffers and material textures before replacing nodes.
  app.node.clearFromGpu()
  for node in app.variants:
    node.clearFromGpu()
  app.variants.setLen(0)

proc rebuild(app: var RockApp) =
  ## Rebuilds the selected seed and optional neighboring seed previews.
  app.releaseRocks()
  app.geometry = generateGeometry(app.settings)
  app.node = rockNode(app.geometry, app.materials, app.regions)
  if app.gallery:
    let spacing = app.settings.width + 0.6'f
    for i in [-1, 1]:
      var settings = app.settings
      settings.seed = (settings.seed + i + 1_000_000_001) mod 1_000_000_001
      let node = rockNode(
        generateGeometry(settings),
        app.materials,
        app.regions
      )
      node.pos.x = i.float32 * spacing
      app.variants.add node
  app.built = app.settings
  app.builtGallery = app.gallery
  app.builtRegions = app.regions

proc frameRock(app: var RockApp) =
  ## Fits the whole rock or comparison gallery in the available viewport.
  app.target = (app.geometry.minimum + app.geometry.maximum) * 0.5'f
  let extent = app.geometry.maximum - app.geometry.minimum
  app.distance = max(
    max(extent.y, max(extent.x, extent.z)) * 1.9'f,
    length(extent) * 1.55'f
  )
  if app.gallery:
    app.distance = max(app.distance, (app.settings.width * 3 + 1.2'f) * 1.6'f)

proc mouseOverUi(app: RockApp, window: Window): bool =
  ## Prevents panel controls and floating menus from moving the camera.
  if not app.showPanel:
    return false
  for state in subWindowStates.values:
    if state.visible and window.mousePos.vec2.overlaps(
      rect(state.pos, state.size)):
        return true
  window.mousePos.x.float32 < PanelWidth + 30

proc randomizeSeed(app: var RockApp) =
  ## Chooses a fresh seed while keeping the selected recipe.
  let previous = app.settings.seed
  while app.settings.seed == previous:
    app.settings.seed = app.rng.rand(1_000_000_000)

proc selectPreset(app: var RockApp, index: int) =
  ## Selects a preset with wrapping while preserving the current seed.
  let selected = (index + PresetNames.len) mod PresetNames.len
  app.presetName = PresetNames[selected]
  app.settings = preset(selected, app.settings.seed)
  app.rebuild()
  app.frameRock()

proc stepPreset(app: var RockApp, step: int) =
  ## Advances through the ordered rock presets.
  var index = 0
  for i, name in PresetNames:
    if name == app.presetName:
      index = i
  app.selectPreset(index + step)

proc handleInput(app: var RockApp, window: Window, delta: float32) =
  ## Handles orbit, pan, zoom, and the tree editor's familiar shortcuts.
  if window.buttonPressed[KeyEscape]:
    window.closeRequested = true
  if window.buttonPressed[KeyTab]:
    app.showPanel = not app.showPanel
  if app.sk.buttonPressed[KeyR]:
    app.randomizeSeed()
  if app.sk.buttonPressed[KeyF]:
    app.frameRock()
  if app.sk.buttonPressed[KeyW]:
    app.wireframe = not app.wireframe
  if app.sk.buttonPressed[KeyD]:
    app.regions = not app.regions
  if app.sk.buttonPressed[KeySpace]:
    app.rotating = not app.rotating
  let overUi = app.mouseOverUi(window)
  if not overUi:
    if window.buttonPressed[MouseLeft] or window.buttonPressed[MouseRight]:
      app.orbiting = true
    if window.buttonPressed[MouseMiddle]:
      app.panning = true
  if not window.buttonDown[MouseLeft] and not window.buttonDown[MouseRight]:
    app.orbiting = false
  if not window.buttonDown[MouseMiddle]:
    app.panning = false
  if app.orbiting:
    app.yaw -= window.mouseDelta.x.float32 * 0.008'f
    app.pitch = clamp(
      app.pitch + window.mouseDelta.y.float32 * 0.008'f, -0.2'f, 1.4'f
    )
  if app.panning:
    let
      right = vec3(cos(app.yaw), 0, -sin(app.yaw))
      up = vec3(-sin(app.yaw) * sin(app.pitch), cos(app.pitch),
        -cos(app.yaw) * sin(app.pitch))
      speed = app.distance * 0.0015'f
    app.target -= right * window.mouseDelta.x.float32 * speed
    app.target += up * window.mouseDelta.y.float32 * speed
  if not overUi and window.scrollDelta.y != 0:
    app.distance = clamp(
      app.distance * pow(0.9'f, window.scrollDelta.y), 1.5'f, 100.0'f
    )
  if app.rotating:
    app.yaw += delta * 0.25'f

template control(caption: string, target: untyped, low, high: untyped) =
  ## Draws a labeled scrubber with one evaluation of the target address.
  block:
    let
      label = caption
      field = addr(target)
    when target is float32:
      text(label & ": " & field[].formatFloat(ffDecimal, 2))
    else:
      text(label & ": " & $field[])
    scrubber(label, field[], low, high, "")

proc shapeControls(app: var RockApp, window: Window) =
  ## Exposes proportions and the planes that make broad polygonal faces.
  let sk = app.sk
  checkBox("Remove bottom triangles", app.settings.removeBottom)
  text("Omits the flat ground-contact face.")
  var floorPercent = app.settings.floorCut * 100
  control("Floor (%)", floorPercent, 0.0'f, 90.0'f)
  app.settings.floorCut = floorPercent / 100
  text("Cuts the buried part; leaves an open base.")
  control("Width", app.settings.width, 0.5'f, 8.0'f)
  control("Height", app.settings.height, 0.5'f, 10.0'f)
  control("Depth", app.settings.depth, 0.5'f, 8.0'f)
  control("Side faces", app.settings.sides, 4, 12)
  control("Crown cuts", app.settings.crownCuts, 3, 12)
  control("Irregularity", app.settings.irregularity, 0.0'f, 0.4'f)
  control("Taper", app.settings.taper, -0.3'f, 0.45'f)
  control("Crown slope", app.settings.crown, 0.4'f, 1.6'f)
  control("Shoulder height", app.settings.shoulder, 0.0'f, 0.85'f)
  control("Corner clipping", app.settings.cornerClip, 0.0'f, 0.45'f)
  control("Corner chips", app.settings.chips, 0, 12)
  control("Chip size", app.settings.chipSize, 0.0'f, 0.25'f)
  control("Lean", app.settings.lean, -0.5'f, 0.5'f)

proc surfaceControls(app: var RockApp, window: Window) =
  ## Exposes the coplanar perimeter and optional square texture patches.
  let sk = app.sk
  control("Fill subdivisions", app.settings.fillSubdivisions, 0, 2)
  text("0: fewest triangles / 2: finer surface wash")
  control("Trim width", app.settings.trimWidth, 0.0'f, 0.4'f)
  control("Worn edges", app.settings.trimChance, 0.0'f, 1.0'f)
  control("Detail chance", app.settings.detailChance, 0.0'f, 1.0'f)
  control("Detail size", app.settings.detailSize, 0.15'f, 0.9'f)
  control("Detail offset", app.settings.detailOffset, 0.0'f, 0.6'f)
  text("Detail tiles")
  dropDown(app.settings.detailKind, [Mixed, Cracks, Scuffs])
  control("Face shade variation", app.settings.shadeVariation, 0.0'f, 0.4'f)
  control("Surface wash", app.settings.mottling, 0.0'f, 0.4'f)
  text("Trim, fill, and details share one flat face.")
  text("A detail square replaces part of the fill.")
  text("Orange: trim / teal: fill / pink: detail")

proc colorControls(app: var RockApp, window: Window) =
  ## Tints the supplied gray atlas and adjusts the shared scene lighting.
  let sk = app.sk
  control("Red", app.settings.tint.x, 0.0'f, 1.0'f)
  control("Green", app.settings.tint.y, 0.0'f, 1.0'f)
  control("Blue", app.settings.tint.z, 0.0'f, 1.0'f)
  group "stone colors":
    box RowWidth, 32
    layout LeftToRight
    button "Gray":
      app.settings.tint = vec3(0.86)
    button "Slate":
      app.settings.tint = vec3(0.72, 0.76, 0.88)
    button "Sand":
      app.settings.tint = vec3(0.95, 0.8, 0.6)
  control("Sun azimuth", sunAzimuth, 0.0'f, 360.0'f)
  control("Sun elevation", sunElevation, 10.0'f, 85.0'f)
  checkBox("Cast shadows", sunShadowsEnabled)

proc drawUi(app: var RockApp, window: Window) =
  ## Draws preset, parameter, export, and inspection controls.
  let sk = app.sk
  sk.beginUi(window, window.size)
  if app.showPanel:
    subWindow(
      "Rock generator", app.showPanel, PanelPosition,
      vec2(PanelWidth, window.size.y.float32 - 24)
    ):
      text("ROCKGEN  /  procedural rock lab")
      text($app.geometry.faces.len & " faces   " &
        $(app.geometry.mesh.indices.len div 3) & " triangles   " &
        $app.geometry.details & " details")
      text("Presets")
      block:
        let previous = app.presetName
        dropDown(app.presetName, PresetNames)
        if previous != app.presetName:
          for i, name in PresetNames:
            if app.presetName == name:
              app.selectPreset(i)
      group "preset actions":
        box RowWidth, 32
        layout LeftToRight
        button "Previous Preset":
          app.stepPreset(-1)
        button "Next Preset":
          app.stepPreset(1)
      text("Seed: " & $app.settings.seed)
      button "Randomize Seed":
        app.randomizeSeed()
      checkBox("Compare three seeds", app.gallery)
      group "parameter tabs":
        box RowWidth, 32
        layout LeftToRight
        radioButton("Shape", app.tab, Shape)
        radioButton("Surface", app.tab, Surface)
        radioButton("Colors", app.tab, Colors)
      frame "parameters":
        size(RowWidth, max(120.0'f, window.size.y.float32 - 570))
        case app.tab
        of Shape:
          app.shapeControls(window)
        of Surface:
          app.surfaceControls(window)
        of Colors:
          app.colorControls(window)
      group "file actions":
        box RowWidth, 32
        layout LeftToRight
        button "Save preset":
          try:
            app.settings.saveSettings(CustomPath)
            app.status = "Saved presets/custom.json"
          except RockgenError as error:
            app.status = error.msg
        button "Load":
          try:
            app.settings = loadSettings(CustomPath)
            app.presetName = "Custom"
            app.rebuild()
            app.frameRock()
            app.status = "Loaded presets/custom.json"
          except RockgenError as error:
            app.status = error.msg
        button "Export GLB":
          try:
            let path = ExperimentDirectory / "exports" /
              ("rock-" & $app.settings.seed & ".glb")
            app.settings.exportRock(path)
            app.status = "Exported rock-" & $app.settings.seed & ".glb"
          except RockgenError as error:
            app.status = error.msg
      group "inspection actions":
        box RowWidth, 32
        layout LeftToRight
        checkBox("Face regions", app.regions)
        checkBox("Wireframe", app.wireframe)
      group "camera actions":
        box RowWidth, 32
        layout LeftToRight
        checkBox("Turntable", app.rotating)
        button "Fit":
          app.frameRock()
      text("Drag orbit / middle drag pan / scroll zoom")
      text("R seed / F fit / W wire / D regions / Tab panel")
      if app.status.len > 0:
        text(app.status)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  sk.endUi()

proc drawScene(app: var RockApp, window: Window) =
  ## Renders the rock and ground with the same toon pipeline as Treegen.
  app.ground.pos.y =
    if app.settings.removeBottom or app.settings.floorCut > 0:
      0.025'f
    else:
      0.0'f
  let
    left = (if app.showPanel: PanelWidth.int32 + 28 else: 0'i32)
    width = max(1'i32, window.size.x - left)
    height = max(1'i32, window.size.y)
    eye = app.target + vec3(
      sin(app.yaw) * cos(app.pitch), sin(app.pitch),
      cos(app.yaw) * cos(app.pitch)
    ) * app.distance
  app.toon.view = lookAt(eye, app.target, vec3(0, 1, 0))
  app.toon.proj = perspective(
    42.0'f, width.float32 / height.float32, 0.05'f, 400.0'f
  )
  app.toon.cameraPosition = eye
  updateSunMatrix()
  app.toon.lightDirection = -sunDirection
  sunDepthPasses(window.size):
    app.toon.drawSunDepth(app.node)
    for node in app.variants:
      app.toon.drawSunDepth(node)
  glViewport(left, 0, width, height)
  glClearColor(0.88, 0.87, 0.85, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  app.toon.draw(app.ground)
  if app.wireframe:
    glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
  app.toon.draw(app.node)
  for node in app.variants:
    app.toon.draw(node)
  glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
  glViewport(0, 0, window.size.x, window.size.y)

proc drawSheet(app: var RockApp, window: Window, options: Options) =
  ## Renders the nine preset meshes as an orthographic reference sheet.
  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.88, 0.87, 0.85, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  let
    cellWidth = window.size.x div 3
    cellHeight = window.size.y div 3
    direction = vec3(
      sin(options.yaw) * cos(options.pitch), sin(options.pitch),
      cos(options.yaw) * cos(options.pitch)
    )
  for i, index in ReferencePresets:
    var settings = preset(index, (options.seed + i) mod 1_000_000_001)
    if options.fillSubdivisions >= 0:
      settings.fillSubdivisions = options.fillSubdivisions
    let
      geometry = generateGeometry(settings)
      node = rockNode(geometry, app.materials, options.regions)
      target = (geometry.minimum + geometry.maximum) * 0.5'f
      extent = geometry.maximum - geometry.minimum
      reach = max(extent.y * 0.68'f, max(extent.x, extent.z) * 0.78'f)
      eye = target + direction * 15.0'f
    app.materials.tint(settings)
    app.toon.view = lookAt(eye, target, vec3(0, 1, 0))
    app.toon.proj = ortho(-reach, reach, -reach, reach, 0.05'f, 250.0'f)
    app.toon.cameraPosition = eye
    updateSunMatrix()
    app.toon.lightDirection = -sunDirection
    sunDepthPasses(window.size):
      app.toon.drawSunDepth(node)
    glViewport(
      (i mod 3).int32 * cellWidth,
      (2 - i div 3).int32 * cellHeight,
      cellWidth,
      cellHeight
    )
    app.toon.draw(app.ground)
    if options.wireframe:
      glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
    app.toon.draw(node)
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
    node.clearFromGpu()
  glViewport(0, 0, window.size.x, window.size.y)

proc screenshot(window: Window, path: string) =
  ## Saves the final rendered frame for reproducible visual checks.
  try:
    createDir(path.parentDir)
    let image = newImage(window.size.x, window.size.y)
    glReadPixels(
      0, 0, window.size.x, window.size.y, GL_RGBA,
      GL_UNSIGNED_BYTE, image.data[0].addr
    )
    image.flipVertical()
    image.writeFile(path)
  except IOError, OSError, PixieError:
    raise newException(RockgenError, "Cannot save screenshot: " &
      getCurrentExceptionMsg())

proc main() =
  ## Runs the standalone rock editor or exports a rock without a window.
  let options = optionsFromArgs()
  var settings = preset(options.preset, options.seed)
  if options.loadPath.len > 0:
    settings = loadSettings(options.loadPath)
  if options.fillSubdivisions >= 0:
    settings.fillSubdivisions = options.fillSubdivisions
  settings.validate()
  if options.exportPath.len > 0:
    settings.exportRock(options.exportPath)
    echo "Exported ", options.exportPath
    return
  createDir(UiAtlas.parentDir)
  let builder = newAtlasBuilder(1024, 4)
  builder.addDir(ThemeDirectory & "/", ThemeDirectory & "/")
  builder.addFont(ThemeDirectory / "IBMPlexSans-Regular.ttf", "Default", 16)
  builder.addFont(ThemeDirectory / "IBMPlexSans-Regular.ttf", "H1", 26)
  builder.write(UiAtlas)
  let window = newWindow(
    "Rockgen",
    (if options.sheet: ivec2(1500, 1500) else: WindowSize),
    visible = options.frames == 0,
    vsync = true,
    msaa = msaa4x
  )
  makeContextCurrent(window)
  loadExtensions()
  initSunShadows(32, 65)
  sunAzimuth = 325
  sunElevation = 70
  sunShadowStrength = 0.3'f
  sunShadowSoftness = 4.0'f
  var app = RockApp(
    sk: newSilky(window, UiAtlas), toon: newToonContext(),
    settings: settings, presetName: PresetNames[options.preset],
    materials: loadMaterials(), rng: initRand(), ground: groundNode(),
    showPanel: not options.noPanel, gallery: options.gallery,
    regions: options.regions, wireframe: options.wireframe,
    yaw: options.yaw, pitch: options.pitch
  )
  if options.loadPath.len > 0:
    app.presetName = "Custom"
  app.toon.setRamp(rampImage(0.0'f, 1.0'f))
  app.toon.highlightColor = color(1, 0.99, 0.96, 1)
  app.toon.shadowColor = color(0.48, 0.52, 0.61, 1)
  app.toon.rimColor = color(0.9, 0.93, 1, 0.025)
  app.toon.tint = color(1.9, 1.9, 1.9, 1)
  app.rebuild()
  app.frameRock()
  var lastTime = epochTime()
  while not window.closeRequested:
    pollEvents()
    let now = epochTime()
    app.handleInput(window, min(0.05'f, (now - lastTime).float32))
    lastTime = now
    let galleryChanged = app.gallery != app.builtGallery
    if app.settings.geometryKey() != app.built.geometryKey() or
      galleryChanged or app.regions != app.builtRegions:
        app.rebuild()
        if galleryChanged:
          app.frameRock()
    app.materials.tint(app.settings)
    if options.sheet:
      app.drawSheet(window, options)
    else:
      app.drawScene(window)
      app.drawUi(window)
    inc app.frame
    if options.frames > 0 and app.frame >= options.frames:
      if options.screenshot.len > 0:
        window.screenshot(options.screenshot)
      window.closeRequested = true
    window.swapBuffers()
  app.releaseRocks()
  app.ground.clearFromGpu()
  window.close()

main()
