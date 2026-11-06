## Production UI wiring and lifecycle guards (native source-route regression).
import std/strutils
let ui = readFile("games/gods_of_the_arena/ui.nim")
let graphics = readFile("games/gods_of_the_arena/graphics.nim")
doAssert "hudTooltip.tooltipContains(mouse)" in ui,
  "Visible tooltip must own gameplay hit testing"
doAssert "not hudTooltip.tooltipContains(sk.mousePos)" in ui,
  "Covered HUD buttons must not receive panel clicks"
doAssert "hudTooltip.updateTooltip" in ui and "sk.drawTooltip(hudTooltip" in ui
doAssert "sk.mouseIdleTime" notin ui,
  "No GotA tooltip route may depend on pointer stationarity"
doAssert "clearHudTooltip()" in graphics,
  "Opening menus must clear retained tooltip state"
doAssert "hudTooltip.clearTooltip()" in ui,
  "Selection/shop/draft contexts must retire stale targets"
echo "PASS native UI tooltip routing and lifecycle guards"
