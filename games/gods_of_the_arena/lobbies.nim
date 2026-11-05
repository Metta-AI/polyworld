import
  chroma, silky, vmath, windy,
  presets, generation/[maps, tiles]
import polyworld/lobbies as sharedLobbies

export sharedLobbies except LobbyUi

# Start is the primary action; brighten its tint without changing status pips.
const StartGameGreen* = rgbx(143, 255, 162, 255)

type
  DraftChoice = enum
    Unique = "Unique", Team = "Team", Open = "Open"
  LobbyUi* = object of sharedLobbies.LobbyUi
    draft: DraftChoice
    previewConfig: MapConfig
    preview: TileGrid

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
    at: Vec2, width, height: float32, enabled: bool
): bool =
  ## Edits typed match controls without exposing the serialized room payload.
  let before = config
  sk.lobbyPanel(at, vec2(width, height))
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
    p + vec2(0, height - 138), fieldWidth, "terrain"
  ):
    ui.configPage = if ui.configPage == 1: 0 else: 1
  if sk.lobbyButton(
    if ui.configPage == 2: "Back to match settings" else: "Advanced settings",
    p + vec2(0, height - 90), fieldWidth, "settings"
  ):
    ui.configPage = if ui.configPage == 2: 0 else: 2
  result = config != before
