## Conservative presentation bounds queries in OpenGL/WebGL clip space.
## Bounds belong to rendered geometry, including animation and shader motion;
## they do not define simulation collision or visibility.

import vmath

func boundsVisible*(minimum, maximum: Vec3; viewProjection: Mat4): bool =
  ## Rejects an AABB only when all corners lie beyond the same clip plane.
  ## No perspective divide: bounds crossing the eye or near plane stay safe.
  ## Pass viewProjection * model to test model-local bounds directly.
  ## Inputs must be finite and minimum must be <= maximum on each axis.
  for axis in 0 .. 2:
    if minimum[axis] > maximum[axis]:
      return false
  var commonOutside = 63
  for x in [minimum.x, maximum.x]:
    for y in [minimum.y, maximum.y]:
      for z in [minimum.z, maximum.z]:
        let clip = viewProjection * vec4(x, y, z, 1'f32)
        let tolerance = 0.0001'f32 * max(1'f32, abs(clip.w))
        var outside = 0
        if clip.x < -clip.w - tolerance: outside = outside or 1
        if clip.x > clip.w + tolerance: outside = outside or 2
        if clip.y < -clip.w - tolerance: outside = outside or 4
        if clip.y > clip.w + tolerance: outside = outside or 8
        if clip.z < -clip.w - tolerance: outside = outside or 16
        if clip.z > clip.w + tolerance: outside = outside or 32
        commonOutside = commonOutside and outside
        if commonOutside == 0:
          return true
  commonOutside == 0
