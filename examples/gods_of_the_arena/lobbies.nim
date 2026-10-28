import
  std/[math, strutils],
  chroma, pixie, silky, vmath, windy,
  polyworld/[assets, chrome, menus],
  homes, presets, generation/[maps, tiles]

const
  LobbyCanvas = vec2(1514, 970)
  LobbyPanelHeight = 712.0'f
  LobbyGreen* = rgbx(110, 230, 125, 255)
  LobbyRed* = rgbx(244, 108, 104, 255)
  LobbyBlue* = rgbx(96, 184, 244, 255)
  LobbyMuted* = rgbx(170, 175, 181, 255)

type
  DraftChoice = enum
    Unique = "Unique", Team = "Team", Open = "Open"
  LobbyLayout* = object
    origin*, left*, right*, footer*, primary*: Vec2
    leftWidth*, rightWidth*: float32
    compact*: bool
  LobbyUi* = object
    scroll*: float32
    search*: string
    roomPage*, participantPage*: int
    selectedSeat*: int = -1
    selectedBot*: string = "Base bot"
    configPage*: int
    draft: DraftChoice
    previewConfig: MapConfig
    preview: TileGrid
  SlotChoice* = object
    chosen*: bool
    human*, clear*, file*: bool
    bot*: int

proc addLobbyFonts*(builder: AtlasBuilder) =
  ## Uses the mockup's three sizes with the existing Rubik typefaces.
  builder.addFont(BoldFontPath, "LobbyTitle", 48)
  builder.addFont(BoldFontPath, "LobbyHeading", 28)
  builder.addFont(DefaultFontPath, "LobbyBody", 20)
  builder.addFont(BoldFontPath, "LobbyBold", 20)

proc lobbyLabel*(
    sk: Silky, text: string, at: Vec2, width: float32,
    font = "LobbyBody", tint = rgbx(240, 237, 225, 255)
) =
  ## Draws clipped text using only the lobby's three font sizes.
  sk.drawLabel(
    text,
    at,
    vec2(width, if font == "LobbyTitle": 60.0'f else: 40.0'f),
    tint,
    font
  )

proc lobbyIcon*(
    sk: Silky, name: string, at: Vec2, size = 28.0'f,
    tint = rgbx(240, 237, 225, 255)
) =
  ## Draws a shared neutral icon with an optional team tint.
  sk.drawSprite(name, at, vec2(size), tint)

proc lobbyTitle*(sk: Silky, title, icon: string, center: Vec2) =
  ## Centers the icon and measured title together on a shared baseline.
  let
    width = sk.getTextSize("LobbyTitle", title).x
    left = center.x - (width + 80) / 2
  sk.drawSprite("home-shade", center - vec2(470, 170), vec2(940, 340))
  sk.lobbyIcon(icon, vec2(left, center.y - 30), 60)
  sk.drawLabel(
    title,
    vec2(left + 80, center.y - 30),
    vec2(width + 1, 60),
    rgbx(240, 237, 225, 255),
    "LobbyTitle"
  )

proc beginLobbySettings*(sk: Silky, window: Window): Vec2 =
  ## Places the matching settings heading above the standard Silky panel.
  result = sk.beginSettings(window, 100)
  sk.drawHomeBackground(window)
  sk.lobbyTitle("SETTINGS", "settings", result + vec2(360, -74))

proc lobbyPanel*(sk: Silky, at, size: Vec2, frame = false) =
  ## Reuses the existing theme's window and inset frame patches.
  sk.draw9Patch(
    if frame: "frame.9patch" else: "window.9patch",
    if frame: sk.theme.framePatch else: sk.theme.windowPatch,
    at,
    size
  )

proc lobbyButton*(
    sk: Silky, text: string, at: Vec2, width: float32,
    icon = "", enabled = true, selected = false, height = 44.0'f,
    tint = rgbx(255, 255, 255, 255)
): bool =
  ## Uses Silky interaction states and theme patches for an icon button.
  let
    size = vec2(width, height)
    interaction = sk.interact(rect(at, size), enabled)
    patch = case interaction
      of Disabled: "button.disabled.9patch"
      of Pressed, Held: "button.down.9patch"
      of Hovered, Released: "button.hover.9patch"
      else:
        if selected: "button.down.9patch" else: "button.9patch"
    ink =
      if enabled: sk.theme.defaultTextColor
      else: sk.theme.disabledTextColor
    inset = if icon.len > 0: 42.0'f else: 10.0'f
  sk.draw9Patch(patch, sk.theme.buttonPatch, at, size, tint)
  if icon.len > 0:
    sk.lobbyIcon(icon, at + vec2(10, (height - 26) / 2), 26, ink)
  sk.drawLabel(
    text,
    at + vec2(inset, 0),
    vec2(width - inset - 10, height),
    ink,
    "LobbyBody",
    CenterAlign
  )
  interaction == Released

proc lobbyInput*(
    sk: Silky, window: Window, id: string, value: var string,
    at: Vec2, width: float32
) =
  ## Reuses Silky's themed text field and editing behavior.
  sk.at = at
  sk.textBox(window, id, value, width, 44, wrapWords = false, singleLine = true)

proc lobbySelect*[T](
    sk: Silky, window: Window, value: var T, options: openArray[T],
    at: Vec2, width: float32, enabled = true
) =
  ## Places a standard Silky dropdown inside an explicit layout cell.
  if enabled:
    sk.pushLayout(at, vec2(width + sk.theme.padding.float32 * 3, 44))
    dropDown value, options
    sk.popLayout()
  else:
    sk.lobbyLabel($value, at, width, tint = LobbyMuted)

proc lobbyNumber*[T: SomeNumber](
    sk: Silky, label: string, value: var T, at: Vec2,
    width: float32, minimum, maximum, step: T, enabled = true
) =
  ## Edits a bounded setting using the theme's buttons and input frame.
  sk.lobbyLabel(label, at, 190)
  let
    point = at + vec2(196, 0)
    fieldWidth = width - 196
    text = when T is SomeFloat: formatFloat(value, ffDecimal, 1) else: $value
  sk.lobbyPanel(point, vec2(fieldWidth, 40), true)
  sk.drawLabel(text, point, vec2(fieldWidth, 40),
    sk.theme.defaultTextColor, "LobbyBody", CenterAlign)
  if sk.lobbyButton("", point, 38, "minus", enabled and value > minimum,
    height = 40):
      value = max(minimum, value - step)
  if sk.lobbyButton("", point + vec2(fieldWidth - 38, 0), 38, "cross",
    enabled and value < maximum, height = 40):
      value = min(maximum, value + step)

proc beginLobby*(
    sk: Silky, window: Window, ui: var LobbyUi,
    title: string, multiplayer = false
): LobbyLayout =
  ## Fits landscape layouts and stacks panels with scrolling in tall windows.
  result.compact = window.size.x.float32 / window.size.y.float32 < 1.3
  let canvas = if result.compact: vec2(1000, 1722) else: LobbyCanvas
  sk.uiScale = max(0.1'f, min(
    window.size.x.float32 / canvas.x,
    if result.compact: window.size.x.float32 / canvas.x
    else: window.size.y.float32 / canvas.y
  ))
  sk.beginUi(window, window.size)
  sk.textStyle = "LobbyBody"
  let view = window.size.vec2 / sk.uiScale
  ui.scroll = clamp(ui.scroll + window.scrollDelta.y * ScrollSpeed.float32,
    0.0'f, max(0.0'f, canvas.y - view.y))
  result.origin = vec2((view.x - canvas.x) / 2, -ui.scroll)
  sk.drawHomeBackground(window)
  sk.lobbyTitle(title, "battle", result.origin + vec2(canvas.x / 2, 72))
  let top = if multiplayer: 238.0'f else: 150.0'f
  result.left = result.origin + vec2(32, top)
  result.leftWidth = if result.compact: 936 else: 930
  result.rightWidth = if result.compact: 936 else: 500
  result.right =
    if result.compact: result.origin + vec2(32, top + 738)
    else: result.origin + vec2(982, top)
  result.footer = result.origin + vec2(32,
    if result.compact: 1632.0'f else: 890.0'f)
  result.primary = vec2(
    result.right.x + result.rightWidth - 250,
    result.footer.y
  )

proc drawMapPreview(sk: Silky, ui: var LobbyUi, config: MapConfig, at: Vec2) =
  ## Caches the real generated map, then draws a small terrain preview.
  if ui.preview.cells.len == 0 or ui.previewConfig != config:
    ui.preview = buildTiles(generateMap(config))
    ui.previewConfig = config
  let grid = ui.preview
  for y in countup(0, grid.resolution - 1, 2):
    for x in countup(0, grid.resolution - 1, 2):
      let cell = 144.0'f / grid.resolution.float32
      sk.drawRect(at + vec2(x.float32, y.float32) * cell,
        vec2(cell * 2 + 0.2'f), grid.cells[y * grid.resolution + x].tileColor)
  sk.lobbyLabel("Generated arena", at + vec2(164, 20), 260, "LobbyBold")
  sk.lobbyLabel($config.mapSize & " x " & $config.mapSize & " tiles",
    at + vec2(164, 60), 260, tint = LobbyMuted)
  sk.lobbyLabel("Map seed " & $config.seed,
    at + vec2(164, 100), 260, tint = LobbyMuted)

proc configPanel*(
    sk: Silky, window: Window, ui: var LobbyUi, config: var GotaConfig,
    at: Vec2, width: float32, enabled: bool
): bool =
  ## Edits typed match controls without exposing the serialized room payload.
  let before = config
  sk.lobbyPanel(at, vec2(width, LobbyPanelHeight))
  let
    p = at + vec2(22)
    fieldWidth = width - 44
  sk.lobbyIcon("settings", p + vec2(0, 7))
  sk.lobbyLabel("MATCH SETTINGS", p + vec2(40, 0), fieldWidth - 40,
    "LobbyHeading")
  if ui.configPage == 0:
    sk.drawMapPreview(ui, config.mapPreset, p + vec2(0, 52))
    sk.lobbyNumber("Match seed", config.seed, p + vec2(0, 204),
      fieldWidth - 48, 0'i32, int32.high - 1, 1'i32, enabled)
    if sk.lobbyButton("", p + vec2(fieldWidth - 40, 204), 40, "dice",
      enabled, height = 40):
        config.seed = ((config.seed * 1664525'i64 + 1013904223'i64) and
          0x7fffffff'i64).int32
    sk.lobbyNumber("Map seed", config.mapPreset.seed, p + vec2(0, 248),
      fieldWidth, 0, int32.high.int - 1, 1, enabled)
    sk.lobbyNumber("Max ticks", config.maxTicks, p + vec2(0, 292),
      fieldWidth, 1440'i32, 43200'i32, 1440'i32, enabled)
    sk.lobbyLabel("Spawn (ticks)", p + vec2(0, 336), 190)
    sk.lobbySelect(window, config.spawnIntervalTicks,
      [240'i32, 480'i32, 720'i32, 960'i32],
      p + vec2(196, 336), fieldWidth - 196, enabled)
    sk.lobbyLabel("Draft mode", p + vec2(0, 384), 190)
    ui.draft = DraftChoice(ord(config.draftMode))
    sk.lobbySelect(window, ui.draft, [Unique, Team, Open],
      p + vec2(196, 384), fieldWidth - 196, enabled)
    config.draftMode = DraftMode(ord(ui.draft))
    sk.lobbyNumber("Map size", config.mapPreset.mapSize, p + vec2(0, 432),
      fieldWidth, MinimumMapSize, MaximumMapSize, 2, enabled)
    if enabled:
      sk.at = p + vec2(0, 482)
      checkBox "Camps touch roads", config.mapPreset.campsTouchRoads
      sk.at = p + vec2(0, 526)
      checkBox "Wait for LLM", config.waitForLlm
    else:
      sk.lobbyLabel("Camps touch roads: " & $config.mapPreset.campsTouchRoads,
        p + vec2(0, 482), fieldWidth, tint = LobbyMuted)
      sk.lobbyLabel("Wait for LLM: " & $config.waitForLlm,
        p + vec2(0, 526), fieldWidth, tint = LobbyMuted)
  elif ui.configPage == 1:
    sk.lobbyNumber("High ground", config.mapPreset.highSize,
      p + vec2(0, 56), fieldWidth, 450'f, 570'f, 1'f, enabled)
    sk.lobbyNumber("Castle size", config.mapPreset.castleSize,
      p + vec2(0, 100), fieldWidth, 210'f, 500'f, 5'f, enabled)
    sk.lobbyNumber("Road width", config.mapPreset.roadWidth,
      p + vec2(0, 144), fieldWidth, 26'f, 62'f, 1'f, enabled)
    sk.lobbyNumber("Road curve", config.mapPreset.roadWobble,
      p + vec2(0, 188), fieldWidth, 0'f, 80'f, 1'f, enabled)
    sk.lobbyNumber("Lake width", config.mapPreset.lakeWidth,
      p + vec2(0, 232), fieldWidth, 42'f, 120'f, 2'f, enabled)
    sk.lobbyNumber("Lake wobble", config.mapPreset.lakeWobble,
      p + vec2(0, 276), fieldWidth, 0'f, 80'f, 1'f, enabled)
    sk.lobbyNumber("Camp size", config.mapPreset.campRadius,
      p + vec2(0, 320), fieldWidth, 20'f, 40'f, 1'f, enabled)
    sk.lobbyNumber("Camp scatter", config.mapPreset.campScatter,
      p + vec2(0, 364), fieldWidth, 0'f, 60'f, 1'f, enabled)
    sk.lobbyNumber("Stem length", config.mapPreset.stemLength,
      p + vec2(0, 408), fieldWidth, 30'f, 80'f, 1'f, enabled)
    sk.lobbyNumber("Jungle roads", config.mapPreset.jungleRoads,
      p + vec2(0, 452), fieldWidth, 18, 50, 2, enabled)
    sk.lobbyNumber("Lake crossings", config.mapPreset.lakeCrossings,
      p + vec2(0, 496), fieldWidth, 0, 6, 2, enabled)
  else:
    sk.lobbyNumber("Day count", config.dayCount, p + vec2(0, 64),
      fieldWidth, 0'i32, 100'i32, 1'i32, enabled)
    sk.lobbyLabel("0 uses the normal day / night cycle.",
      p + vec2(0, 112), fieldWidth, tint = LobbyMuted)
    sk.lobbyNumber("Headless tick rate", config.headlessTickRate,
      p + vec2(0, 176), fieldWidth, 0'i32, 10000'i32, 24'i32, enabled)
    sk.lobbyLabel("Only used for headless matches.",
      p + vec2(0, 224), fieldWidth, tint = LobbyMuted)
    if sk.lobbyButton("Reset map defaults", p + vec2(0, 316),
      fieldWidth, "terrain", enabled):
        config.mapPreset = defaultConfig()
  if sk.lobbyButton(
    if ui.configPage == 1: "Back to match settings" else: "Map generation",
    p + vec2(0, 574), fieldWidth, "terrain"
  ):
    ui.configPage = if ui.configPage == 1: 0 else: 1
  if sk.lobbyButton(
    if ui.configPage == 2: "Back to match settings" else: "Advanced settings",
    p + vec2(0, 622), fieldWidth, "settings"
  ):
    ui.configPage = if ui.configPage == 2: 0 else: 2
  result = config != before

proc rosterPanel*(sk: Silky, layout: LobbyLayout) =
  ## Draws the team headings over the ten-seat grid.
  sk.lobbyPanel(layout.left, vec2(layout.leftWidth, LobbyPanelHeight))
  sk.lobbyIcon("tower", layout.left + vec2(24, 24), 36, LobbyRed)
  sk.lobbyLabel("RED TEAM", layout.left + vec2(70, 22), 280,
    "LobbyHeading", LobbyRed)
  sk.lobbyIcon("tower", layout.left + vec2(layout.leftWidth / 2 + 24, 24),
    36, LobbyBlue)
  sk.lobbyLabel("BLUE TEAM",
    layout.left + vec2(layout.leftWidth / 2 + 70, 22), 300,
    "LobbyHeading", LobbyBlue)

proc seatButton*(
    sk: Silky, layout: LobbyLayout, index: int,
    name, owner: string, human, empty, editable: bool
): bool =
  ## Tints each seat and its icon by team with standard button interaction.
  let
    width = (layout.leftWidth - 60) / 2
    at = layout.left + vec2(20 + float32(index div 5) * (width + 20),
      84 + float32(index mod 5) * 88)
    tint = if index < 5: LobbyRed else: LobbyBlue
    icon = if empty: "cross" elif human: "character" else: "settings"
  result = sk.lobbyButton(
    "",
    at,
    width,
    enabled = editable,
    height = 78,
    tint = tint
  )
  sk.lobbyLabel($(index + 1), at + vec2(10, 19), 30, "LobbyBold", tint)
  sk.lobbyIcon(icon, at + vec2(44, 22), 32, tint)
  sk.lobbyLabel(name, at + vec2(88, 6), width - 130, "LobbyBold")
  sk.lobbyLabel(owner, at + vec2(88, 37), width - 130,
    tint = LobbyMuted)
  sk.lobbyIcon("chevron_down", at + vec2(width - 34, 25), 22)

proc seatPicker*(
    sk: Silky, window: Window, ui: var LobbyUi, bots: openArray[LocalPolicy]
): SlotChoice =
  ## Offers local human and bot choices in a modal using existing theme art.
  if ui.selectedSeat < 0:
    return
  sk.pushLayer(PopupsLayer)
  let
    view = window.size.vec2 / sk.uiScale
    at = (view - vec2(520, 480)) * 0.5'f
  discard sk.interact(rect(vec2(0), view), true)
  sk.drawRect(vec2(0), view, rgbx(0, 0, 0, 180))
  sk.lobbyPanel(at, vec2(520, 480))
  sk.lobbyLabel("PLAYER " & $(ui.selectedSeat + 1), at + vec2(24, 16),
    400, "LobbyHeading")
  if sk.lobbyButton("Play as you", at + vec2(24, 72), 472, "character"):
    result = SlotChoice(chosen: true, human: true)
  for i, bot in bots:
    if i >= 4:
      break
    if sk.lobbyButton(bot.name, at + vec2(24, 124 + i.float32 * 48),
      472, "settings"):
        result = SlotChoice(chosen: true, bot: i)
  if sk.lobbyButton("Choose local .bas / .zip...", at + vec2(24, 324),
    472, "cross"):
      result = SlotChoice(chosen: true, file: true)
  if sk.lobbyButton("Clear slot", at + vec2(24, 376), 226, "minus"):
    result = SlotChoice(chosen: true, clear: true)
  if sk.lobbyButton("Cancel", at + vec2(270, 376), 226, "arrow_left") or
    window.buttonPressed[KeyEscape]:
      ui.selectedSeat = -1
  sk.popLayer()
