import
  std/strutils,
  bumpy, chroma, pixie, silky, vmath, windy,
  assets, chrome, homes, menus

const
  LobbyCanvas = vec2(1514, 970)
  LobbyPanelHeight = 712.0'f
  LobbyGreen* = rgbx(110, 230, 125, 255)
  LobbyRed* = rgbx(244, 108, 104, 255)
  LobbyBlue* = rgbx(96, 184, 244, 255)
  LobbyMuted* = rgbx(170, 175, 181, 255)

type
  LobbyLayout* = object
    origin*, left*, right*, footer*, primary*: Vec2
    leftWidth*, rightWidth*, panelHeight*: float32
    compact*: bool
  LobbyUi* = object of RootObj
    scroll*: float32
    search*: string
    participantPage*: int
    roomScroll*: FrameState
    roomListOverflow*: bool
    selectedSeat*: int = -1
    selectedBot*: string = "Base bot"
    configPage*: int
  SlotChoice* = object
    chosen*: bool
    human*, clear*, file*: bool
    bot*: int

proc readinessColor*(ready: bool): ColorRGBX =
  ## Keeps the ready button's status pip explicit in either readiness state.
  if ready: LobbyGreen else: LobbyRed

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
    tint = rgbx(255, 255, 255, 255), iconTint = rgbx(0, 0, 0, 0)
): bool =
  ## Uses Silky interaction states and theme patches for an icon button.
  ## Transparent icon tint inherits the text ink; disabled icons stay muted.
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
    sk.lobbyIcon(icon, at + vec2(10, (height - 26) / 2), 26,
      if enabled and iconTint.a > 0: iconTint else: ink)
  sk.drawLabel(
    text,
    at + vec2(inset, 0),
    vec2(width - inset - 10, height),
    ink,
    "LobbyBody",
    CenterAlign
  )
  interaction == Released

proc playerButton*(
  sk: Silky, window: Window, name: string, enabled = true
): bool =
  ## Opens the player profile from the top-right corner of a menu.
  let
    view = window.size.vec2 / sk.uiScale
    label = if name.len == 0: "Player name" else: name
  sk.lobbyButton(
    sk.fittedLabel(label, 180, "LobbyBody"),
    vec2(view.x - 264, 16),
    240,
    "character",
    enabled = enabled
  )

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
  sk.uiScale = selectedUiScale(max(0.1'f, min(
    window.size.x.float32 / canvas.x,
    if result.compact: window.size.x.float32 / canvas.x
    else: window.size.y.float32 / canvas.y
  )), if result.compact: 1920.0'f / canvas.x else: 1080.0'f / canvas.y)
  sk.beginUi(window, window.size)
  sk.textStyle = "LobbyBody"
  let
    view = window.size.vec2 / sk.uiScale
    height = max(canvas.y, view.y)
    top = if multiplayer: 238.0'f else: 150.0'f
    leftWidth = if result.compact: 936.0'f else: 930.0'f
    panelHeight = max(
      if multiplayer: 622.0'f else: LobbyPanelHeight,
      if result.compact: (height - top - 24 - 110) / 2
      else: height - top - 110
    )
    roomList = rect(
      (view.x - canvas.x) / 2 + 54,
      444 - ui.scroll,
      leftWidth - 44,
      panelHeight - 268
    )
    scrollingRooms = multiplayer and ui.roomListOverflow and
      overlaps(sk.mousePos, roomList)
  if not scrollingRooms:
    ui.scroll += window.scrollDelta.y * ScrollSpeed.float32
  ui.scroll = clamp(ui.scroll, 0.0'f, max(0.0'f, canvas.y - view.y))
  result.origin = vec2((view.x - canvas.x) / 2, -ui.scroll)
  sk.drawHomeBackground(window)
  sk.lobbyTitle(title, "battle", result.origin + vec2(canvas.x / 2, 72))
  result.left = result.origin + vec2(32, top)
  result.leftWidth = if result.compact: 936 else: 930
  result.rightWidth = if result.compact: 936 else: 500
  result.panelHeight = panelHeight
  result.right =
    if result.compact: result.left + vec2(0, panelHeight + 24)
    else: result.origin + vec2(982, top)
  result.footer = vec2(result.left.x, result.right.y + panelHeight + 30)
  result.primary = vec2(
    result.right.x + result.rightWidth - 250,
    result.footer.y
  )

proc rosterPanel*(sk: Silky, layout: LobbyLayout) =
  ## Draws the team headings over the ten-seat grid.
  sk.lobbyPanel(layout.left, vec2(layout.leftWidth, layout.panelHeight))
  sk.lobbyIcon("tower", layout.left + vec2(24, 24), 36, LobbyRed)
  sk.lobbyLabel("RED TEAM", layout.left + vec2(70, 22), 280,
    "LobbyHeading", LobbyRed)
  sk.lobbyIcon("tower", layout.left + vec2(layout.leftWidth / 2 + 24, 24),
    36, LobbyBlue)
  sk.lobbyLabel("BLUE TEAM",
    layout.left + vec2(layout.leftWidth / 2 + 70, 22), 300,
    "LobbyHeading", LobbyBlue)

proc seatBackgroundTint*(team: ColorRGBX, empty: bool): ColorRGBX =
  ## Keep empty slots visibly neutral while occupied seats retain team colors.
  if empty: rgbx(116, 116, 116, 255) else: team

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
    tint = seatBackgroundTint(tint, empty)
  )
  sk.lobbyLabel($(index + 1), at + vec2(10, 19), 30, "LobbyBold", tint)
  sk.lobbyIcon(icon, at + vec2(44, 22), 32, if empty: LobbyMuted else: tint)
  sk.lobbyLabel(name, at + vec2(88, 6), width - 130, "LobbyBold",
    if empty: LobbyMuted else: rgbx(240, 237, 225, 255))
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
