import vmath
import polyworld/frustums

echo "Bounds reject all six clip planes and retain intersections"
block:
  let identity = mat4()
  doAssert boundsVisible(vec3(-0.5), vec3(0.5), identity)
  doAssert boundsVisible(vec3(-10), vec3(10), identity)
  doAssert boundsVisible(vec3(1, 0, 0), vec3(1, 0, 0), identity)
  doAssert not boundsVisible(vec3(1), vec3(-1), identity)
  for axis in 0 .. 2:
    for sign in [-1'f32, 1'f32]:
      var center = vec3(0)
      center[axis] = sign * 3
      doAssert not boundsVisible(center - vec3(0.5), center + vec3(0.5), identity)
      center[axis] = sign
      doAssert boundsVisible(center - vec3(0.5), center + vec3(0.5), identity)

echo "Perspective near-plane intersections are conservative"
block:
  let projection = perspective(60'f32, 1'f32, 0.1'f32, 100'f32)
  doAssert boundsVisible(vec3(-1, -1, -4), vec3(1, 1, -2), projection)
  doAssert boundsVisible(vec3(-1, -1, -1), vec3(1, 1, 1), projection)
  doAssert boundsVisible(vec3(-0.01, -0.01, -0.2), vec3(0.01, 0.01, -0.05), projection)
  doAssert not boundsVisible(vec3(-1, -1, 2), vec3(1, 1, 4), projection)
  # Perspective compresses far depth. Stay beyond the documented clip-space
  # tolerance when asserting rejection, and separately retain the boundary.
  doAssert not boundsVisible(vec3(-1, -1, -120), vec3(1, 1, -110), projection)
  doAssert boundsVisible(vec3(0, 0, -100), vec3(0, 0, -100), projection)
  doAssert not boundsVisible(vec3(100, 0, -4), vec3(101, 1, -2), projection)

echo "Model-local bounds and orthographic projections"
block:
  let projection = ortho(-2'f32, 2'f32, -2'f32, 2'f32, 0.1'f32, 10'f32)
  let boundsMin = vec3(-0.5)
  let boundsMax = vec3(0.5)
  doAssert boundsVisible(boundsMin, boundsMax, projection * translate(vec3(0, 0, -2)))
  doAssert not boundsVisible(boundsMin, boundsMax, projection * translate(vec3(8, 0, -2)))
  let stretched = projection * translate(vec3(2.5, 0, -2)) * scale(vec3(4, 1, 1))
  doAssert boundsVisible(boundsMin, boundsMax, stretched)

echo "Any contained visible point keeps its bounding box"
block:
  for aspect in [0.5'f32, 1'f32, 2'f32]:
    let matrix = perspective(60'f32, aspect, 0.1'f32, 100'f32) *
      lookAt(vec3(4, 3, 6), vec3(0), vec3(0, 1, 0))
    for x in -5 .. 5:
      for y in -5 .. 5:
        for z in -5 .. 5:
          let point = vec3(x.float32, y.float32, z.float32)
          let clip = matrix * vec4(point, 1)
          if clip.w > 0 and abs(clip.x) <= clip.w and
              abs(clip.y) <= clip.w and abs(clip.z) <= clip.w:
            doAssert boundsVisible(point - vec3(0.1), point + vec3(0.1), matrix)

echo "Frustum bounds tests passed"
