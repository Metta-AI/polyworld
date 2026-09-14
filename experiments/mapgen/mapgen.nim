import
  std/[math, os, strutils, times],
  bumpy, pixie, silky, vmath,
  maps, tiles

const
  ExperimentDir = currentSourcePath().parentDir
  DefaultAssetDir = ExperimentDir / "../../../polyworld_data"
  IconNames = ["tower", "idol", "tree", "barracks"]
  Background = rgbx(21, 27, 28, 255)
  PanelColor = rgbx(29, 36, 37, 255)
  CardColor = rgbx(39, 47, 48, 255)
  BorderColor = rgbx(56, 66, 66, 255)
  TextColor = rgbx(232, 236, 223, 255)
  MutedColor = rgbx(143, 158, 151, 255)
  AccentColor = rgbx(189, 218, 143, 255)

type
  App = ref object
    window: Window
    sk: Silky
    config: MapConfig
    map: MapData
    tiles: TileGrid
    tileColors: seq[ColorRGBX]
    activeKnob: int
    dragOrigin: Vec2
    dragValue: float32
    walkableOnly, creeps: bool
    elapsed: float32
    lastFrame: float
    status: string

proc label(
  sk: Silky,
  text: string,
  x, y: float32,
  color = TextColor,
  font = "Default"
) =
  ## Draws one consistently styled UI label.
  discard sk.drawText(font, text, vec2(x, y), color)

proc drawIcon(
  sk: Silky,
  name: string,
  center: Vec2,
  size: float32,
  tint: ColorRGBX
) =
  ## Draws a centered icon from the shared Polyworld assets.
  let entry = sk.atlas.entries[name]
  sk.drawQuad(
    center - vec2(size / 2),
    vec2(size),
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32),
    tint
  )

proc triangle(sk: Silky, a, b, c: Vec2, tint: ColorRGBX) =
  ## Draws a solid triangle from the Silky white atlas tile.
  let
    tile = sk.atlas.entries[WhiteTileKey]
    uv = vec2(tile.x.float32 + 8, tile.y.float32 + 8)
  sk.drawTriangle([a, b, c], [uv, uv, uv], [tint, tint, tint])

proc circle(sk: Silky, center: Vec2, radius: float32, tint: ColorRGBX) =
  ## Draws a small UI disc using a triangle fan.
  for i in 0 ..< 48:
    let
      a = i.float32 / 48 * 2 * PI.float32
      b = (i + 1).float32 / 48 * 2 * PI.float32
    sk.triangle(
      center,
      center + vec2(cos(a), sin(a)) * radius,
      center + vec2(cos(b), sin(b)) * radius,
      tint
    )

proc arc(
  sk: Silky,
  center: Vec2,
  radius, start, finish, width: float32,
  tint: ColorRGBX
) =
  ## Draws a ring segment for a rotary control.
  for i in 0 ..< 48:
    let
      a = start + (finish - start) * i.float32 / 48
      b = start + (finish - start) * (i + 1).float32 / 48
      outerA = center + vec2(cos(a), sin(a)) * radius
      outerB = center + vec2(cos(b), sin(b)) * radius
      innerA = center + vec2(cos(a), sin(a)) * (radius - width)
      innerB = center + vec2(cos(b), sin(b)) * (radius - width)
    sk.triangle(outerA, outerB, innerA, tint)
    sk.triangle(innerA, outerB, innerB, tint)

proc button(
  app: App,
  title: string,
  area: Rect,
  accent = false
): bool =
  ## Draws a button and activates it on a mouse press.
  let
    sk = app.sk
    hovered = sk.mousePos.overlaps(area)
    fill =
      if accent: AccentColor
      elif hovered: BorderColor
      else: CardColor
    ink = (if accent: Background else: TextColor)
  sk.drawRect(area.xy, area.wh, fill)
  discard sk.drawText(
    "Default", title, area.xy, ink, area.w, area.h,
    hAlign = CenterAlign, vAlign = MiddleAlign
  )
  hovered and sk.buttonPressed[MouseLeft]

proc checkbox(app: App, title: string, value: var bool, area: Rect) =
  ## Toggles a generator rule by clicking its box or label.
  let
    sk = app.sk
    hovered = sk.mousePos.overlaps(area)
    corner = area.xy + vec2(8, (area.h - 16) / 2)
  if hovered and sk.buttonPressed[MouseLeft]:
    value = not value
  sk.drawRect(area.xy, area.wh, if hovered: BorderColor else: CardColor)
  sk.drawRect(corner, vec2(16), MutedColor)
  sk.drawRect(corner + vec2(2), vec2(12), PanelColor)
  if value:
    sk.drawRect(corner + vec2(4), vec2(8), AccentColor)
  sk.label(title, area.x + 32, area.y + 5, TextColor, "Small")

proc knob(
  app: App,
  id: int,
  title: string,
  value: var float32,
  minimum, maximum, x, y: float32
) =
  ## Adjusts a bounded value by dragging vertically or horizontally.
  let
    sk = app.sk
    area = rect(x, y, 112, 83)
    hovered = sk.mousePos.overlaps(area)
    center = vec2(x + 27, y + 48)
  if hovered and sk.buttonPressed[MouseLeft]:
    app.activeKnob = id
    app.dragOrigin = sk.mousePos
    app.dragValue = value
  if app.activeKnob == id:
    if sk.buttonDown[MouseLeft]:
      let delta = sk.mousePos - app.dragOrigin
      value = clamp(
        round(app.dragValue + (delta.x - delta.y) / 180 * (maximum - minimum)),
        minimum,
        maximum
      )
    else:
      app.activeKnob = -1
  if hovered and app.window.scrollDelta.y != 0:
    value = clamp(value + app.window.scrollDelta.y, minimum, maximum)
  sk.drawRect(area.xy, area.wh, CardColor)
  sk.label(title, x + 10, y + 6, MutedColor, "Small")
  let
    start = PI.float32 * 0.75'f
    finish = PI.float32 * 2.25'f
    theta = start + (finish - start) * (value - minimum) / (maximum - minimum)
    tint = (if hovered or app.activeKnob == id: TextColor else: AccentColor)
  sk.arc(center, 20, start, finish, 3, BorderColor)
  sk.arc(center, 20, start, theta, 3, tint)
  sk.circle(center, 13, PanelColor)
  sk.circle(center + vec2(cos(theta), sin(theta)) * 9, 2.5, tint)
  let number =
    if value == floor(value): $value.int
    else: formatFloat(value, ffDecimal, 1)
  sk.label(number, x + 58, y + 33, TextColor, "Value")

proc slider(
  app: App,
  id: int,
  title: string,
  value: var float32,
  minimum, maximum, step, x, y, width: float32
) =
  ## Adjusts a stepped value while dragging or scrolling a compact slider.
  let
    sk = app.sk
    area = rect(x, y, width, 43)
    left = x + 8
    span = width - 16
    hovered = sk.mousePos.overlaps(area)
  if hovered and sk.buttonPressed[MouseLeft]:
    app.activeKnob = id
  if app.activeKnob == id:
    if sk.buttonDown[MouseLeft]:
      let fraction = clamp((sk.mousePos.x - left) / span, 0'f, 1'f)
      value = minimum + round(fraction * (maximum - minimum) / step) * step
    else:
      app.activeKnob = -1
  if hovered and app.window.scrollDelta.y != 0:
    let delta = (if app.window.scrollDelta.y > 0: step else: -step)
    value = clamp(value + delta, minimum, maximum)
  sk.drawRect(area.xy, area.wh, CardColor)
  sk.label(title & "  " & $value.int, left, y + 3, MutedColor, "Small")
  let fill = (value - minimum) / (maximum - minimum) * span
  sk.drawRect(vec2(left, y + 31), vec2(span, 3), BorderColor)
  sk.drawRect(vec2(left, y + 31), vec2(fill, 3), AccentColor)
  sk.circle(vec2(left + fill, y + 32.5'f), 4.5, AccentColor)

proc rebuild(app: App) =
  ## Regenerates terrain and caches the colors used by the tile rectangles.
  try:
    let
      map = generateMap(app.config)
      tiles = buildTiles(map)
    app.map = map
    app.tiles = tiles
    app.tileColors = tiles.colors(app.walkableOnly)
  except MapgenError as error:
    app.config = app.map.config
    app.status = error.msg
    return
  app.elapsed = 0
  app.status = "Seed " & $app.config.seed & "  /  symmetry locked"

proc toggleWalkability(app: App) =
  ## Switches tile colors without regenerating the map or restarting creeps.
  app.walkableOnly = not app.walkableOnly
  app.tileColors = app.tiles.colors(app.walkableOnly)

proc legend(sk: Silky, title: string, tint: ColorRGBX, x, y: float32) =
  ## Draws one colored key in the map legend.
  sk.drawRect(vec2(x, y + 4), vec2(10, 10), tint)
  sk.label(title, x + 18, y, MutedColor, "Small")

proc drawSidebar(app: App) =
  ## Draws the persistent generator controls on the left.
  let sk = app.sk
  sk.drawRect(vec2(0, 0), vec2(280, sk.size.y), PanelColor)
  sk.drawRect(vec2(279, 0), vec2(1, sk.size.y), BorderColor)
  sk.label("MAP GENERATOR", 24, 22, AccentColor, "Small")
  sk.label("GotA", 24, 44, TextColor, "Heading")
  sk.label("Procedural battleground", 24, 83, MutedColor)
  sk.drawRect(vec2(24, 121), vec2(232, 1), BorderColor)
  sk.label("SEED  " & align($app.config.seed, 4, '0'), 24, 135)
  sk.label("180-degree symmetry", 24, 160, AccentColor, "Small")
  if app.button("New seed", rect(159, 132, 97, 30)):
    app.config.seed = (app.config.seed + 1) mod 1_000_000

  app.knob(0, "High ground", app.config.highSize, 450, 570, 24, 198)
  app.knob(1, "Castle size", app.config.castleSize, 210, 500, 144, 198)
  app.knob(2, "Road width", app.config.roadWidth, 26, 62, 24, 289)
  app.knob(3, "Road curve", app.config.roadWobble, 0, 80, 144, 289)
  app.knob(4, "Lake width", app.config.lakeWidth, 42, 120, 24, 380)
  app.knob(5, "Lake wobble", app.config.lakeWobble, 0, 80, 144, 380)
  app.slider(6, "Camp size", app.config.campRadius, 20, 40, 1, 24, 471, 112)
  app.slider(7, "Stem length", app.config.stemLength, 30, 80, 1, 144, 471, 112)
  var
    roads = app.config.jungleRoads.float32
    crossings = app.config.lakeCrossings.float32
    mapSize = app.config.mapSize.float32
  app.slider(8, "Jungle roads", roads, 18, 50, 2, 24, 520, 112)
  app.slider(9, "Camp scatter", app.config.campScatter, 0, 60, 1, 144, 520, 112)
  app.slider(10, "Lake crossings", crossings, 0, 6, 2, 24, 569, 112)
  app.slider(11, "Map tiles", mapSize, MinimumMapSize,
    MaximumMapSize, 2, 144, 569, 112)
  app.config.mapSize = mapSize.int
  app.config.jungleRoads = roads.int
  app.config.lakeCrossings = crossings.int
  app.checkbox(
    "Camps can touch roads", app.config.campsTouchRoads, rect(24, 618, 232, 28)
  )
  sk.drawRect(vec2(24, 657), vec2(232, 1), BorderColor)
  sk.legend("Low ground", LowColor, 24, 671)
  sk.legend("High ground", HighColor, 144, 671)
  sk.legend("Castle", CastleColor, 24, 695)
  sk.legend("Keep", KeepColor, 144, 695)
  sk.legend("Spawn", SpawnColor, 24, 719)
  sk.legend("Lake", WaterColor, 144, 719)
  sk.legend("Road", RoadColor, 24, 743)
  sk.drawIcon("tree", vec2(149, 752), 18, AccentColor)
  sk.label("Jungle camp", 162, 743, MutedColor, "Small")
  sk.circle(vec2(29, 776), 5, TreeColor)
  sk.label("Trees", 42, 767, MutedColor, "Small")
  sk.drawIcon("tower", vec2(108, 776), 18, TeamColors[0])
  sk.label("Towers", 121, 767, MutedColor, "Small")
  sk.drawIcon("idol", vec2(187, 776), 18, TeamColors[1])
  sk.label("Gods", 200, 767, MutedColor, "Small")
  sk.legend("Walls", WallColor, 24, 791)
  sk.legend("Cliffs / ramps", Palettes[Southwest].cliffs, 144, 791)
  if app.button("Reset defaults", rect(24, 813, 232, 38), true):
    app.config = defaultConfig()
  sk.label(
    "R  Seed   W  Walkable   C  Creeps",
    24,
    867,
    MutedColor,
    "Small"
  )

proc drawTiles(app: App, origin: Vec2, size: float32) =
  ## Draws crisp pixel-aligned tiles, merging identical colors within each row.
  let sk = app.sk
  var edges = newSeq[Vec2](app.tiles.resolution + 1)
  for i in 0 .. app.tiles.resolution:
    let
      offset = size * i.float32 / app.tiles.resolution.float32
      point = (origin + vec2(offset)) * sk.uiScale
    edges[i] = vec2(round(point.x), round(point.y)) / sk.uiScale
  for y in 0 ..< app.tiles.resolution:
    var x = 0
    while x < app.tiles.resolution:
      let color = app.tileColors[y * app.tiles.resolution + x]
      var finish = x + 1
      while finish < app.tiles.resolution and
        app.tileColors[y * app.tiles.resolution + finish] == color:
          finish.inc
      sk.drawRect(
        vec2(edges[x].x, edges[y].y),
        vec2(edges[finish].x - edges[x].x, edges[y + 1].y - edges[y].y),
        color
      )
      x = finish

proc drawCanvas(app: App) =
  ## Fits the square map into the space beside the controls.
  let
    sk = app.sk
    available = vec2(sk.size.x - 328, sk.size.y - 150)
    size = min(available.x, available.y)
    origin = vec2(304 + (available.x - size) / 2, 90)
  sk.label("THE BATTLEGROUND", 304, 25, TextColor, "Small")
  sk.label(
    $app.tiles.resolution & " x " & $app.tiles.resolution &
      " tiles   /   18 towers   /   14 camps   /   12 barracks",
    304,
    61,
    MutedColor
  )
  if app.button(
    (if app.creeps: "Creeps on" else: "Creeps off"),
    rect(sk.size.x - 272, 27, 96, 31)
  ):
    app.creeps = not app.creeps
  if app.button(
    "Walkable only",
    rect(sk.size.x - 166, 27, 142, 31),
    app.walkableOnly
  ):
    app.toggleWalkability()
  sk.drawRect(origin - vec2(1, 1), vec2(size + 2), BorderColor)
  app.drawTiles(origin, size)
  sk.pushClipRect(rect(origin, vec2(size)))
  let factor = size / MapSize
  for camp in app.map.camps:
    let side = app.tiles.tileAt(camp.position).side
    sk.drawIcon(
      "tree",
      origin + camp.position * factor,
      app.config.campRadius * 0.9'f * factor,
      Palettes[side].jungle
    )
  for barrack in app.map.barracks:
    sk.drawIcon(
      "barracks",
      origin + barrack.position * factor,
      BarrackRadius * 2 * factor,
      TeamColors[barrack.team.ord]
    )
    if app.creeps:
      for wave in 0 ..< 4:
        for unit in 0 ..< 2:
          let age = app.elapsed mod CreepInterval +
            wave.float32 * CreepInterval - unit.float32 * 0.65'f
          if age < 0 or age > app.elapsed or
            age * CreepSpeed >= barrack.distance:
              continue
          let point = barrack.route.along(age * CreepSpeed / barrack.distance)
          sk.circle(origin + point * factor, 4 * factor, KeepColor)
          sk.circle(
            origin + point * factor,
            2.8'f * factor,
            TeamColors[barrack.team.ord]
          )
  for tower in app.map.towers:
    sk.drawIcon(
      "tower",
      origin + tower.position * factor,
      44 * factor,
      TeamColors[tower.team.ord]
    )
  for i, position in app.map.forts:
    sk.drawIcon(
      "idol",
      origin + position * factor,
      68 * factor,
      TeamColors[i]
    )
  sk.popClipRect()
  let bottom = origin.y + size + 15
  sk.circle(vec2(origin.x + 6, bottom + 8), 5, TeamColors[0])
  sk.label("RADIANT / SW", origin.x + 20, bottom, MutedColor, "Small")
  sk.circle(vec2(origin.x + size - 101, bottom + 8), 5, TeamColors[1])
  sk.label("DIRE / NE", origin.x + size - 88, bottom, MutedColor, "Small")
  var caption = app.status
  if sk.mousePos.overlaps(rect(origin, vec2(size))):
    let
      point = (sk.mousePos - origin) / size * app.tiles.resolution.float32
      x = clamp(point.x.int, 0, app.tiles.resolution - 1)
      y = clamp(point.y.int, 0, app.tiles.resolution - 1)
      tile = app.tiles.cells[y * app.tiles.resolution + x]
    caption &= "  |  Tile " & $x & ", " & $y & "  |  Height " & $tile.height
    if app.walkableOnly:
      caption &= (if tile.passable: "  |  Walkable" else: "  |  Blocked")
    if RampEdge in tile.edges:
      caption &= "  |  Ramp"
    elif CliffEdge in tile.edges:
      caption &= "  |  Cliff edge"
    for barrack in app.map.barracks:
      let distance = length(point * app.tiles.tileSize - barrack.position)
      if distance < BarrackRadius * 2:
        let lane =
          if barrack.team == Southwest:
            ["West", "South", "Middle"][barrack.lane]
          else:
            ["North", "East", "Middle"][barrack.lane]
        caption = lane & " barracks  /  creep waves every " &
          $CreepInterval.int & " seconds"
  sk.label(caption, 304, sk.size.y - 25, MutedColor, "Small")

proc runApp(config: MapConfig) =
  ## Creates the native Silky window and runs its explicit frame loop.
  let
    assetDir = getEnv("POLYWORLD_DATA", DefaultAssetDir)
    fontPath = assetDir / "themes/main/IBMPlexSans-Regular.ttf"
    builder = newAtlasBuilder(2048, 2)
    map = generateMap(config)
    tileGrid = buildTiles(map)
  builder.addFont(fontPath, "Small", 13)
  builder.addFont(fontPath, "Default", 16)
  builder.addFont(fontPath, "Value", 24)
  builder.addFont(fontPath, "Heading", 32)
  for name in IconNames:
    let path = assetDir / "icons" / (name & ".png")
    if not builder.addImage(name, readImage(path)):
      raise newException(
        MapgenError,
        "The icon did not fit in its atlas: " & path
      )
  let window = newWindow("GotA - Map Generator", ivec2(2400, 1720))
  window.makeContextCurrent()
  loadExtensions()
  let app = App(
    window: window,
    sk: newSilky(window, builder.atlasImage, builder.atlas),
    config: config,
    map: map,
    tiles: tileGrid,
    tileColors: tileGrid.colors(),
    activeKnob: -1,
    creeps: true,
    lastFrame: epochTime(),
    status: "Seed " & $config.seed & "  /  symmetry locked"
  )
  window.onFrame = proc() =
    ## Handles input, rebuilds changed geometry, and presents one frame.
    let
      previous = app.config
      size = window.size.vec2
      now = epochTime()
    if app.creeps:
      app.elapsed += min(0.1, now - app.lastFrame).float32
      if app.elapsed >= CreepInterval * 5:
        app.elapsed -= CreepInterval
    app.lastFrame = now
    app.sk.uiScale = max(0.5'f, min(2'f, min(size.x / 1120, size.y / 890)))
    app.sk.beginUi(window, window.size)
    app.sk.clearScreen(Background)
    if app.sk.buttonPressed[KeyR]:
      app.config.seed = (app.config.seed + 1) mod 1_000_000
    if app.sk.buttonPressed[KeyW]:
      app.toggleWalkability()
    if app.sk.buttonPressed[KeyC]:
      app.creeps = not app.creeps
    app.drawSidebar()
    if app.config != previous:
      app.rebuild()
    app.drawCanvas()
    app.sk.endUi()
    window.swapBuffers()
  while not window.closeRequested:
    pollEvents()
  window.onFrame = nil
  window.close()

proc main() =
  ## Starts the native map generator with an optional reproducible seed.
  var config = defaultConfig()
  for argument in commandLineParams():
    if argument.startsWith("--seed:"):
      try:
        config.seed = parseInt(argument[7 .. ^1])
      except ValueError as error:
        raise newException(MapgenError, "Invalid map seed: " & error.msg)
    else:
      raise newException(MapgenError, "Unknown argument: " & argument)
  runApp(config)

main()
