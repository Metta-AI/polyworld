## Presentation-only picking against the current glTF pose.
## Call updateTransforms on the posed root before querying. These hits never
## replace authoritative movement, collision, visibility, or ability checks.

import std/[math, options]
import vmath
import gltf/[common, models]

type
  PickRay* = object
    origin*, direction*: Vec3
      ## Direction must be normalized; distances are in world units.
    near*, far*: float32
  MeshHit* = object
    node*: Node
    primitive*: Primitive
    triangle*: int
    distance*: float32
    point*, barycentric*: Vec3
    uv*: Option[Vec2]

proc pickRay*(origin, direction: Vec3;
    near = 0'f32; far = Inf.float32): PickRay =
  ## Constructs a ray with a normalized direction and inclusive distance range.
  let magnitude = direction.length
  if not (magnitude > 0 and magnitude < Inf and
      near >= 0 and near < Inf and far >= near):
    raise newException(ValueError, "invalid pick ray direction or distance range")
  for value in [origin.x, origin.y, origin.z]:
    if not (abs(value) < Inf):
      raise newException(ValueError, "pick ray origin must be finite")
  PickRay(origin: origin, direction: direction / magnitude, near: near, far: far)

proc pickRayFromScreen*(viewProjection: Mat4; ndc: Vec2): PickRay =
  ## NDC is [-1, 1], with Y pointing up. OpenGL/WebGL clip Z is [-1, 1].
  ## The origin is the near plane for both perspective and orthographic views.
  let inv = inverse(viewProjection)
  let a = inv * vec4(ndc.x, ndc.y, -1, 1)
  let b = inv * vec4(ndc.x, ndc.y, 1, 1)
  if abs(a.w) < 1e-7'f32 or abs(b.w) < 1e-7'f32:
    raise newException(ValueError, "pick projection must have finite clip planes")
  let origin = a.xyz / a.w
  pickRay(origin, b.xyz / b.w - origin)

proc intersectTriangle*(ray: PickRay; a, b, c: Vec3;
    doubleSided = false): Option[MeshHit] =
  ## Moller-Trumbore intersection; edges are included and back faces opt in.
  let edge = b - a
  let other = c - a
  let crossRay = cross(ray.direction, other)
  let determinant = dot(edge, crossRay)
  if abs(determinant) < 1e-7'f32 or (not doubleSided and determinant < 0):
    return
  let offset = ray.origin - a
  let u = dot(offset, crossRay) / determinant
  if u < 0 or u > 1:
    return
  let crossOffset = cross(offset, edge)
  let v = dot(ray.direction, crossOffset) / determinant
  if v < 0 or u + v > 1:
    return
  let distance = dot(other, crossOffset) / determinant
  if distance < ray.near or distance > ray.far:
    return
  some(MeshHit(distance: distance, point: ray.origin + ray.direction * distance,
    barycentric: vec3(1 - u - v, u, v)))

proc pickMesh*(ray: PickRay; root: Node; doubleSided = false): Option[MeshHit] =
  ## Finds the nearest triangle in a visible subtree, retaining traversal order
  ## for equal distances. Uses current (including morphed) points and joint
  ## matrices. Alpha masks and non-triangle primitive modes are not sampled.
  var query = ray
  var nearest: Option[MeshHit]
  proc visit(node: Node) =
    if node == nil or not node.visible:
      return
    if node.mesh != nil:
      let joints = root.skinMatrices(node)
      let mirrored = node.mat.determinant < 0
      for primitive in node.mesh.primitives:
        if primitive.mode != TrianglesMode:
          continue
        var points = newSeq[Vec3](primitive.points.len)
        for i, point in primitive.points:
          var posed = point
          if joints.len > 0:
            posed = vec3(0)
            for component in 0 .. 3:
              let weight = primitive.jointWeights[i][component]
              if weight != 0:
                posed += (joints[int(primitive.jointIds[i][component])] * point) * weight
          points[i] = node.mat * posed
        let count = if primitive.indices16.len > 0: primitive.indices16.len
          elif primitive.indices32.len > 0: primitive.indices32.len
          else: points.len
        template index(i: int): int =
          (if primitive.indices16.len > 0: int(primitive.indices16[i])
          elif primitive.indices32.len > 0: int(primitive.indices32[i])
          else: i)
        for triangle in 0 ..< count div 3:
          let a = index(triangle * 3)
          var b = index(triangle * 3 + 1)
          var c = index(triangle * 3 + 2)
          if mirrored:
            swap(b, c)
          let hit = query.intersectTriangle(points[a], points[b], points[c],
            doubleSided or (primitive.material != nil and primitive.material.doubleSided))
          if hit.isSome and (nearest.isNone or hit.get.distance < query.far):
            var value = hit.get
            value.node = node
            value.primitive = primitive
            value.triangle = triangle
            if primitive.uvs.len == points.len:
              let weights = value.barycentric
              value.uv = some(primitive.uvs[a] * weights.x +
                primitive.uvs[b] * weights.y + primitive.uvs[c] * weights.z)
            if mirrored:
              swap(value.barycentric.y, value.barycentric.z)
            query.far = value.distance
            nearest = some(value)
    for child in node.nodes:
      visit(child)
  visit(root)
  nearest
