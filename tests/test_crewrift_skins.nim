## Static ship transforms and reflected face winding without a GPU context.

import
  std/[json, math, os, tempfiles],
  flatty/binny, gltf, vmath,
  ../examples/crewrift/skins

proc matrixValues(matrix: Mat4): seq[float32] =
  ## Flattens an authored matrix in glTF's column-major order.
  for column in 0 ..< 4:
    for row in 0 ..< 4:
      result.add matrix[column, row]

proc shipFixture(matrix: Mat4): string =
  ## Creates a small GLB with one console triangle and an authored matrix.
  var binary: string
  for point in [vec3(0), vec3(1, 0, 0), vec3(0, 0, 1)]:
    for value in [point.x, point.y, point.z]:
      binary.addFloat32(value)
  for i in 0 ..< 3:
    for value in [0.0'f, -1.0'f, 0.0'f]:
      binary.addFloat32(value)
  for i in 0 ..< 6:
    binary.addFloat32(0)
  let document = %*{
    "asset": {"version": "2.0"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [{"name": "Console", "matrix": matrix.matrixValues(), "mesh": 0}],
    "meshes": [{"primitives": [{"attributes": {
      "POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2
    }, "material": 0, "mode": 4}]}],
    "materials": [{"pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1]}}],
    "buffers": [{"byteLength": binary.len}],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 36},
      {"buffer": 0, "byteOffset": 36, "byteLength": 36},
      {"buffer": 0, "byteOffset": 72, "byteLength": 24}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"}
    ]
  }
  var text = $document
  while text.len mod 4 != 0:
    text.add ' '
  result.addUint32(0x46546C67)
  result.addUint32(2)
  result.addUint32(uint32(12 + 8 + text.len + 8 + binary.len))
  result.addUint32(text.len.uint32)
  result.addUint32(0x4E4F534A)
  result.add text
  result.addUint32(binary.len.uint32)
  result.addUint32(0x004E4942)
  result.add binary

proc checkFacing(primitive: Primitive) =
  ## Checks that a baked triangle's front face agrees with its normal.
  let
    a = primitive.points[primitive.indices32[0]].xyz
    b = primitive.points[primitive.indices32[1]].xyz
    c = primitive.points[primitive.indices32[2]].xyz
    normal = primitive.normals[primitive.indices32[0]]
  doAssert dot(cross(b - a, c - a), normal) > 0

echo "Testing authored console matrices and mirrored faces"
block:
  let directory = createTempDir("crewrift-skins-", "")
  defer:
    removeDir(directory)
  for matrix in [
    mat4(),
    scale(vec3(-1, 1, 1)),
    translate(vec3(3, 2, -4)) * rotateY(PI.float32 / 2) *
      scale(vec3(-2, 3, 4))
  ]:
    let path = directory / "console.glb"
    writeFile(path, shipFixture(matrix))
    let primitive = loadShipSkin(path).mesh.primitives[0]
    for i, point in [vec3(0), vec3(1, 0, 0), vec3(0, 0, 1)]:
      let expected = (matrix * vec4(point, 1)).xyz * ShipModelScale
      doAssert length(primitive.points[i].xyz - expected) < 0.0001'f
    let expected =
      if matrix.determinant() < 0:
        @[0'u32, 2, 1]
      else:
        @[0'u32, 1, 2]
    doAssert primitive.indices32 == expected
    primitive.checkFacing()

echo "Testing mirrored indexed mesh batches"
block:
  for wide in [false, true]:
    let
      primitive = Primitive(
        mode: TrianglesMode,
        material: Material(
          baseColorTransform: TextureTransform(scale: vec2(1))
        ),
        points: @[vec3(0), vec3(1, 0, 0), vec3(0, 0, 1)],
        normals: @[vec3(0, -1, 0), vec3(0, -1, 0), vec3(0, -1, 0)],
        uvs: @[vec2(0), vec2(0), vec2(0)]
      )
      root = Node(visible: true, mat: scale(vec3(-1, 1, 1)),
        mesh: Mesh(primitives: @[primitive]))
    if wide:
      primitive.indices32 = @[0'u32, 1, 2]
    else:
      primitive.indices16 = @[0'u16, 1, 2]
    let combined = combineShipSkin(root).mesh.primitives[0]
    doAssert combined.indices32 == @[0'u32, 2, 1]
    combined.checkFacing()

echo "Crewrift skin checks passed"
