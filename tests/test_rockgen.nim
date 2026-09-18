import
  chroma, gltf, vmath,
  polyworld/rockgen

echo "Checking renderable rock nodes through the public generator"
for index in 0 .. PresetNames.high:
  for cut in [0.0'f, 0.5'f, 0.9'f]:
    var settings = preset(index, seed = 73)
    settings.floorCut = cut
    let
      geometry = generateGeometry(settings)
      node: Node = generate(settings)
    doAssert node.visible
    doAssert node.pos == vec3(0)
    doAssert node.scale == vec3(1)
    doAssert node.rot == quat(0, 0, 0, 1)
    doAssert node.mesh.primitives.len == 1
    let
      primitive = node.mesh.primitives[0]
      material = primitive.material
    doAssert primitive.mode == TrianglesMode
    doAssert primitive.indices32 == geometry.mesh.indices
    doAssert primitive.points.len == geometry.mesh.vertices.len
    doAssert primitive.normals.len == primitive.points.len
    doAssert primitive.uvs.len == primitive.points.len
    doAssert primitive.colors.len == primitive.points.len
    for i, vertex in geometry.mesh.vertices:
      doAssert primitive.points[i] == vertex.position
      doAssert primitive.normals[i] == vertex.normal
      doAssert primitive.uvs[i] == vertex.uv
      let shade = (vertex.shade * 255).uint8
      doAssert primitive.colors[i] == rgbx(shade, shade, shade, 255)
    doAssert material.baseColor.width == 512
    doAssert material.baseColor.height == 512
    doAssert material.baseColorFactor == color(
      settings.tint.x, settings.tint.y, settings.tint.z, 1
    )
    doAssert material.baseColorSampler.magFilter == LinearMagFilter
    doAssert material.baseColorSampler.minFilter == LinearMinFilter
    doAssert material.baseColorSampler.wrapS == ClampToEdgeWrap
    doAssert material.baseColorSampler.wrapT == ClampToEdgeWrap
    doAssert material.roughnessFactor == 1
    doAssert material.alphaMode == OpaqueAlphaMode

echo "Checking independent and explicitly shared rock materials"
let
  settings = preset(0)
  first = generate(settings)
  second = generate(settings)
  original = first.mesh.primitives[0].material.baseColorFactor
second.mesh.primitives[0].material.baseColorFactor = color(1, 0, 0, 1)
doAssert first.mesh.primitives[0].material.baseColorFactor == original
let
  materials = loadMaterials()
  geometry = generateGeometry(settings)
  shared = rockNode(geometry, materials)
  neighbor = rockNode(generateGeometry(preset(0, 43)), materials)
  regions = rockNode(geometry, materials, showRegions = true)
materials.tint(settings)
doAssert shared.mesh.primitives[0].material == materials.stone
doAssert neighbor.mesh.primitives[0].material == materials.stone
doAssert regions.mesh.primitives[0].material == materials.regions
doAssert materials.stone.baseColorFactor == original

echo "Public rock generator tests passed"
