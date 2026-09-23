import
  std/[math, os],
  chroma, opengl, pixie, vmath, windy,
  polyworld/[assets, groves, quadterrain, shadows, toon],
  ../examples/light_vs_dark/[assets, buildings, content, factions, sim]

const
  RenderSize = 512
  CardColor = color(0.10, 0.12, 0.16)
  Names = ["Town hall", "Farm", "Barracks", "Lumber mill", "Tower",
    "Stables", "Church", "Blacksmith", "Gold mine"]

type
  Bounds = object
    low, high: Vec3
  CaptureTarget = object
    framebuffer, color, depth: GLuint

proc createTarget(): CaptureTarget =
  ## Allocates an offscreen target so hidden windows need no drawable.
  glGenFramebuffers(1, result.framebuffer.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, result.framebuffer)
  glGenRenderbuffers(1, result.color.addr)
  glBindRenderbuffer(GL_RENDERBUFFER, result.color)
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, RenderSize, RenderSize)
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, result.color
  )
  glGenRenderbuffers(1, result.depth.addr)
  glBindRenderbuffer(GL_RENDERBUFFER, result.depth)
  glRenderbufferStorage(
    GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, RenderSize, RenderSize
  )
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, result.depth
  )
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc close(target: var CaptureTarget) =
  ## Frees the image target before the OpenGL context closes.
  glDeleteRenderbuffers(1, target.depth.addr)
  glDeleteRenderbuffers(1, target.color.addr)
  glDeleteFramebuffers(1, target.framebuffer.addr)

proc label(
  image: Image,
  font: Font,
  value: string,
  x, y, width: int,
  size: float32,
  tint = color(0.14, 0.17, 0.20)
) =
  ## Places a label outside the game-rendered model.
  font.size = size
  font.paint.color = tint
  image.fillText(
    font.typeset(value, vec2(width.float32, 100)),
    translate(vec2(x.float32, y.float32))
  )

proc bounds(parts: openArray[BuildingPart]): Bounds =
  ## Measures all placed pieces, including the mine's rotated rock cluster.
  result = Bounds(low: vec3(float32.high), high: vec3(float32.low))
  for part in parts:
    let
      size = part.pack.propSize(part.name) * part.scale
      halfWidth = (abs(cos(part.rotation)) * size.x +
        abs(sin(part.rotation)) * size.z) * 0.5'f
      halfDepth = (abs(sin(part.rotation)) * size.x +
        abs(cos(part.rotation)) * size.z) * 0.5'f
    result.low = min(
      result.low, part.position - vec3(halfWidth, 0, halfDepth)
    )
    result.high = max(
      result.high, part.position + vec3(halfWidth, size.y, halfDepth)
    )

proc capture(
  window: Window,
  output: CaptureTarget,
  parts: openArray[BuildingPart],
  frame: Bounds
): Image =
  ## Renders the same loaded props, materials, lighting, and mine assembly.
  let
    target = (frame.low + frame.high) * 0.5'f
    view = lookAt(target + vec3(5, 5.5, 8), target, vec3(0, 1, 0))
  var extent = 0.0'f
  for x in [frame.low.x, frame.high.x]:
    for y in [frame.low.y, frame.high.y]:
      for z in [frame.low.z, frame.high.z]:
        let point = view * vec4(x, y, z, 1)
        extent = max(extent, max(abs(point.x), abs(point.y)))
  extent *= 1.10'f
  let matrix = ortho(-extent, extent, -extent, extent, 0.1'f, 100'f) * view
  for iteration in 0 ..< 2:
    sunDepthPasses(window.size):
      for part in parts:
        part.pack.drawPropSunDepth(
          part.name, part.position, part.rotation, part.scale
        )
    doAssert glGetError() == GL_NO_ERROR, "Building shadow pass."
    glBindFramebuffer(GL_FRAMEBUFFER, output.framebuffer)
    glViewport(0, 0, RenderSize, RenderSize)
    glEnable(GL_MULTISAMPLE)
    glDepthMask(GL_TRUE)
    glClearColor(CardColor.r, CardColor.g, CardColor.b, 1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    for part in parts:
      part.pack.drawProp(
        part.name,
        part.position,
        part.rotation,
        part.scale,
        matrix
      )
    let error = glGetError()
    doAssert error == GL_NO_ERROR, "Building color pass: " & $error.uint32
    if iteration == 1:
      result = newImage(RenderSize, RenderSize)
      glReadPixels(
        0, 0, RenderSize, RenderSize,
        GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr
      )
      result.flipVertical()
      doAssert glGetError() == GL_NO_ERROR, "Building image capture."
    window.swapBuffers()
    pollEvents()

proc main() =
  ## Renders all CC0 building portraits with the game's exact assemblies.
  let window = newWindow(
    "LvD building portraits",
    ivec2(RenderSize, RenderSize),
    visible = false,
    vsync = false,
    msaa = msaa4x
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  var output = createTarget()
  defer:
    output.close()
  initSunShadows(lightRadius = 10, lightDistance = 20)
  initTerrain(
    NoTrees, GeneratedTerrain, NoRocks,
    settings = TerrainAssets(size: 64)
  )
  applySunHour(12)
  let palette = paletteAtHour(12)
  setEnvironmentPalette(palette.highlight, palette.shadow, -sunDirection)
  if "--factions" in commandLineParams():
    var factions: seq[Faction]
    for faction in Faction:
      factions.add faction
    let
      art = loadBuildingArt(Grove(), factions = factions)
      sheet = newImage(4 * 384, 2 * 416)
      font = readFont(DefaultFontPath)
    sheet.fill(CardColor)
    for faction in Faction:
      for kind in TownHallBuilding .. BuildableHigh:
        let
          parts = art.buildingParts(kind, vec3(0), owner = faction.ord.int32)
          portrait = capture(window, output, parts, bounds(parts))
          path = buildingPortraitPath(faction, kind)
        createDir(path.parentDir)
        portrait.resize(256, 256).writeFile(path)
        if kind == TownHallBuilding:
          let
            x = (faction.ord mod 4) * 384
            y = (faction.ord div 4) * 416
          sheet.draw(
            portrait.resize(384, 384), translate(vec2(x.float32, y.float32))
          )
          sheet.label(
            font, $faction, x + 16, y + 384, 352, 24,
            color(0.95, 0.95, 0.95)
          )
      echo "Rendered ", faction, " building portraits."
    createDir("tmp")
    sheet.writeFile("tmp/lvd-faction-buildings.png")
    return
  let
    grove = generateGrove(DefaultSeed, {LightRock})
    art = loadBuildingArt(grove)
    sheet = newImage(1152, 1248)
    constructionSheet = newImage(768, 8 * 280)
    font = readFont(DefaultFontPath)
  sheet.fill(CardColor)
  constructionSheet.fill(CardColor)
  for kind in BuildingKind:
    let
      parts = art.buildingParts(kind, vec3(0))
      frame = bounds(parts)
      footprint = BuildingTable[kind].footprint
      portrait = capture(window, output, parts, frame)
      path = buildingPortraitPath(0, kind)
      x = (kind.ord mod 3) * 384
      y = (kind.ord div 3) * 416
    echo Names[kind.ord], " bounds: ", frame.low, " to ", frame.high
    doAssert max(abs(frame.low.x), abs(frame.high.x)) <=
      footprint.width.float32 * 0.5'f + 0.01'f,
      $kind & " extends beyond its footprint width"
    doAssert max(abs(frame.low.z), abs(frame.high.z)) <=
      footprint.depth.float32 * 0.5'f + 0.01'f,
      $kind & " extends beyond its footprint depth"
    createDir(path.parentDir)
    portrait.resize(256, 256).writeFile(path)
    sheet.draw(portrait.resize(384, 384), translate(vec2(x.float32, y.float32)))
    sheet.label(
      font, Names[kind.ord], x + 16, y + 384, 352, 24,
      color(0.95, 0.95, 0.95)
    )
    echo path
    if kind <= BuildableHigh:
      for column in 0 .. 2:
        let
          stageParts =
            if column == 2: parts
            else:
              art.buildingParts(
                kind, vec3(0), BuildingUnderConstruction,
                ConstructionStage(column)
              )
          stageImage = capture(window, output, stageParts, frame)
          stageName =
            if column == 2: "Complete"
            else: ConstructionNames[column]
          stageX = column * 256
          stageY = kind.ord * 280
        constructionSheet.draw(
          stageImage.resize(256, 256),
          translate(vec2(stageX.float32, stageY.float32))
        )
        constructionSheet.label(
          font, Names[kind.ord] & " / " & stageName,
          stageX + 8, stageY + 256, 240, 15, color(0.95, 0.95, 0.95)
        )
  createDir("tmp")
  sheet.writeFile("tmp/lvd-cc0-buildings.png")
  constructionSheet.writeFile("tmp/lvd-construction-stages.png")

main()
