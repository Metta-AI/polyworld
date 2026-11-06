import vmath
import polyworld/gameuis
import ../tooltiphover

let anchor = GameUiPanel(origin: vec2(100, 500), size: vec2(64))
let panel = GameUiPanel(origin: vec2(30, 100), size: vec2(380, 390))
var hover: TooltipHover
doAssert not hover.update("ability:1", anchor, panel, vec2(101, 501), 10.0)
doAssert not hover.update("ability:1", anchor, panel, vec2(150, 550), 10.49)
doAssert hover.update("ability:1", anchor, panel, vec2(120, 520), 10.5),
  "Movement within the same anchor must not restart half-second dwell"
doAssert hover.update("ability:1", anchor, panel, vec2(160, 560), 11.0)
echo "PASS stable anchor dwell and moving visible target"
doAssert hover.update("", anchor, panel, vec2(600, 600), 11.1),
  "Leaving both regions must start a grace period, not hide immediately"
doAssert hover.update("", anchor, panel, vec2(600, 600), 11.44)
doAssert not hover.update("", anchor, panel, vec2(600, 600), 11.46)
echo "PASS leave grace and expiry"
doAssert not hover.update("ability:1", anchor, panel, vec2(120, 520), 20.0)
doAssert hover.update("ability:1", anchor, panel, vec2(120, 520), 20.5)
doAssert hover.update("", anchor, panel, vec2(600, 600), 20.6)
doAssert hover.update("", anchor, panel, vec2(200, 200), 20.8)
doAssert hover.update("", anchor, panel, vec2(250, 250), 22.0),
  "Hovering the visible panel must keep it alive indefinitely"
echo "PASS panel hover keeps visible"
doAssert hover.update("ability:2", anchor, panel, vec2(120, 520), 23.0),
  "A warmed session must switch anchors instantly"
doAssert hover.target == "ability:2"
# Pending targets do not acquire visibility from passing through the old panel.
hover = TooltipHover()
doAssert not hover.update("ability:3", anchor, panel, vec2(120, 520), 30.0)
doAssert not hover.update("", anchor, panel, vec2(200, 200), 30.6)
doAssert not hover.update("ability:3", anchor, panel, vec2(120, 520), 30.7)
echo "PASS global warm switch and pending dwell cancellation"
