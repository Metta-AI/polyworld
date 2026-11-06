## Real Windy button state exercises production HUD/gameplay hit ownership.
import std/importutils
import windy/internal
include ../ui
privateAccess(Window)

let window = newWindow("GotA tooltip input", ivec2(1600, 1000), visible = false)
run = Game(world: World(phase: Playing))
let sk = Silky()
let anchor = GameUiPanel(origin: vec2(700, 800), size: vec2(64))
let target = TooltipTarget(id: "input", anchor: anchor,
  card: DetailTooltip(title: "Input ownership"))
hudTooltip.updateTooltip([target], anchor.origin + vec2(1), vec2(1600, 1000), 0)
hudTooltip.updateTooltip([target], anchor.origin + vec2(20), vec2(1600, 1000), 0.5)
sk.mousePos = hudTooltip.panel.origin + vec2(20)
window.state.perFrame = PerFrame(buttonPressed: {MouseLeft})
let coveredButton = GameUiPanel(origin: sk.mousePos - vec2(10), size: vec2(30))
doAssert window.mousePressed(MouseLeft)
doAssert not window.hudClicked(sk, coveredButton),
  "The real left press must not activate a HUD button behind the tooltip"
doAssert mouseOverUi(window, sk.mousePos),
  "Gameplay order/selection polling must see the tooltip as UI"
var minimapPanning = true
var follow = true
var camera = vec3(0)
updateMinimapCamera(window, sk.mousePos, camera, minimapPanning, follow)
doAssert not minimapPanning
clearHudTooltip()
doAssert window.hudClicked(sk, coveredButton),
  "Clearing a tooltip must retire its collision rectangle"
window.close()
echo "PASS native Windy press: covered HUD blocked, gameplay blocked, clear releases"
