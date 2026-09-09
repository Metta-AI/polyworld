import
  vmath,
  polyworld/gameuis

echo "Testing the nine game UI regions"
let layout = initGameUiLayout(vec2(1000, 800), 80, 10)
doAssert layout.gameAreaSize == vec2(1000, 720)
doAssert layout.panel(
  GameUiRegion.TopLeft,
  vec2(100, 50)
).origin == vec2(10, 10)
doAssert layout.panel(
  GameUiRegion.TopCenter,
  vec2(100, 50)
).origin == vec2(450, 10)
doAssert layout.panel(
  GameUiRegion.TopRight,
  vec2(100, 50)
).origin == vec2(890, 10)
doAssert layout.panel(
  GameUiRegion.CenterLeft,
  vec2(100, 50)
).origin == vec2(10, 335)
doAssert layout.panel(
  GameUiRegion.Center,
  vec2(100, 50)
).origin == vec2(450, 335)
doAssert layout.panel(
  GameUiRegion.CenterRight,
  vec2(100, 50)
).origin == vec2(890, 335)
doAssert layout.panel(
  GameUiRegion.BottomLeft,
  vec2(100, 50)
).origin == vec2(10, 660)
doAssert layout.panel(
  GameUiRegion.BottomCenter,
  vec2(100, 50)
).origin == vec2(450, 660)
doAssert layout.panel(
  GameUiRegion.BottomRight,
  vec2(100, 50)
).origin == vec2(890, 660)

echo "Testing the transport pushes bottom regions upward"
let transportPanel = layout.transportPanel
doAssert transportPanel.origin == vec2(0, 720)
doAssert transportPanel.size == vec2(1000, 80)
doAssert transportPanel.contains(vec2(999, 799))
doAssert not transportPanel.contains(vec2(1000, 800))

echo "Testing panel overlap and layout clearance"
block:
  let
    left = GameUiPanel(origin: vec2(0, 0), size: vec2(100, 50))
    right = GameUiPanel(origin: vec2(108, 0), size: vec2(100, 50))
    flush = GameUiPanel(origin: vec2(99, 0), size: vec2(100, 50))
    touch = GameUiPanel(origin: vec2(100, 0), size: vec2(100, 50))
  doAssert not overlaps(left, right)
  doAssert not overlaps(left, touch)
  doAssert overlaps(left, flush)
  doAssert overlaps(left, right, 16)
  doAssert not overlaps(left, right, 8)
  doAssert left.inside(vec2(100, 50))
  doAssert not left.inside(vec2(99, 50))

echo "Testing replay transport state"
var transport = initReplayTransport(100)
doAssert not transport.playing
transport.play()
doAssert transport.playing
transport.sync(100)
doAssert not transport.playing
transport.play()
doAssert transport.playing and transport.tick == 0
transport.seek(50)
doAssert not transport.playing and transport.tick == 50
transport.stepBack()
doAssert transport.tick == 49
transport.stepForward()
doAssert transport.tick == 50
transport.rewind()
doAssert transport.tick == 0


block:
  echo "Safe insets and transport share one usable rectangle"
  let layout = initGameUiLayout(vec2(800, 600), 40, 10, vec4(30, 20, 50, 60))
  doAssert layout.gameArea.origin == vec2(30, 20)
  doAssert layout.gameArea.size == vec2(720, 480)
  doAssert layout.panel(GameUiRegion.TopLeft, vec2(100)).origin == vec2(40, 30)
  doAssert layout.panel(GameUiRegion.BottomRight, vec2(100)).origin == vec2(640, 390)
  doAssert layout.transportPanel.origin == vec2(30, 500)
  doAssert layout.transportPanel.size == vec2(720, 40)
  doAssert not layout.layoutFits([GameUiPanel(origin: vec2(0), size: vec2(10))])
  let collapsed = initGameUiLayout(vec2(40, 30), 100, safeInsets = vec4(60, 40, 60, 40))
  doAssert collapsed.gameArea.size == vec2(0)
  doAssert collapsed.transportPanel.size == vec2(0)

block:
  echo "Popups flip at edges and oversize content stays within usable bounds"
  let area = GameUiPanel(origin: vec2(20, 30), size: vec2(300, 200))
  let low = GameUiPanel(origin: vec2(290, 200), size: vec2(20))
  doAssert area.popupPanel(low, vec2(100, 80)).origin == vec2(220, 112)
  let high = GameUiPanel(origin: vec2(30, 40), size: vec2(20))
  doAssert area.popupPanel(high, vec2(100, 80)).origin == vec2(30, 68)
  let huge = area.popupPanel(low, vec2(600, 400))
  doAssert huge.origin == area.origin and huge.size == area.size
  for x in [-100'f32, 0, 200, 500]:
    for y in [-100'f32, 0, 200, 500]:
      let placed = area.fitPanel(vec2(x, y), vec2(80, 60))
      doAssert GameUiPanel(origin: placed.origin - area.origin, size: placed.size).inside(area.size)
      doAssert placed.contains(placed.origin + placed.size * 0.5)

block:
  let empty = GameUiPanel(origin: vec2(20), size: vec2(-10))
  let fitted = empty.fitPanel(vec2(-100), vec2(50))
  doAssert fitted.origin == empty.origin and fitted.size == vec2(0)

echo "Game UI tests passed"
