## Minimap order routing and shared world-space feedback coordinates.
import std/math, vmath

type MinimapOrder* = enum
  NoMinimapOrder, MinimapWalk, MinimapAttackMove

proc minimapOrder*(rightPressed, leftPressed, attackArmed, targeting: bool): MinimapOrder =
  ## Leaves ordinary left-click camera navigation and aimed casts untouched.
  if targeting:
    return NoMinimapOrder
  if rightPressed or (leftPressed and attackArmed):
    return if attackArmed: MinimapAttackMove else: MinimapWalk

proc minimapDestination*(point: Vec2): tuple[x, y: int32] =
  ## Floors world XZ to the same signed map tiles used by ground orders.
  (int32(floor(point.x)), int32(floor(point.y)))

proc minimapMarker*(destination: tuple[x, y: int32], height: float32): Vec3 =
  ## Centers feedback on the commanded world tile at its terrain height.
  vec3(destination.x.float32 + 0.5'f, height, destination.y.float32 + 0.5'f)
