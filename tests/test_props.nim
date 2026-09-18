import
  std/[json, os, tempfiles],
  flatty/binny, vmath,
  polyworld/quadterrain,
  ../tools/assetpacks

proc assembledFixture(): string =
  ## Builds a translated tower body with a smaller elevated flag mesh.
  var binary = ""
  for value in [-1.0'f, 0, 0, 1, 0, 0, 0, 2, 0]:
    binary.addFloat32(value)
  for index in [0'u16, 1, 2]:
    binary.addUint16(index)
  let doc = %*{
    "asset": {"version": "2.0"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [
      {"name": "Root", "translation": [7, 5, -4], "children": [1, 2, 3]},
      {"name": "Body", "mesh": 0},
      {"name": "Flag", "mesh": 0, "translation": [1, 3, 1],
       "scale": [0.25, 0.25, 0.25]},
      {"name": "fire", "translation": [0, 9, 0]}
    ],
    "meshes": [{"primitives": [
      {"attributes": {"POSITION": 0}, "indices": 1}
    ]}],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
       "min": [-1, 0, 0], "max": [1, 2, 0]},
      {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}
    ],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 36},
      {"buffer": 0, "byteOffset": 36, "byteLength": 6}
    ],
    "buffers": [{"byteLength": binary.len}]
  }
  encodeGlb(doc, binary)

echo "Testing assembled prop scale and relative mesh placement"
block:
  let directory = createTempDir("polyworld-props-", "")
  defer:
    removeDir(directory)
  let path = directory / "tower.glb"
  writeFile(path, assembledFixture())
  for unitHeight in [false, true]:
    let
      pack = loadPropPack(path, unitHeight = unitHeight, mergeNodes = true)
      factor = if unitHeight: 1.0'f / 3.5'f else: 1.0'f
    doAssert pack.hasProp("tower")
    doAssert not pack.hasProp("Flag")
    for target in [vec3(-0.125, 0.5, -0.5), vec3(0.875, 3.1, 0.5)]:
      let
        point = target * factor
        distance = pack.pickProp(
          "tower", vec3(point.x, point.y, 2), vec3(0, 0, -1),
          vec3(0), 0, 1)
      doAssert abs(distance - (2 - point.z)) < 0.0001'f
    doAssert pack.pickProp(
      "tower", vec3(0, 2.5'f * factor, 2), vec3(0, 0, -1),
      vec3(0), 0, 1) < 0
  let separate = loadPropPack(path)
  doAssert separate.hasProp("Body") and separate.hasProp("Flag")
  doAssert not separate.hasProp("tower")

echo "Prop tests passed"
