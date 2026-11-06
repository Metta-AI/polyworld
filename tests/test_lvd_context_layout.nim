import bumpy, vmath
import ../games/light_vs_dark/lobbies

let layout = LobbyLayout(left: vec2(30, 150), leftWidth: 930, panelHeight: 740)
let card = rosterCardPosition(layout, 0)
doAssert rosterCardHit(layout, 0, 0, card + vec2(10))
doAssert not rosterCardHit(layout, 0, 0, card - vec2(10))
# Scrolled-away cards and the scrollbar gutter must not open the popup.
doAssert not rosterCardHit(layout, 0, 90, card - vec2(0, 80))
let viewport = rosterViewport(layout)
doAssert not rosterCardHit(layout, 1, 0,
  vec2(viewport.x + viewport.w - 4, card.y + 10))
# The visible fragment of a partially clipped card remains interactive.
doAssert rosterCardHit(layout, 0, 40, card + vec2(10))
echo "LvD context roster hit tests passed"
