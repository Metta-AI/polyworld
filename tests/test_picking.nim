import std/[math, options]
import vmath
import gltf/[common, models]
import polyworld/picking

proc triangle(z = 0'f32): Node =
  Node(visible: true, scale: vec3(1), rot: quat(), mesh: Mesh(primitives: @[
    Primitive(mode: TrianglesMode,
      points: @[vec3(-1, -1, z), vec3(1, -1, z), vec3(0, 1, z)],
      uvs: @[vec2(0, 0), vec2(1, 0), vec2(0.5, 1)])]))

echo "Picking nearest visible posed mesh and interpolated UV"
block:
  let back = triangle(-2)
  let front = triangle()
  let root = Node(visible: true, scale: vec3(1), rot: quat(), nodes: @[back, front])
  root.updateTransforms()
  let ray = pickRay(vec3(0, 0, 5), vec3(0, 0, -4))
  let hit = ray.pickMesh(root).get
  doAssert hit.node == front
  doAssert abs(hit.distance - 5) < 1e-6
  doAssert length(hit.point) < 1e-6
  doAssert length(hit.uv.get - vec2(0.5, 0.5)) < 1e-6
  front.visible = false
  doAssert ray.pickMesh(root).get.node == back
  root.visible = false
  doAssert ray.pickMesh(root).isNone

echo "Picking range, face orientation, edge and degenerate triangles"
block:
  let a = vec3(-1, -1, 0)
  let b = vec3(1, -1, 0)
  let c = vec3(0, 1, 0)
  let ray = pickRay(vec3(0, 0, 5), vec3(0, 0, -1))
  doAssert ray.intersectTriangle(a, c, b).isNone
  doAssert ray.intersectTriangle(a, c, b, true).isSome
  doAssert ray.intersectTriangle(a, a, a).isNone
  doAssert pickRay(vec3(1, -1, 5), vec3(0, 0, -1)).intersectTriangle(a, b, c).isSome
  doAssert pickRay(ray.origin, ray.direction, far = 4).intersectTriangle(a, b, c).isNone
  doAssert pickRay(ray.origin, ray.direction, near = 6).intersectTriangle(a, b, c).isNone
  doAssert pickRay(ray.origin, ray.direction, near = 5, far = 5).intersectTriangle(a, b, c).isSome
  doAssert pickRay(vec3(0, 0, -1), ray.direction).intersectTriangle(a, b, c, true).isNone

echo "Both index widths, non-triangle rejection and transformed geometry"
block:
  let root = triangle()
  root.pos = vec3(2, 0, -3)
  root.scale = vec3(2, 1, 1)
  root.updateTransforms()
  let primitive = root.mesh.primitives[0]
  let ray = pickRay(vec3(2, 0, 5), vec3(0, 0, -1))
  primitive.indices16 = @[0'u16, 1, 2]
  doAssert abs(ray.pickMesh(root).get.distance - 8) < 1e-6
  primitive.indices16.setLen(0)
  primitive.indices32 = @[0'u32, 1, 2]
  doAssert ray.pickMesh(root).get.node == root
  primitive.mode = LinesMode
  doAssert ray.pickMesh(root).isNone

echo "Picking follows the actual skin pose rather than bind geometry"
block:
  let mesh = triangle()
  let joint = Node(visible: true, scale: vec3(1), rot: quat(), pos: vec3(4, 0, 0))
  mesh.skin = Skin(joints: @[joint], inverseBindMatrices: @[mat4()])
  let primitive = mesh.mesh.primitives[0]
  primitive.jointIds = @[[0'u16, 0, 0, 0], [0'u16, 0, 0, 0], [0'u16, 0, 0, 0]]
  primitive.jointWeights = @[vec4(1, 0, 0, 0), vec4(1, 0, 0, 0), vec4(1, 0, 0, 0)]
  let root = Node(visible: true, scale: vec3(1), rot: quat(), nodes: @[mesh, joint])
  root.updateTransforms()
  doAssert pickRay(vec3(0, 0, 5), vec3(0, 0, -1)).pickMesh(root).isNone
  doAssert pickRay(vec3(4, 0, 5), vec3(0, 0, -1)).pickMesh(root).get.node == mesh

echo "Screen ray and invalid input contracts"
block:
  let ray = pickRayFromScreen(mat4(), vec2(0.25, -0.5))
  doAssert length(ray.origin - vec3(0.25, -0.5, -1)) < 1e-6
  doAssert length(ray.direction - vec3(0, 0, 1)) < 1e-6
  for invalid in [vec3(0), vec3(NaN.float32, 0, 1), vec3(Inf.float32, 0, 1)]:
    var rejected = false
    try:
      discard pickRay(vec3(0), invalid)
    except ValueError:
      rejected = true
    doAssert rejected

echo "Picking tests passed"
