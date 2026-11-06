import
  bumpy, chroma, silky, vmath, windy,
  polyworld/rooms,
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

type KickMenu* = object
  target*: uint32
  at*: Vec2
  room*: string
  botSeat*: int = -1
  local*: bool

proc defaultGameName*(player: string): string =
  ## Preserve the display name exactly, including punctuation and Unicode.
  player & "'s game"

proc canEditGameName*(snapshot: RoomMessage, self: uint32): bool =
  ## Guests always see authoritative read-only settings.
  snapshot.phase == Lobby and snapshot.participant == self

proc canKick*(snapshot: RoomMessage, self, target: uint32): bool =
  ## Match the relay's lobby-owner authorization, never offering self removal.
  if snapshot.phase != Lobby or snapshot.participant != self or
    target == 0 or target == self:
      return false
  for participant in snapshot.participants:
    if participant.id == target:
      return true

proc openSeatContext*(menu: var KickMenu, snapshot: RoomMessage,
    self: uint32, seatIndex: int, at: Vec2): bool =
  ## Human actions target a participant; bot actions target exactly one seat.
  menu = KickMenu()
  if snapshot.phase != Lobby or snapshot.participant != self or
    seatIndex notin 0 ..< snapshot.seats.len:
    return false
  let seat = snapshot.seats[seatIndex]
  if seat.owner == 0:
    return false
  if seat.name == "Human":
    if not snapshot.canKick(self, seat.owner):
      return false
  elif self != seat.owner and self != snapshot.participant:
    return false
  menu = KickMenu(target: seat.owner, room: snapshot.room, at: at,
    botSeat: if seat.name == "Human": -1 else: seatIndex)
  true

proc openLocalBot*(menu: var KickMenu, seat: int, occupiedBot: bool,
    at: Vec2): bool =
  menu = KickMenu()
  if occupiedBot and seat >= 0:
    menu = KickMenu(target: 1, local: true, botSeat: seat, at: at)
    return true

proc contextLabel*(menu: KickMenu): string =
  if menu.botSeat >= 0: "Remove bot" else: "Kick player"

proc canUseContext*(menu: KickMenu, snapshot: RoomMessage, self: uint32): bool =
  ## Revalidate the room, owner and slot kind against the latest snapshot.
  if menu.local or menu.target == 0 or snapshot.room != menu.room or
    snapshot.phase != Lobby or snapshot.participant != self:
      return false
  if menu.botSeat < 0:
    return snapshot.canKick(self, menu.target)
  if menu.botSeat >= snapshot.seats.len:
    return false
  let seat = snapshot.seats[menu.botSeat]
  seat.owner == menu.target and seat.name != "Human" and
    (self == seat.owner or self == snapshot.participant)

proc contextCommand*(menu: KickMenu, snapshot: RoomMessage,
    self: uint32): RoomMessage =
  doAssert menu.canUseContext(snapshot, self)
  if menu.botSeat >= 0:
    RoomMessage(kind: ReleaseSeat, seat: uint32(menu.botSeat))
  else:
    RoomMessage(kind: KickParticipant, participant: menu.target)

proc dismissKick*(menu: var KickMenu, mouse: Vec2, escape, pressed: bool) =
  ## Keep inside clicks available for the popup button; dismiss outside presses.
  if escape or (pressed and not overlaps(mouse, rect(menu.at, vec2(220, 52)))):
    menu.target = 0

proc lobbySeatBounds*(layout: LobbyLayout, index: int): Rect =
  ## Use the same two-column geometry as the shared seat renderer.
  let width = (layout.leftWidth - 60) / 2
  rect(layout.left + vec2(20 + float32(index div 5) * (width + 20),
    84 + float32(index mod 5) * 88), vec2(width, 78))

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

proc settingsFooter*(at: Vec2, height: float32, named: bool): tuple[map, advanced: Vec2] =
  ## Anchor navigation to the panel, not the optional game-name content row.
  (at + vec2(22, height - 114), at + vec2(22, height - 66))

proc configPanel*(
    sk: Silky, window: Window, ui: var LobbyUi, config: var GotaConfig,
    at: Vec2, width, height: float32, enabled: bool,
    gameName: ptr string = nil, showControls = true
): bool =
  ## Edits typed match controls without exposing the serialized room payload.
  let
    before = config
    page = if showControls: ui.configPage else: 0
  sk.lobbyPanel(at, vec2(width, height))
  let
    p = at + vec2(22, if gameName != nil: 66 else: 22)
    fieldWidth = width - 44
  sk.lobbyIcon("settings", p + vec2(0, 7))
  sk.lobbyLabel("MATCH SETTINGS", p + vec2(40, 0), fieldWidth - 40,
    "LobbyHeading")
  if gameName != nil:
    if enabled:
      sk.lobbyInput(window, "matchGameName", gameName[], at + vec2(22, 10), width - 44)
    else:
      sk.lobbyLabel(gameName[], at + vec2(22, 10), width - 44)
  if page == 0:
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
  elif page == 1:
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
  if showControls:
    if sk.lobbyButton(
      if ui.configPage == 1: "Back to match settings" else: "Map generation",
      settingsFooter(at, height, gameName != nil).map, fieldWidth, "terrain"
    ):
      ui.configPage = if ui.configPage == 1: 0 else: 1
    if sk.lobbyButton(
      if ui.configPage == 2: "Back to match settings" else: "Advanced settings",
      settingsFooter(at, height, gameName != nil).advanced, fieldWidth, "settings"
    ):
      ui.configPage = if ui.configPage == 2: 0 else: 2
  result = config != before
