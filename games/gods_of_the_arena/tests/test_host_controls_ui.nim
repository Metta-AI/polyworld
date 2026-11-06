## Render-route guards: hidden controls must never reach lobbyButton, not merely
## be disabled. Local setup derives owner=true and retains the same full route.
import std/strutils
let frontend = readFile("games/gods_of_the_arena/frontend.nim")
let lobbies = readFile("games/gods_of_the_arena/lobbies.nim")
let fillRoute = frontend.split("          let\n            fill =", 1)[1].split("          let previousName", 1)[0]
doAssert "          if owner:\n" in fillRoute,
  "Fill controls must be omitted from guest rendering"
for line in fillRoute.splitLines:
  if "sk.lobby" in line:
    doAssert line.startsWith("            "), "Fill labels/select/buttons must all be host-only"
doAssert "\"Shuffle team\"" in fillRoute
doAssert "Shuffle mine" notin frontend
let startRoute = frontend.split("            if configDirty and owner and editable:", 1)[1].split("            if sk.lobbyButton(\n              if owner", 1)[0]
doAssert "            elif owner:" in startRoute,
  "Guests must not render even a disabled Start Game button"
doAssert "showControls = owner" in frontend
let navigation = lobbies.split("  if showControls:\n", 1)
doAssert navigation.len == 2, "Map generation and Advanced settings require a visibility guard"
doAssert "\"Map generation\"" in navigation[1]
doAssert "\"Advanced settings\"" in navigation[1]
doAssert "page = if showControls: ui.configPage else: 0" in lobbies,
  "A stale host advanced tab must not leak into the guest view"
doAssert "owner = not online or snapshot.participant == client.participant" in frontend,
  "Single-player setup must retain full controls"
echo "Host-only rendered controls, exact shuffle label and full local setup passed"
