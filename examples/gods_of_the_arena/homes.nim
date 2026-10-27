import
  pixie, silky, vmath, windy,
  polyworld/[chrome, menus],
  assets

const
  HomeSize = vec2(1672, 941)
  HomeLabels = ["Single Player", "Multiplayer", "Settings", "Exit"]

type HomeAction* = enum
  StayHome, PlaySingle, PlayMultiplayer, OpenSettings, ExitGame

proc addHomeAssets*(builder: AtlasBuilder) =
  ## Packs the generated menu art, trimming empty space around button faces.
  let
    shade = newImage(256, 256)
    gradient = newPaint(RadialGradientPaint)
  gradient.gradientHandlePositions = @[
    vec2(128, 128), vec2(256, 128), vec2(128, 256)
  ]
  gradient.gradientStops = @[
    ColorStop(color: color(0, 0, 0, 0.68), position: 0),
    ColorStop(color: color(0, 0, 0, 0.42), position: 0.5),
    ColorStop(color: color(0, 0, 0, 0), position: 1)
  ]
  shade.fill(gradient)
  if not builder.addImage("home-shade", shade):
    raise newException(MenusError, "The UI atlas is too small for menu shade")
  for i, name in MenuImages:
    var picture = readImage(MenuRoot & name & ".png")
    if i >= 2:
      var
        left = picture.width
        top = picture.height
        right, bottom: int
      for y in 0 ..< picture.height:
        for x in 0 ..< picture.width:
          if picture[x, y].a > 200:
            left = min(left, x)
            top = min(top, y)
            right = max(right, x)
            bottom = max(bottom, y)
      if left > right or top > bottom:
        raise newException(MenusError, "Empty GotA menu button: " & name)
      let padding = max(1, picture.width div 200)
      left = max(0, left - padding)
      top = max(0, top - padding)
      right = min(picture.width - 1, right + padding)
      bottom = min(picture.height - 1, bottom + padding)
      picture = picture.subImage(left, top, right - left + 1, bottom - top + 1)
    let
      limit = if i == 0: 1672 else: 768
      ratio = min(1.0, limit.float / picture.width.float)
    picture = picture.resize(
      max(1, int(picture.width.float * ratio)),
      max(1, int(picture.height.float * ratio))
    )
    if not builder.addImage("home-" & name, picture):
      raise newException(MenusError, "The UI atlas is too small for menu art")

proc drawHome*(sk: Silky, window: Window, focus: var int): HomeAction =
  ## Draws the centered arena menu with pointer and keyboard navigation.
  sk.uiScale = max(0.1'f, min(
    window.size.x.float32 / 720,
    window.size.y.float32 / HomeSize.y
  ))
  sk.beginUi(window, window.size)
  sk.mousePos = window.mousePos.vec2 / sk.uiScale
  let
    size = window.size.vec2 / sk.uiScale
    origin = (size - HomeSize) * 0.5'f
    backdrop = HomeSize * max(size.x / HomeSize.x, size.y / HomeSize.y)
    count = when defined(emscripten): 3 else: 4
  sk.clearScreen(rgbx(12, 18, 23, 255))
  sk.drawSprite("home-background", (size - backdrop) * 0.5'f, backdrop)
  sk.drawRect(vec2(0), size, rgbx(8, 12, 22, 35))
  sk.drawSprite("home-shade", origin + vec2(386, 95), vec2(900, 850))
  sk.drawSprite("home-logo", origin + vec2(536, 30), vec2(600, 400))
  sk.drawLabel("Polyworld", origin + vec2(536, 437), vec2(600, 36),
    rgbx(222, 222, 218, 255), "Bold", CenterAlign)
  if window.buttonPressed[KeyUp]:
    focus = (focus + count - 1) mod count
  if window.buttonPressed[KeyDown] or window.buttonPressed[KeyTab]:
    focus = (focus + 1) mod count
  for i in 0 ..< count:
    let
      position = origin + vec2(596, 490 + i.float32 * 86)
      buttonSize = vec2(480, 76)
      hovered = sk.mousePos.x >= position.x and
        sk.mousePos.x < position.x + buttonSize.x and
        sk.mousePos.y >= position.y and
        sk.mousePos.y < position.y + buttonSize.y
    if hovered and window.mouseDelta != ivec2(0):
      focus = i
    let
      active = hovered or focus == i
      tint = if active: 255'u8 else: 226'u8
      ink = if i == 0: rgbx(39, 24, 10, 255) else: rgbx(255, 242, 213, 255)
    sk.drawSprite(
      "home-" & MenuImages[i + 2], position, buttonSize,
      rgbx(tint, tint, tint, 255)
    )
    sk.drawLabel(HomeLabels[i], position, buttonSize, ink, "H1", CenterAlign)
    if (hovered and window.buttonReleased[MouseLeft]) or
      (focus == i and window.buttonPressed[KeyEnter]):
        result = HomeAction(i + 1)
