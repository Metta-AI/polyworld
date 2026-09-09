## Shared screen anchoring and replay transport state for Polyworld games.

import std/math, vmath

type
  GameUiRegion* {.pure.} = enum
    TopLeft
    TopCenter
    TopRight
    CenterLeft
    Center
    CenterRight
    BottomLeft
    BottomCenter
    BottomRight

  GameUiPanel* = object
    origin*: Vec2
    size*: Vec2

  GameUiLayout* = object
    size*: Vec2
    margin*: float32
    transportHeight*: float32
    safeInsets*: Vec4  ## Left, top, right, bottom in UI layout units.

  ReplayTransport* = object
    playing*: bool
    tick*: int
    lastTick*: int

proc initGameUiLayout*(
    size: Vec2,
    transportHeight = 0.0'f32,
    margin = 10.0'f32,
    safeInsets = vec4(0)
): GameUiLayout =
  ## Creates a nine-region layout above an optional bottom transport ribbon.
  result.size = max(size, vec2(0))
  result.margin = max(margin, 0)
  result.safeInsets.x = clamp(safeInsets.x, 0, result.size.x)
  result.safeInsets.y = clamp(safeInsets.y, 0, result.size.y)
  result.safeInsets.z = clamp(safeInsets.z, 0, result.size.x - result.safeInsets.x)
  result.safeInsets.w = clamp(safeInsets.w, 0, result.size.y - result.safeInsets.y)
  result.transportHeight = clamp(transportHeight, 0,
    result.size.y - result.safeInsets.y - result.safeInsets.w)

proc gameArea*(layout: GameUiLayout): GameUiPanel =
  ## Usable game rectangle, excluding safe insets and replay transport.
  GameUiPanel(origin: layout.safeInsets.xy, size: vec2(
    layout.size.x - layout.safeInsets.x - layout.safeInsets.z,
    layout.size.y - layout.safeInsets.y - layout.safeInsets.w - layout.transportHeight))

proc gameAreaSize*(layout: GameUiLayout): Vec2 =
  ## Returns the area available to the nine anchored game UI regions.
  layout.gameArea.size

proc panel*(
    layout: GameUiLayout,
    region: GameUiRegion,
    size: Vec2
): GameUiPanel =
  ## Places one game-sized panel in a stable screen region.
  let
    area = layout.gameAreaSize
    panelSize = max(size, vec2(0))
    left = layout.margin
    # Centered plates snap to whole pixels so icons stay crisp.
    centerX = floor((area.x - panelSize.x) * 0.5'f32)
    right = area.x - layout.margin - panelSize.x
    top = layout.margin
    centerY = floor((area.y - panelSize.y) * 0.5'f32)
    bottom = area.y - layout.margin - panelSize.y
  result.size = panelSize
  result.origin =
    case region
    of GameUiRegion.TopLeft:
      vec2(left, top)
    of GameUiRegion.TopCenter:
      vec2(centerX, top)
    of GameUiRegion.TopRight:
      vec2(right, top)
    of GameUiRegion.CenterLeft:
      vec2(left, centerY)
    of GameUiRegion.Center:
      vec2(centerX, centerY)
    of GameUiRegion.CenterRight:
      vec2(right, centerY)
    of GameUiRegion.BottomLeft:
      vec2(left, bottom)
    of GameUiRegion.BottomCenter:
      vec2(centerX, bottom)
    of GameUiRegion.BottomRight:
      vec2(right, bottom)
  result.origin = layout.gameArea.origin + max(result.origin, vec2(0))

proc transportPanel*(layout: GameUiLayout): GameUiPanel =
  ## Returns the full-width panel reserved below the nine game UI regions.
  let area = layout.gameArea
  result.origin = area.origin + vec2(0, area.size.y)
  result.size = vec2(area.size.x, layout.transportHeight)

proc fitPanel*(area: GameUiPanel, origin, size: Vec2): GameUiPanel =
  ## Fits a desired panel to a usable area. Oversized content needs scrolling.
  result.size = min(max(size, vec2(0)), max(area.size, vec2(0)))
  result.origin = clamp(origin, area.origin, area.origin + area.size - result.size)

proc popupPanel*(area, anchor: GameUiPanel, size: Vec2, gap = 8'f32): GameUiPanel =
  ## Places a popup below its anchor, preferring above when below cannot fit.
  ## Final clamping handles edge anchors and popups larger than the viewport.
  var origin = anchor.origin + vec2(0, anchor.size.y + gap)
  if origin.y + size.y > area.origin.y + area.size.y:
    origin.y = anchor.origin.y - size.y - gap
  area.fitPanel(origin, size)

proc contains*(panel: GameUiPanel, point: Vec2): bool =
  ## Returns whether a point lies inside a panel.
  point.x >= panel.origin.x and point.y >= panel.origin.y and
    point.x < panel.origin.x + panel.size.x and
    point.y < panel.origin.y + panel.size.y

proc inside*(panel: GameUiPanel, bounds: Vec2): bool =
  ## Returns whether a panel lies fully inside a top-left bounds rectangle.
  panel.origin.x >= 0 and
    panel.origin.y >= 0 and
    panel.origin.x + panel.size.x <= bounds.x and
    panel.origin.y + panel.size.y <= bounds.y

proc overlaps*(a, b: GameUiPanel, gap = 0.0'f32): bool =
  ## Returns whether two panels sit closer than the required gap.
  not (
    a.origin.x + a.size.x + gap <= b.origin.x or
    b.origin.x + b.size.x + gap <= a.origin.x or
    a.origin.y + a.size.y + gap <= b.origin.y or
    b.origin.y + b.size.y + gap <= a.origin.y
  )

proc panelsOverlap*(
    panels: openArray[GameUiPanel],
    gap = 0.0'f32
): bool =
  ## Returns whether any pair of panels sits closer than the required gap.
  for i in 0 ..< panels.len:
    for j in i + 1 ..< panels.len:
      if overlaps(panels[i], panels[j], gap):
        return true

proc layoutFits*(
    layout: GameUiLayout,
    plates: openArray[GameUiPanel],
    gap = 0.0'f32
): bool =
  ## Returns whether plates stay inside the layout without overlapping.
  if panelsOverlap(plates, gap):
    return false
  let transport = layout.transportPanel
  let area = layout.gameArea
  for plate in plates:
    let local = GameUiPanel(origin: plate.origin - area.origin, size: plate.size)
    if not local.inside(area.size) or overlaps(plate, transport):
      return false
  true

proc initReplayTransport*(lastTick: int): ReplayTransport =
  ## Creates paused replay controls clamped to a non-negative tick range.
  result.lastTick = max(lastTick, 0)

proc sync*(transport: var ReplayTransport, tick: int) =
  ## Synchronizes the displayed transport tick with the game simulation.
  transport.tick = clamp(tick, 0, transport.lastTick)
  if transport.tick >= transport.lastTick:
    transport.playing = false

proc play*(transport: var ReplayTransport) =
  ## Starts playback, rewinding first when already at the end.
  if transport.lastTick <= 0:
    return
  if transport.tick >= transport.lastTick:
    transport.tick = 0
  transport.playing = true

proc pause*(transport: var ReplayTransport) =
  ## Pauses replay playback at the current tick.
  transport.playing = false

proc seek*(transport: var ReplayTransport, tick: int) =
  ## Pauses and moves the transport to one clamped replay tick.
  transport.tick = clamp(tick, 0, transport.lastTick)
  transport.playing = false

proc rewind*(transport: var ReplayTransport) =
  ## Pauses and returns the transport to the first replay tick.
  transport.seek(0)

proc stepBack*(transport: var ReplayTransport) =
  ## Pauses and moves the transport backward by one tick.
  transport.seek(transport.tick - 1)

proc stepForward*(transport: var ReplayTransport) =
  ## Pauses and moves the transport forward by one tick.
  transport.seek(transport.tick + 1)
