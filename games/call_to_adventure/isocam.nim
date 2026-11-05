## Call to Adventure's fixed isometric camera.
##
## Every camera mode (director, party follow, hero follow, free pan, the
## arena shot) moves one look-at target and one zoom distance. This module
## turns those into the same view: a north-west diagonal at the classic
## isometric elevation, drawn with an orthographic projection, so walls run
## along both screen diagonals and nothing shrinks with depth.
##
## `distance` keeps its perspective meaning: the orthographic window shows
## exactly what the old 45 degree camera showed across its target at that
## distance. Zoom limits, the director's framing and the HUD all keep
## working in the same units.

import
  std/math,
  vmath

const
  IsoYaw* = PI.float32 / 4
    ## The eye sits to the south-east, looking north-west.
  IsoPitch* = 0.6154797'f32
    ## arctan(1 / sqrt(2)): the true isometric elevation, 35.26 degrees.
  IsoHalfFov = PI.float32 / 8
    ## Half the old perspective field of view. Sizes the window per distance.
  IsoEyeBack = 160.0'f32
    ## How far behind its target the eye sits. Orthographic, so this only
    ## has to clear the drawn floors; it never changes the picture.
  IsoNear = 1.0'f32
  IsoFar = 400.0'f32

proc isoBack*(): Vec3 =
  ## Unit vector from the target toward the eye.
  vec3(
    sin(IsoYaw) * cos(IsoPitch),
    sin(IsoPitch),
    cos(IsoYaw) * cos(IsoPitch)
  )

proc isoGroundRight*(): Vec3 =
  ## The ground direction that runs to the right of the screen.
  vec3(cos(IsoYaw), 0, -sin(IsoYaw))

proc isoGroundDown*(): Vec3 =
  ## The ground direction that runs down the screen, toward the eye.
  vec3(sin(IsoYaw), 0, cos(IsoYaw))

proc isoHalfHeight*(distance: float32): float32 =
  ## Half the window's world height at this zoom distance.
  max(distance, 0.1'f32) * tan(IsoHalfFov)

proc isoEye*(target: Vec3): Vec3 =
  ## The eye position, far up the fixed diagonal from the target.
  target + isoBack() * IsoEyeBack

proc isoView*(target: Vec3): Mat4 =
  ## The fixed-diagonal view matrix centered on the target.
  lookAt(isoEye(target), target, vec3(0, 1, 0))

proc isoProjection*(distance, aspect, lift: float32): Mat4 =
  ## Orthographic projection for a zoom distance. `lift` raises the target
  ## by that fraction of the screen height, above the bottom HUD.
  let
    halfHeight = isoHalfHeight(distance)
    halfWidth = halfHeight * aspect
    shift = 2 * lift * halfHeight
  ortho(
    -halfWidth, halfWidth,
    -halfHeight - shift, halfHeight - shift,
    IsoNear, IsoFar
  )

proc isoViewProjection*(
    target: Vec3, distance, aspect, lift: float32
): Mat4 =
  ## The full camera transform for one target and zoom.
  isoProjection(distance, aspect, lift) * isoView(target)

proc isoPan*(screen: Vec2, scale: float32): Vec2 =
  ## Converts a screen-space pan (x right, y down) into a ground XZ move,
  ## so a vertical pan covers the same screen distance as a horizontal one.
  let ground =
    isoGroundRight() * screen.x +
    isoGroundDown() * (screen.y / sin(IsoPitch))
  vec2(ground.x, ground.z) * scale

proc isoGroundFootprint*(
    viewProjection: Mat4, planeY: float32
): array[4, Vec2] =
  ## The window corners projected onto a floor plane, as ground XZ points
  ## in screen order: top left, top right, bottom right, bottom left.
  const corners = [vec2(-1, 1), vec2(1, 1), vec2(1, -1), vec2(-1, -1)]
  let inv = inverse(viewProjection)
  for i, corner in corners:
    let
      nearPoint = inv * vec4(corner.x, corner.y, -1, 1)
      farPoint = inv * vec4(corner.x, corner.y, 1, 1)
      origin = nearPoint.xyz / nearPoint.w
      dir = farPoint.xyz / farPoint.w - origin
      t = (planeY - origin.y) / dir.y
      hit = origin + dir * t
    result[i] = vec2(hit.x, hit.z)

proc isoFitDistance*(
    boxMin, boxMax: Vec3, aspect, freeHeight: float32
): float32 =
  ## The zoom that fits a world box, centered on the target, inside the
  ## window's width and the `freeHeight` fraction of its height.
  let view = isoView((boxMin + boxMax) / 2)
  var halfWidth, halfHeight = 0.0'f32
  for i in 0 ..< 8:
    let
      corner = vec3(
        if (i and 1) == 0: boxMin.x else: boxMax.x,
        if (i and 2) == 0: boxMin.y else: boxMax.y,
        if (i and 4) == 0: boxMin.z else: boxMax.z
      )
      eyeSpace = view * corner
    halfWidth = max(halfWidth, abs(eyeSpace.x))
    halfHeight = max(halfHeight, abs(eyeSpace.y))
  let needed = max(
    halfWidth / max(aspect, 0.1'f32),
    halfHeight / clamp(freeHeight, 0.1'f32, 1)
  )
  needed / tan(IsoHalfFov)
