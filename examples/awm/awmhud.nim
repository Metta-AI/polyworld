## Screen-space HUD only. Included after hudSize; no world or camera state.

const
  HudIvory = rgbx(244, 228, 192, 255)
  HudMuted = rgbx(178, 177, 161, 255)
  HudGold = rgbx(215, 181, 112, 255)
  HudHelperY = 324'f32
  HudClassInk: array[HeroClass, ColorRGBX] = [
    rgbx(142, 199, 146, 255), rgbx(227, 127, 104, 255),
    rgbx(156, 175, 234, 255)]
  HudClassIcon: array[HeroClass, string] = [
    "class-archer", "class-warrior", "class-mage"]

proc addAwmHudAssets(builder: AtlasBuilder, cardRoot: string) =
  let hudRoot = cardRoot.parentDir / "ui/hud"
  for name in ["player-panel", "class-archer", "class-warrior", "class-mage",
      "life-heart", "energy-gem", "energy-glow", "energy-ready", "energy-spent", "energy-locked",
      "turn-plaque", "turn-active", "turn-waiting", "button", "button-hover",
      "button-disabled", "pile-label", "notice", "status-line"]:
    if not builder.addImage("hud/" & name, readImage(hudRoot / (name & ".svg"))):
      raise newException(IOError, "AWM HUD does not fit the UI atlas")
  let heading = cardRoot / "fonts/Grenze-SemiBold.ttf"
  builder.addFont(heading, "Display", 94)
  builder.addFont(heading, "TurnState", 45)
  builder.addFont(heading, "Prompt", 32)
  builder.addFont(heading, "Heading", 36)
  builder.addFont(heading, "Class", 32)
  builder.addFont(heading, "Number", 48)
  builder.addFont(heading, "Action", 48)

proc hudSprite(sk: Silky, name: string, origin, size: Vec2,
    tint = rgbx(255, 255, 255, 255), flipX = false) =
  let entry = sk.atlas.entries["hud/" & name]
  let
    uvX = if flipX: entry.x + entry.width else: entry.x
    uvWidth = if flipX: -entry.width else: entry.width
  sk.drawQuad(origin, size, vec2(uvX.float32, entry.y.float32),
    vec2(uvWidth.float32, entry.height.float32), tint)

proc finishRect(window: Window): UiRect =
  UiRect(origin: vec2(hudSize(window).x - 496, hudSize(window).y - 194),
    size: vec2(460, 126))

proc drawButton(sk: Silky, window: Window, rect: UiRect, label: string,
    enabled = true): bool =
  let hovered = rect.contains(sk.mousePos)
  sk.hudSprite(if not enabled: "button-disabled"
    elif hovered: "button-hover" else: "button", rect.origin, rect.size)
  sk.drawLabel(label, rect.origin + vec2(18, 0), rect.size - vec2(36, 0),
    if enabled: HudIvory else: HudMuted, "Action", CenterAlign)
  enabled and hovered and window.buttonPressed[MouseLeft]

proc drawHudNotice(sk: Silky, rect: UiRect) =
  sk.hudSprite("notice", rect.origin, rect.size)

proc drawPlayerPanel(sk: Silky, window: Window, game: GameState,
    playerIndex: int, human: bool, time: float32) =
  let
    origin = vec2(if playerIndex == 0: 24'f32
      else: hudSize(window).x - PlayerPanelWidth - 24, 18)
    player = game.players[playerIndex]
    active = playerIndex == game.currentPlayer
    name = if human: (if playerIndex == 0: "YOU" else: "OPPONENT")
      else: "PLAYER " & $(playerIndex + 1)
    mirrored = playerIndex == 1
    alignment = if mirrored: RightAlign else: LeftAlign
    # A four-second breath; only opacity changes, so the gems stay steady.
    glow = rgbx(255, 255, 255, uint8(135 + 65 * sin(time * PI.float32 / 2)))
    energyX = if mirrored: 30'f32 else: 438'f32
  template panelX(x, width: float32): float32 =
    (if mirrored: PlayerPanelWidth - x - width else: x)
  sk.hudSprite("player-panel", origin, vec2(PlayerPanelWidth, PlayerPanelHeight),
    flipX = mirrored)
  sk.hudSprite(HudClassIcon[player.heroClass], origin + vec2(panelX(14, 90), 4), vec2(90, 124))
  sk.drawLabel(name, origin + vec2(panelX(124, 176), 19), vec2(176, 43),
    HudIvory, "Heading", alignment)
  sk.drawLabel(player.heroClass.className(), origin + vec2(panelX(124, 176), 66),
    vec2(176, 42), HudClassInk[player.heroClass], "Class", alignment)
  if active:
    sk.drawRect(origin + vec2(panelX(124, 156), 118), vec2(156, 1), rgbx(207, 167, 93, 160))
  sk.hudSprite("life-heart", origin + vec2(panelX(306, 104), 16), vec2(104))
  sk.drawLabel($player.life, origin + vec2(panelX(311, 94), 24), vec2(94, 65),
    HudIvory, "Number", CenterAlign)
  sk.hudSprite("energy-glow", origin + vec2(energyX - 24, 5), vec2(81), glow)
  sk.hudSprite("energy-gem", origin + vec2(energyX, 29), vec2(33))
  sk.drawLabel($player.energy & " / " & $player.totalEnergy,
    origin + vec2(energyX + 47, 21), vec2(158, 50), HudIvory, "Heading")
  # Reserve all ten slots. Earned but spent gems are visibly different from
  # future capacity; totals above ten retain the exact numeric meter.
  if player.totalEnergy <= 10:
    for i in 0 ..< 10:
      let sprite = if i < player.energy: "energy-ready"
        elif i < player.totalEnergy: "energy-spent" else: "energy-locked"
      let dot = origin + vec2(energyX + 2 + i.float32 * 21, 88)
      if i < player.energy:
        sk.hudSprite("energy-glow", dot - vec2(11), vec2(40), glow)
      sk.hudSprite(sprite, dot, vec2(18))

proc drawTurnHeader(sk: Silky, window: Window, game: GameState,
    human: bool, status: string) =
  let
    origin = vec2(hudSize(window).x * 0.5'f32 - 364, 12)
    yourTurn = human and game.currentPlayer == 0
    label = if game.gameOver: "MATCH COMPLETE"
      elif human: (if yourTurn: "YOUR TURN" else: "OPPONENT'S TURN")
      else: "PLAYER " & $(game.currentPlayer + 1) & "'S TURN"
    statusWidth = min(920'f32, hudSize(window).x - (PlayerPanelWidth + 52) * 2)
  sk.hudSprite("turn-plaque", origin, vec2(728, 224))
  sk.drawLabel("TURN " & $game.turnNumber, origin + vec2(52, 16),
    vec2(624, 114), HudIvory, "Display", CenterAlign)
  sk.hudSprite(if yourTurn and not game.gameOver: "turn-active" else: "turn-waiting",
    origin + vec2(72, 144), vec2(584, 86))
  sk.drawLabel(label, origin + vec2(100, 144), vec2(528, 86),
    if yourTurn and not game.gameOver: rgbx(42, 32, 18, 255) else: HudGold,
    "TurnState", CenterAlign)
  if status.len > 0:
    sk.hudSprite("status-line",
      vec2((hudSize(window).x - statusWidth) * 0.5'f32 - 16, 258),
      vec2(statusWidth + 32, 50))
  sk.drawLabel(sk.fittedLabel(status, statusWidth, "Small"),
    vec2((hudSize(window).x - statusWidth) * 0.5'f32, 266),
    vec2(statusWidth, 34), HudIvory, "Small", CenterAlign)
