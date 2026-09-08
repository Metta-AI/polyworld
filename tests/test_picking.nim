import std/[math, options]
import vmath
import gltf/[common, models]
import polyworld/picking
import polyworld/characters

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

echo "Screen rays agree with perspective and orthographic cameras"
block:
  let eye = vec3(3, 2, 5)
  let view = lookAt(eye, vec3(3, 2, 0), vec3(0, 1, 0))
  let perspectiveRay = pickRayFromScreen(perspective(60'f32, 1'f32, 0.1'f32, 20'f32) * view, vec2(0))
  doAssert length(perspectiveRay.origin - vec3(3, 2, 4.9)) < 1e-4
  doAssert length(perspectiveRay.direction - vec3(0, 0, -1)) < 1e-4
  let projection = ortho(-2'f32, 2'f32, -2'f32, 2'f32, 0.1'f32, 20'f32)
  let left = pickRayFromScreen(projection * view, vec2(-0.5, 0))
  let right = pickRayFromScreen(projection * view, vec2(0.5, 0))
  doAssert length(left.direction - right.direction) < 1e-6
  doAssert abs(right.origin.x - left.origin.x - 2) < 1e-6

echo "Character consumer picks the skinned pose and preserves double-sided hits"
block:
  let root = triangle()
  root.baseVisible = true
  root.baseScale = vec3(1)
  root.baseRot = quat()
  let joint = Node(visible: true, baseVisible: true,
    scale: vec3(1), baseScale: vec3(1), rot: quat(), baseRot: quat(),
    pos: vec3(4, 0, 0), basePos: vec3(4, 0, 0))
  root.nodes = @[joint]
  root.skin = Skin(joints: @[joint], inverseBindMatrices: @[mat4()])
  let primitive = root.mesh.primitives[0]
  primitive.jointIds = @[[0'u16, 0, 0, 0], [0'u16, 0, 0, 0], [0'u16, 0, 0, 0]]
  primitive.jointWeights = @[vec4(1, 0, 0, 0), vec4(1, 0, 0, 0), vec4(1, 0, 0, 0)]
  let model = CharacterModel(file: GltfFile(root: root), baseTransform: mat4())
  doAssert model.pickCharacter(vec3(0, 0, 5), vec3(0, 0, -1), vec3(0), 0, 0, 0) == -1
  doAssert abs(model.pickCharacter(vec3(4, 0, 5), vec3(0, 0, -1), vec3(0), 0, 0, 0) - 5) < 1e-6
  doAssert abs(model.pickCharacter(vec3(4, 0, -5), vec3(0, 0, 1), vec3(0), 0, 0, 0) - 5) < 1e-6

echo "Picking rejects non-finite origins and invalid distance intervals"
block:
  for origin in [vec3(NaN.float32, 0, 0), vec3(0, Inf.float32, 0)]:
    var rejected = false
    try:
      discard pickRay(origin, vec3(0, 0, 1))
    except ValueError:
      rejected = true
    doAssert rejected
  for limits in [(-1'f32, 10'f32), (2'f32, 1'f32), (0'f32, NaN.float32)]:
    var rejected = false
    try:
      discard pickRay(vec3(0), vec3(0, 0, 1), limits[0], limits[1])
    except ValueError:
      rejected = true
    doAssert rejected

echo "Picking tests passed"
