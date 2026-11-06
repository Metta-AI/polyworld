import vmath
import ../minimaporders

# Right click moves; an armed A-click attacks without panning the camera.
doAssert minimapOrder(true, false, false, false) == MinimapWalk
doAssert minimapOrder(true, false, true, false) == MinimapAttackMove
doAssert minimapOrder(false, true, true, false) == MinimapAttackMove
doAssert minimapOrder(false, true, false, false) == NoMinimapOrder
# Spell and item targeting must not leak into movement orders.
doAssert minimapOrder(true, false, true, true) == NoMinimapOrder
let destination = minimapDestination(vec2(12.75'f, -8.25'f))
doAssert destination.x == 12 and destination.y == -9
# The feedback belongs at the commanded tile, not beneath the HUD cursor.
let marker = minimapMarker(destination, 3.5'f)
doAssert marker == vec3(12.5'f, 3.5'f, -8.5'f)
echo "Minimap order routing and world feedback passed"
