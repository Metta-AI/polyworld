## Structural guard for the rendered route; packet/simulation behavior is tested
## against the real relay in test_spectator. Browser QA exercises these controls.
import std/strutils
let graphics = readFile("games/gods_of_the_arena/graphics.nim")
let ui = readFile("games/gods_of_the_arena/ui.nim")
doAssert "spectatorStream.receive()" in graphics
doAssert "spectatorStream.advance()" in graphics
doAssert "transport.streamed = network.isSpectator" in graphics
doAssert "if network != nil and not network.isSpectator:" in graphics
doAssert "transportAvailable()" in ui
let main = graphics.split("          drawAimBanner()", 1)[1].split("          if matchMenu != HiddenMatchMenu:", 1)[0]
doAssert "menuButton" notin main, "No main-screen leave/save buttons"
doAssert "network.client.status" notin main, "Status belongs in Esc, not over minimap"
echo "Spectator graphics routing and uncluttered HUD passed"
