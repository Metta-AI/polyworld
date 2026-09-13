import std/options
import vmath
import gltf/[common, models]
import polyworld/picking
import polyworld/animblend
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
  root.animations = @[AnimationClip(name: "move", duration: 1,
    channels: @[AnimationChannel(target: joint, path: AnimTranslation,
      interpolation: aiLinear, times: @[0'f32, 1],
      valuesVec3: @[vec3(4, 0, 0), vec3(6, 0, 0)])])]
  let player = newClipPlayer(root)
  player.play(0, fade = 0)
  player.seek(1)
  joint.pos = vec3(4, 0, 0) # Simulate another shared instance's last pose.
  doAssert model.pickCharacter(
    player, vec3(6, 0, 5), vec3(0, 0, -1), vec3(0), 0) == 5

echo "Picking rejects non-finite origins and invalid distance intervals"
block:
  for direction in [vec3(0), vec3(NaN.float32, 0, 1), vec3(Inf.float32, 0, 1)]:
    doAssertRaises(ValueError):
      discard pickRay(vec3(0), direction)
  for origin in [vec3(NaN.float32, 0, 0), vec3(0, Inf.float32, 0)]:
    doAssertRaises(ValueError):
      discard pickRay(origin, vec3(0, 0, 1))
  for limits in [(-1'f32, 10'f32), (2'f32, 1'f32), (0'f32, NaN.float32)]:
    doAssertRaises(ValueError):
      discard pickRay(vec3(0), vec3(0, 0, 1), limits[0], limits[1])

echo "Reflected meshes preserve rendered faces, vertex weights and UVs"
block:
  let root = triangle()
  root.scale = vec3(-1, 1, 1)
  root.updateTransforms()
  let front = pickRay(vec3(0.25, 0, 5), vec3(0, 0, -1)).pickMesh(root).get
  doAssert length(front.barycentric - vec3(0.375, 0.125, 0.5)) < 1e-6
  doAssert length(front.uv.get - vec2(0.375, 0.5)) < 1e-6
  let back = pickRay(vec3(0.25, 0, -5), vec3(0, 0, 1))
  doAssert back.pickMesh(root).isNone
  doAssert back.pickMesh(root, doubleSided = true).isSome

echo "Character rays skip origin hits before choosing the nearest distance"
block:
  let root = triangle()
  root.baseVisible = true
  root.baseScale = vec3(1)
  root.baseRot = quat()
  let primitive = root.mesh.primitives[0]
  primitive.points.add triangle(-2).mesh.primitives[0].points
  let model = CharacterModel(file: GltfFile(root: root), baseTransform: mat4())
  doAssert model.pickCharacter(vec3(0), vec3(0, 0, -1), vec3(0), 0, -1, 0) == 2
  for i in 3 .. 5:
    primitive.points[i].z = -1e-9'f32
  doAssert abs(model.pickCharacter(vec3(0), vec3(0, 0, -1), vec3(0), 0, -1, 0) - 1e-9'f32) < 1e-15
  primitive.points.setLen(3)
  doAssert model.pickCharacter(vec3(0), vec3(0, 0, -1), vec3(0), 0, -1, 0) == -1
  root.updateTransforms()
  doAssert pickRay(vec3(0), vec3(0, 0, -1)).pickMesh(root).get.distance == 0


block:
  let root = triangle()
  root.scale = vec3(0.0001)
  root.updateTransforms()
  let hit = pickRay(vec3(0, 0, 1), vec3(0, 0, -1)).pickMesh(root)
  doAssert hit.isSome, "a small visible triangle must still be selectable"
  doAssert abs(hit.get.distance - 1) < 1e-6

echo "Picking tests passed"
