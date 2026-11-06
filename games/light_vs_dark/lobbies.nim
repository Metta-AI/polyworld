## LvD's team-free roster and map controls; all menu chrome is shared.
import presets
import polyworld/[rooms, roomclients]

const RosterColumns* = 2

proc defaultGameName*(player: string): string = player & "'s game"

proc canEditGameName*(snapshot: RoomMessage, self: uint32): bool =
  self != 0 and snapshot.room.len > 0 and snapshot.phase == Lobby and
    snapshot.participant == self

proc renameGame*(client: RoomClient, name: string): bool =
  if client == nil or not client.connected or not client.welcomed or
      not client.snapshot.canEditGameName(client.participant):
    return false
  if not name.validName:
    client.error = "Game name must contain visible text and no control characters"
    return false
  if name.len > 128:
    client.error = "Game name must be at most 128 UTF-8 bytes"
    return false
  if name == client.snapshot.name: return false
  client.error = ""
  # Reuse the authoritative settings verbatim: local map/roster drafts must
  # never become an accidental settings change when Enter submits the name.
  client.send(RoomMessage(kind: ResizeRoom, name: name,
    payload: client.snapshot.payload, number: uint32(client.snapshot.seats.len),
    tickRate: client.snapshot.tickRate, flag: client.snapshot.flag))
  return true

proc previewMap*(config: LvdConfig): MapData =
  config.validate()
  generateMap(config.seed, config.playerCount, config.mapSettings)

proc rosterColumn*(index: int): int = index mod RosterColumns

proc humanAfterRemoval*(human, removed: int): int =
  if human == removed: -1
  elif human > removed: human - 1
  else: human

when not defined(headless):
  import bumpy, chroma, silky, vmath, windy
  import polyworld/[menus, inputs]
  import polyworld/lobbies as sharedLobbies
  import content, factions, shortcutsettings
  export sharedLobbies

  const LvdControlProfile* = block:
    var profile = ControlProfile(defaults: DefaultBindings)
    profile.defaults[SelectInput] = [MouseLeft, ButtonUnknown]
    profile.defaults[AttackMoveInput] = [KeyA, ButtonUnknown]
    profile.defaults[OrderInput] = [MouseRight, KeyD]
    profile.defaults[PanInput] = [MouseMiddle, ButtonUnknown]
    profile.defaults[CameraInput] = [KeyC, ButtonUnknown]
    profile.defaults[StopInput] = [KeyS, KeyX]
    for action in [SelectInput, OrderInput, PanInput, CameraInput, PauseInput,
      MenuInput, DebugInput, FullscreenInput, PanLeftInput, PanRightInput,
      PanUpInput, PanDownInput, ShiftInput, ControlInput, ShadingInput,
      TraceInput, ZoomInInput, ZoomOutInput]:
      profile.actions.add ControlBinding(action: action, label: $action)
    profile.actions.add ControlBinding(action: AttackMoveInput, label: "Attack move / click destination")
    profile.actions.add ControlBinding(action: StopInput, label: "Stop selected / cancel construction")
    profile

  proc migrateLvdBindings*(bindings: var InputBindings) =
    ## Upgrade only exact legacy defaults, preserving custom bindings.
    if bindings[StopInput] == [KeyX, ButtonUnknown]:
      bindings[StopInput] = LvdControlProfile.defaults[StopInput]
    if bindings[PanInput] == [MouseMiddle, KeyS]:
      bindings[PanInput] = LvdControlProfile.defaults[PanInput]
    if bindings[SelectInput] == [MouseLeft, KeyA] and
        bindings[AttackMoveInput] == [KeyA, ButtonUnknown]:
      bindings[SelectInput][1] = ButtonUnknown

  proc readLvdPreferences*(): Preferences =
    loadLvdShortcuts()
    result = readPreferences("Polyworld LvD")
    if getConfig("Polyworld LvD", "settings.json").len == 0:
      result.bindings = LvdControlProfile.defaults
    else:
      result.bindings.migrateLvdBindings()


  proc lvdSettingsPanel*(sk: Silky, window: Window,
      preferences: var Preferences, app: string, origin: Vec2,
      title = "Settings", height = 440.0'f): bool =
    sk.settingsPanel(window, preferences, app, origin, title, height,
      LvdControlProfile, lvdShortcutExtension())

  proc lvdRosterPanel*(sk: Silky, layout: LobbyLayout) =
    sk.lobbyPanel(layout.left, vec2(layout.leftWidth, layout.panelHeight))
    sk.lobbyIcon("units", layout.left + vec2(24, 24), 36)
    sk.lobbyLabel("PLAYERS", layout.left + vec2(70, 22), 600, "LobbyHeading")
    sk.lobbyLabel("Each player commands an independent faction.",
      layout.left + vec2(24, 68), layout.leftWidth - 48, tint = LobbyMuted)

  proc rosterCardSize*(layout: LobbyLayout): Vec2 =
    ## Match GotA's compact two-line seat dimensions.
    vec2((layout.leftWidth - 60) / RosterColumns.float32, 78)

  proc rosterCardPosition*(layout: LobbyLayout, index: int, scroll = 0.0'f): Vec2 =
    layout.left + vec2(20 + rosterColumn(index).float32 *
      (rosterCardSize(layout).x + 20),
      132 + (index div RosterColumns).float32 * 88 - scroll)

  proc rosterControlsPosition*(layout: LobbyLayout): Vec2 =
    layout.left + vec2(24, layout.panelHeight - 220)

  proc rosterViewport*(layout: LobbyLayout): Rect =
    ## Leave room for the fixed resize/fill controls and the right scrollbar.
    rect(rosterCardPosition(layout, 0),
      vec2(layout.leftWidth - 24, layout.panelHeight - 364))

  proc rosterCardHit*(layout: LobbyLayout, index: int, scroll: float32,
      mouse: Vec2): bool =
    ## Right-click picking uses exactly the visible roster clip, not hidden rows.
    let viewport = rosterViewport(layout)
    overlaps(mouse, rect(viewport.xy, viewport.wh - vec2(16, 0))) and
      overlaps(mouse, rect(rosterCardPosition(layout, index, scroll),
        rosterCardSize(layout)))

  proc rosterContentHeight*(count: int): float32 =
    max(0, ((count + RosterColumns - 1) div RosterColumns) * 88 - 10).float32

  proc rosterScrollPosition*(layout: LobbyLayout, count: int, scroll: float32): float32 =
    clamp(scroll, 0.0'f, max(0.0'f, rosterContentHeight(count) - rosterViewport(layout).h))

  proc rosterOwnsScroll*(layout: LobbyLayout, count: int, mouse: Vec2): bool =
    rosterContentHeight(count) > rosterViewport(layout).h and
      overlaps(mouse, rosterViewport(layout))

  proc pushRosterClip*(sk: Silky, layout: LobbyLayout) =
    let viewport = rosterViewport(layout)
    sk.pushClipRect(rect(viewport.xy, viewport.wh - vec2(16, 0)))

  proc beginLvdBattle*(sk: Silky, window: Window, ui: var LobbyUi,
    count: int, contextOpen = false): LobbyLayout =
    ## The nested roster consumes its wheel gesture, not the portrait page.
    let previousScroll = ui.scroll
    result = sk.beginLobby(window, ui, "BATTLE SETUP")
    let correction = vec2(0, ui.scroll - previousScroll)
    var previousLayout = result
    previousLayout.left += correction
    if window.scrollDelta.y != 0 and (contextOpen or ui.selectedSeat != -1 or
      rosterOwnsScroll(previousLayout, count, sk.mousePos)):
      ui.scroll = previousScroll
      result.origin += correction
      result.left += correction
      result.right += correction
      result.footer += correction
      result.primary += correction

  proc beginRoster*(sk: Silky, window: Window, layout: LobbyLayout,
    state: FrameState, count: int, enabled: bool) =
    let viewport = rosterViewport(layout)
    state.scrollPos = vec2(0, rosterScrollPosition(layout, count, state.scrollPos.y))
    if enabled:
      sk.frameScrollbars(window, state, viewport,
        vec2(viewport.w, rosterContentHeight(count)), vec2(1))
    sk.pushRosterClip(layout)

  proc rosterColor*(seed: int32, player: int): ColorRGBX =
    ## Use the exact seeded faction assignment used by runGraphics.
    let order = factionOrder(seed.int64)
    FactionColors[order[Faction(player mod FactionFiles.len)]]

  proc seatWellTint*(empty: bool, faction: ColorRGBX): ColorRGBX =
    if empty: rgbx(65, 65, 65, 255) else: faction

  proc seatButton*(sk: Silky, layout: LobbyLayout, index: int, scroll: float32,
    name, owner: string, human, empty, editable: bool, seed: int32): bool =
    let
      size = rosterCardSize(layout)
      at = rosterCardPosition(layout, index, scroll)
      tint = rosterColor(seed, index)
      edge = if empty: rgbx(tint.r div 3, tint.g div 3, tint.b div 3, 255) else: tint
      ink = if empty: LobbyMuted else: tint
    result = sk.lobbyButton("", at, size.x, enabled = editable,
      height = size.y, tint = seatWellTint(empty, tint))
    # Explicit color edging remains readable even on the disabled theme patch.
    sk.drawRect(at, vec2(size.x, 2), edge)
    sk.drawRect(at + vec2(0, size.y - 2), vec2(size.x, 2), edge)
    sk.drawRect(at, vec2(2, size.y), edge)
    sk.drawRect(at + vec2(size.x - 2, 0), vec2(2, size.y), edge)
    sk.lobbyLabel($(index + 1), at + vec2(10, 19), 30, "LobbyBold", ink)
    sk.lobbyIcon(if empty: "cross" elif human: "character" else: "settings",
      at + vec2(44, 22), 32, ink)
    sk.lobbyLabel(name, at + vec2(88, 6), size.x - 130, "LobbyBold",
      if empty: LobbyMuted else: rgbx(240, 237, 225, 255))
    sk.lobbyLabel(owner, at + vec2(88, 37), size.x - 130, tint = LobbyMuted)
    sk.lobbyIcon("chevron_down", at + vec2(size.x - 34, 25), 22)

  var
    cachedPreview: MapData
    previewSeed: int32
    previewPlayers: int
    previewSettings: MapSettings
    previewError: string

  proc drawMapPreview(sk: Silky, config: LvdConfig, at: Vec2, width: float32) =
    if cachedPreview.side == 0 or previewSeed != config.seed or
      previewPlayers != config.playerCount or previewSettings != config.mapSettings:
      previewSeed = config.seed
      previewPlayers = config.playerCount
      previewSettings = config.mapSettings
      try:
        cachedPreview = previewMap(config)
        previewError = ""
      except CatchableError as error:
        previewError = error.msg
    if previewError.len > 0:
      sk.lobbyLabel(previewError, at, width, tint = LobbyRed)
      return
    let side = cachedPreview.side
    let step = max(1'i32, side div 64)
    let cell = 126.0'f / side.float32
    for y in countup(0'i32, side - 1, step):
      for x in countup(0'i32, side - 1, step):
        let i = int(y * side + x)
        let tint = if cachedPreview.treeWood[i] > 0: rgbx(36, 87, 49, 255)
          elif cachedPreview.passable[i] == 0: rgbx(77, 75, 83, 255)
          else: rgbx(123, 150, 82, 255)
        sk.drawRect(at + vec2(x.float32, y.float32) * cell,
          vec2(step.float32 * cell + 0.2'f), tint)
    for i, origin in cachedPreview.hallOrigin:
      let point = at + vec2(origin.x.float32, origin.y.float32) * cell
      sk.drawRect(point - vec2(2), vec2(5), rgbx(244, 215, 98, 255))
    sk.lobbyLabel("Generated map", at + vec2(142, 8), width - 142, "LobbyBold")
    sk.lobbyLabel($side & " x " & $side & " tiles", at + vec2(142, 48), width - 142)
    sk.lobbyLabel($config.playerCount & " factions", at + vec2(142, 88), width - 142)

  proc settingsFooter*(at: Vec2, height: float32): tuple[map, advanced: Vec2] =
    (at + vec2(22, height - 114), at + vec2(22, height - 66))

  proc configPanel*(sk: Silky, window: Window, ui: var LobbyUi,
    config: var LvdConfig, at: Vec2, width, height: float32,
    enabled: bool, showControls = true, gameName: ptr string = nil): bool =
    let before = config
    sk.lobbyPanel(at, vec2(width, height))
    let p = at + vec2(22, if gameName != nil: 74 else: 22)
    let w = width - 44
    let page = if showControls: ui.configPage else: 0
    sk.lobbyLabel("MATCH SETTINGS", p, w, "LobbyHeading")
    if gameName != nil:
      if enabled:
        sk.lobbyInput(window, "matchGameName", gameName[], at + vec2(22, 12), w)
      else:
        sk.lobbyLabel(gameName[], at + vec2(22, 12), w)
    if page == 0:
      sk.drawMapPreview(config, p + vec2(0, 64), w)
      if showControls:
        sk.lobbyNumber("Map seed", config.seed, p + vec2(0, 214), w,
          0'i32, int32.high - 1, 1'i32, enabled)
        sk.lobbyNumber("Max ticks", config.maxTicks, p + vec2(0, 266), w,
          TickRate, TickRate * 3600, TickRate * 60, enabled)
      else:
        sk.lobbyLabel("Map seed: " & $config.seed, p + vec2(0, 214), w)
        sk.lobbyLabel("Max ticks: " & $config.maxTicks, p + vec2(0, 266), w)
        sk.lobbyLabel("Layout: " & $config.mapSettings.layout, p + vec2(0, 318), w)
    elif page == 1:
      sk.lobbyLabel("Layout", p + vec2(0, 64), 190)
      sk.lobbySelect(window, config.mapSettings.layout, [SpokeLayout, RandomLayout],
        p + vec2(196, 64), w - 196, enabled)
      sk.lobbyNumber("Map size", config.mapSettings.size, p + vec2(0, 116), w,
        32'i32, 4096'i32, 2'i32, enabled)
      sk.lobbyNumber("Expansions", config.mapSettings.expansions, p + vec2(0, 168), w,
        0'i32, 8'i32, 1'i32, enabled)
      sk.lobbyNumber("Spawn distance", config.mapSettings.minDistance,
        p + vec2(0, 220), w, 1'i32, 4096'i32, 1'i32, enabled)
    else:
      sk.lobbyNumber("War grace (s)", config.diplomacySettings.warGraceSeconds,
        p + vec2(0, 64), w, 1'i32, 300'i32, 1'i32, enabled)
      sk.lobbyNumber("Offer time (s)", config.diplomacySettings.offerSeconds,
        p + vec2(0, 116), w, 1'i32, 600'i32, 5'i32, enabled)
    if showControls:
      if sk.lobbyButton(if page == 1: "Back to match settings" else: "Map generation",
        settingsFooter(at, height).map, w, "terrain", enabled):
        ui.configPage = if page == 1: 0 else: 1
      if sk.lobbyButton(if page == 2: "Back to match settings" else: "Advanced settings",
        settingsFooter(at, height).advanced, w, "settings", enabled):
        ui.configPage = if page == 2: 0 else: 2
    result = config != before
