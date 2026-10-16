import
  chroma, gltf, pixie, vmath,
  polyworld/[characters, charactermeshes]

proc node(name: string, position = vec3(0)): Node =
  ## Creates a visible test node with an explicit rest transform.
  Node(name: name, visible: true, baseVisible: true,
    pos: position, basePos: position, rot: quat(), baseRot: quat(),
    scale: vec3(1), baseScale: vec3(1))

proc point(root, owner: Node, primitive: Primitive, index: int): Vec3 =
  ## Evaluates a vertex with the same joint weights as the renderer.
  var value = primitive.points[index]
  if owner.skin != nil:
    let joints = root.skinMatrices(owner)
    value = vec3(0)
    for i in 0 ..< 4:
      value += joints[primitive.jointIds[index][i].int] *
        primitive.points[index] * primitive.jointWeights[index][i]
  owner.mat * value

echo "Merged character skin palettes preserve joint order and bind variants."
let
  root = node("root")
  firstJoint = node("first", vec3(1, 2, 3))
  lastJoint = node("last", vec3(-3, 2, 1))
  firstPart = node("first part", vec3(2, 0, 0))
  lastPart = node("last part", vec3(-2, 0, 0))
root.nodes = @[firstJoint, lastJoint, firstPart, lastPart]
firstPart.skin = Skin(joints: @[firstJoint, lastJoint],
  inverseBindMatrices: @[mat4(), translate(vec3(0, 2, 0))])
lastPart.skin = Skin(joints: @[lastJoint, firstJoint],
  inverseBindMatrices: @[translate(vec3(0, 2, 0)), translate(vec3(0, -1, 0))])
for owner in [firstPart, lastPart]:
  owner.mesh = Mesh(primitives: @[Primitive(
    mode: TrianglesMode,
    points: @[vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0)],
    normals: @[vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1)],
    jointIds: @[[0'u16, 1, 0, 0], [1'u16, 0, 0, 0], [0'u16, 1, 0, 0]],
    jointWeights: @[vec4(0.4, 0.6, 0, 0), vec4(1, 0, 0, 0),
      vec4(0.25, 0.75, 0, 0)],
    material: Material()
  )])
let merged = mergeCharacterMesh(root, [])
doAssert merged.mesh.primitives.len == 1
doAssert merged.skin.joints.len == 3
doAssert merged.mesh.primitives[0].indices16 == @[0'u16, 1, 2, 3, 4, 5]
for time in [0'f, 0.25'f, 1'f]:
  firstJoint.pos = vec3(time, time * 2, 1)
  lastJoint.rot = quat(rotateY(time))
  root.updateTransforms(
    translate(vec3(4, 5, 6)) * rotateZ(time) * scale(vec3(2))
  )
  merged.mat = root.mat
  var index = 0
  for owner in [firstPart, lastPart]:
    let primitive = owner.mesh.primitives[0]
    for i in 0 ..< primitive.points.len:
      doAssert length(point(root, owner, primitive, i) -
        point(root, merged, merged.mesh.primitives[0], index)) < 0.00001
      doAssert primitive.jointWeights[i] ==
        merged.mesh.primitives[0].jointWeights[index]
      inc index
echo "Merged character skinning passed."

echo "Merged parts preserve face pixels, colors and cutout flags."
let
  face = newImage(3, 3)
  source = firstPart.mesh.primitives[0]
face.fill(rgbx(220, 180, 140, 255))
source.material.baseColor = face
source.material.baseColorFactor = color(0.5, 0.75, 1, 1)
source.material.alphaMode = MaskAlphaMode
source.material.alphaCutoff = 0.4
source.uvs = @[vec2(0.5), vec2(0.5), vec2(0.5)]
let
  textured = mergeCharacterMesh(root, [firstPart.name])
  packed = textured.mesh.primitives[0]
  atlas = packed.material.baseColor
  uv = packed.uvs[0]
doAssert atlas.width == 512 and atlas.height == 512
doAssert atlas[int(uv.x * 512), int(uv.y * 512)] == face[1, 1]
doAssert packed.colors[0] == source.material.baseColorFactor.rgbx
doAssert packed.uvs1[0] == vec2(1, 0.4)
doAssert packed.uvs1[3] == vec2(0, -1)
doAssert atlas[511, 511] == rgbx(255, 255, 255, 255)

echo "Merged colors retain straight alpha and blended drawing state."
source.material.baseColorFactor.a = 0.5
source.colors = @[rgbx(200, 160, 100, 128), rgbx(200, 160, 100, 128),
  rgbx(200, 160, 100, 128)]
lastPart.mesh.primitives[0].material.alphaMode = BlendAlphaMode
let translucent = mergeCharacterMesh(root, [])
doAssert translucent.mesh.primitives.len == 2
doAssert translucent.mesh.primitives[0].colors[0] == rgbx(100, 120, 100, 64)
doAssert translucent.mesh.primitives[1].material.alphaMode == BlendAlphaMode

echo "Shared meshes retain independent living and dead pose snapshots."
let
  model = CharacterModel(file: GltfFile(root: root), baseTransform: mat4())
  scene = CharacterScene(shading: ToonCharacters)
lastPart.baseVisible = false
discard model.mergeCharacterParts()
firstPart.baseVisible = false
lastPart.baseVisible = true
discard model.mergeCharacterParts()
var living, dead, next: CharacterPose
model.mergedMesh = 0
scene.prepareCharacter(living, model, vec3(0), 0, 0, 0)
let joints = living.toon.meshes[0].joints
model.mergedMesh = 1
scene.prepareCharacter(dead, model, vec3(2, 0, 0), 1, 0, 0)
model.mergedMesh = 0
scene.prepareCharacter(next, model, vec3(4, 0, 0), 2, 0, 0)
doAssert living.toon.meshCount == 1
doAssert living.toon.meshes[0].packedParts
doAssert living.toon.meshes[0].node == model.mergedMeshes[0]
doAssert dead.toon.meshes[0].node == model.mergedMeshes[1]
doAssert living.toon.meshes[0].joints == joints
doAssert living.toon.meshes[0].transform != next.toon.meshes[0].transform
echo "Merged face materials and pose snapshots passed."
