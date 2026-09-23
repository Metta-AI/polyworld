import
  std/[base64, json, os, sets, tempfiles, times],
  flatty/binny, gltf, gltf/ktx2, pixie, pixie/fileformats/png,
  polyworld/[assets, textures],
  ../tools/assetpacks

proc fixture(image: string): string =
  ## Builds two skinned meshes sharing an image and an animated transform.
  var binary = ""
  for value in [0.0'f, 0, 0, 1, 0, 0, 0, 1, 0]:
    binary.addFloat32(value)
  binary.add binary
  for i in 0 ..< 16:
    binary.addFloat32(if i mod 5 == 0: 1.0'f else: 0.0'f)
  binary.addFloat32(0.0'f)
  for value in [1.0'f, 2, 3]:
    binary.addFloat32(value)
  let imageOffset = binary.len
  binary.add image
  let doc = %*{
    "asset": {"version": "2.0"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [
      {"name": "Root", "translation": [2, 3, 4], "children": [1, 2, 3]},
      {"name": "Keep", "mesh": 0, "skin": 0},
      {"name": "Joint"},
      {"name": "Unused", "mesh": 1, "skin": 1}
    ],
    "meshes": [
      {"primitives": [{"attributes": {"POSITION": 0}, "material": 0}]},
      {"primitives": [{"attributes": {"POSITION": 1}, "material": 0}]}
    ],
    "skins": [
      {"joints": [2], "inverseBindMatrices": 2},
      {"joints": [2], "inverseBindMatrices": 2}
    ],
    "animations": [
      {"name": "Idle", "samplers": [{"input": 3, "output": 4}],
       "channels": [{"sampler": 0, "target": {"node": 3, "path": "translation"}}]},
      {"name": "Unused", "samplers": [{"input": 3, "output": 4}],
       "channels": [{"sampler": 0, "target": {"node": 2, "path": "translation"}}]}
    ],
    "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
    "textures": [{"source": 0}],
    "images": [{"bufferView": 5, "mimeType": "image/png"}],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
       "min": [0, 0, 0], "max": [1, 1, 0]},
      {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3",
       "min": [0, 0, 0], "max": [1, 1, 0]},
      {"bufferView": 2, "componentType": 5126, "count": 1, "type": "MAT4"},
      {"bufferView": 3, "componentType": 5126, "count": 1, "type": "SCALAR"},
      {"bufferView": 4, "componentType": 5126, "count": 1, "type": "VEC3"}
    ],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 36},
      {"buffer": 0, "byteOffset": 36, "byteLength": 36},
      {"buffer": 0, "byteOffset": 72, "byteLength": 64},
      {"buffer": 0, "byteOffset": 136, "byteLength": 4},
      {"buffer": 0, "byteOffset": 140, "byteLength": 12},
      {"buffer": 0, "byteOffset": imageOffset, "byteLength": image.len}
    ],
    "buffers": [{"byteLength": binary.len}]
  }
  encodeGlb(doc, binary)

proc expectAssetError(action: proc()) =
  ## Requires a library-specific failure at an asset boundary.
  var failed = false
  try:
    action()
  except AssetError:
    failed = true
  doAssert failed, "Expected AssetError."

echo "Testing lossless PNG compression"
block:
  let image = newImage(16, 16)
  for i in 0 ..< image.data.len:
    image.data[i] = rgbx(i.uint8, 64, 128, 255)
  let
    original = encodePng(image)
    compressed = compressPng(original)
  doAssert compressed.len <= original.len
  doAssert decodePng(compressed).data == decodePng(original).data
  expectAssetError(proc() =
    ## Rejects truncated PNG input.
    discard compressPng(original[0 ..< 20])
  )

echo "Testing browser image size limits and unchanged originals"
block:
  let
    directory = createTempDir("polyworld-images-", "")
    source = directory / "source"
    output = directory / "output"
    image = newImage(32, 16)
  defer:
    removeDir(directory)
  createDir(source)
  image.fill(rgbx(64, 64, 64, 128))
  let original = image.encodePng()
  writeFile(source / "tree.png", original)
  discard packAssets(@[imageAsset("tree.png", 8)], source, output)
  let packed = readImage(output / "stage/tree.png")
  doAssert packed.width == 8 and packed.height == 4
  doAssert packed.data[0] == image.data[0]
  doAssert readFile(source / "tree.png") == original
  discard packAssets(@[imageAsset("tree.png", 64)], source, output)
  let larger = readImage(output / "stage/tree.png")
  doAssert larger.width == image.width and larger.height == image.height

echo "Testing independent BC3 terrain channels"
block:
  let
    color = newImage(16, 16)
    height = newImage(16, 16)
  color.fill(rgbx(255, 0, 0, 255))
  height.fill(rgbx(0, 0, 0, 255))
  let
    bytes = encodeTerrain(color, height)
    info = parseKtx2(bytes)
  doAssert info.width == 16 and info.height == 16
  doAssert info.levelCount == 3
  for level in 0 ..< info.levelCount:
    let pixels = decodeBc3(bytes, info, level)
    for i in 0 ..< pixels.len div 4:
      doAssert pixels[i * 4].ord == 255
      doAssert pixels[i * 4 + 1].ord == 0
      doAssert pixels[i * 4 + 3].ord == 0
  height.fill(rgbx(255, 255, 255, 255))
  let
    raised = encodeTerrain(color, height)
    raisedPixels = decodeBc3(raised, parseKtx2(raised), 0)
  doAssert raisedPixels[0].ord == 255 and raisedPixels[3].ord == 255
  for mip in info.levels:
    for i in 0 ..< mip.byteLength div 16:
      let offset = mip.byteOffset + i * 16 + 8
      doAssert bytes[offset ..< offset + 8] == raised[offset ..< offset + 8]
  let uneven = newImage(12, 12)
  expectAssetError(proc() =
    ## Rejects dimensions that cannot form the supported power-of-two mips.
    discard encodeTerrain(uneven, uneven)
  )

echo "Testing both BC3 height endpoint modes"
for endpoints in [[0'u8, 255'u8], [255'u8, 0'u8]]:
  var
    blockBytes = ""
    bits = endpoints[0].uint64 or (endpoints[1].uint64 shl 8)
  for i in 0 ..< 16:
    bits = bits or ((i mod 8).uint64 shl (16 + i * 3))
  blockBytes.addUint64(bits)
  blockBytes.addUint16(0xf800)
  blockBytes.addUint16(0)
  blockBytes.addUint32(0)
  let
    encoded = encodeKtx2(VkFormatBc3UnormBlock, 4, 4, @[blockBytes])
    pixels = decodeBc3(encoded, parseKtx2(encoded), 0)
    expected =
      if endpoints[0] == 0: [0, 255, 51, 102, 153, 204, 0, 255]
      else: [255, 0, 218, 182, 145, 109, 72, 36]
  for i in 0 ..< 16:
    doAssert pixels[i * 4].ord == 255
    doAssert pixels[i * 4 + 3].ord == expected[i mod 8]

echo "Testing model selection, dependency deduplication, and clean staging"
block:
  let
    directory = createTempDir("polyworld-assets-", "")
    source = directory / "source"
    output = directory / "output"
    stage = output / "stage"
    image = newImage(4, 4)
  defer:
    removeDir(directory)
  createDir(source)
  image.fill(rgbx(200, 100, 50, 255))
  let original = fixture(encodePng(image))
  writeFile(source / "pack.glb", original)
  let
    declaration = modelAsset("pack.glb", @["Keep"], @["Idle"])
    files = packAssets(@[declaration], source, output)
    packedBytes = readFile(stage / "pack.glb")
    packed = parseGlb(packedBytes)
    input = parseGlb(original)
  doAssert packed.doc["meshes"].len == 1
  doAssert packed.doc["skins"].len == 1
  doAssert packed.doc["nodes"][0] == input.doc["nodes"][0]
  doAssert packed.doc["nodes"][2] == input.doc["nodes"][2]
  doAssert "mesh" notin packed.doc["nodes"][3]
  doAssert packed.doc["animations"].len == 1
  doAssert packed.doc["animations"][0]["channels"][0]["target"]["node"].getInt == 3
  doAssert packed.doc["accessors"].len == 4
  doAssert packed.binary.len == 116
  doAssert packed.binary[0 ..< 36] == input.binary[0 ..< 36]
  doAssert packed.binary[36 ..< 116] == input.binary[72 ..< 152]
  doAssert files.len == 2
  doAssert readGltfFile(stage / "pack.glb").root.animations.len == 1
  let report = readFile(output / "report.json")
  let selected = propAssets("pack.glb", ["Keep", "Unused"])
  discard packAssets(selected, source, output)
  var images: HashSet[string]
  for name in ["Keep", "Unused"]:
    let doc = parseGlb(readFile(stage / propPath("pack.glb", name))).doc
    images.incl doc["images"][0]["uri"].getStr
  doAssert images.len == 1
  doAssert not fileExists(stage / "pack.glb")
  discard packAssets(@[declaration], source, output)
  doAssert readFile(stage / "pack.glb") == packedBytes
  doAssert readFile(output / "report.json") == report
  doAssert not dirExists(stage / "pack")
  block:
    var external = parseGlb(original)
    external.doc["buffers"][0]["uri"] = %"geometry.bin"
    external.doc["images"].elems[0] = %*{"uri": "palette%20color.png"}
    writeFile(source / "geometry.bin", external.binary)
    writeFile(source / "palette color.png", encodePng(image))
    writeFile(source / "pack.glb", encodeGlb(external.doc, ""))
    discard packAssets(@[declaration], source, output)
    doAssert readFile(stage / "pack.glb") == packedBytes
    external.doc["buffers"][0]["uri"] = %(
      "data:application/octet-stream;base64," & encode(external.binary)
    )
    writeFile(source / "pack.glb", encodeGlb(external.doc, ""))
    discard packAssets(@[declaration], source, output)
    doAssert readFile(stage / "pack.glb") == packedBytes
    removeFile(source / "palette color.png")
    expectAssetError(proc() =
      ## Rejects missing external image dependencies.
      discard packAssets(@[declaration], source, output)
    )
    writeFile(source / "pack.glb", original)
  expectAssetError(proc() =
    ## Rejects undeclared model names.
    discard packAssets(@[modelAsset("pack.glb", @["Absent"])], source, output)
  )
  expectAssetError(proc() =
    ## Rejects undeclared animation names.
    discard packAssets(
      @[modelAsset("pack.glb", clips = @["Absent"])], source, output
    )
  )
  expectAssetError(proc() =
    ## Rejects missing files.
    discard packAssets(@[fileAsset("absent.png")], source, output)
  )
  expectAssetError(proc() =
    ## Rejects paths outside the asset tree.
    discard safeName("../secret")
  )
  var invalid = parseGlb(original)
  invalid.doc["skins"][0]["joints"].elems[0] = %99
  writeFile(source / "pack.glb", encodeGlb(invalid.doc, invalid.binary))
  expectAssetError(proc() =
    ## Rejects invalid skeleton references before packaging.
    discard packAssets(@[declaration], source, output)
  )
  var unsupported = parseGlb(original)
  unsupported.doc["extensions"] = %*{"UNKNOWN_extension": {}}
  writeFile(source / "pack.glb", encodeGlb(unsupported.doc, unsupported.binary))
  expectAssetError(proc() =
    ## Rejects extensions whose references cannot be preserved.
    discard packAssets(@[declaration], source, output)
  )
  var unlit = parseGlb(original)
  unlit.doc["extensionsUsed"] = %*["KHR_materials_unlit"]
  unlit.doc["materials"][0]["extensions"] = %*{"KHR_materials_unlit": {}}
  writeFile(source / "pack.glb", encodeGlb(unlit.doc, unlit.binary))
  discard packAssets(@[declaration], source, output)
  let packedUnlit = parseGlb(readFile(output / "stage/pack.glb"))
  doAssert "KHR_materials_unlit" in
    packedUnlit.doc["materials"][0]["extensions"]
  unlit.doc["materials"][0]["extensions"]["KHR_materials_specular"] =
    %*{"specularFactor": 0.24}
  writeFile(source / "pack.glb", encodeGlb(unlit.doc, unlit.binary))
  discard packAssets(@[declaration], source, output)
  let
    packedSpecular = parseGlb(readFile(output / "stage/pack.glb"))
    extensions = packedSpecular.doc["materials"][0]["extensions"]
    specular = extensions["KHR_materials_specular"]
  doAssert specular["specularFactor"].getFloat == 0.24
  var emissive = parseGlb(original)
  emissive.doc["extensionsUsed"] = %*["KHR_materials_emissive_strength"]
  emissive.doc["materials"][0]["extensions"] =
    %*{"KHR_materials_emissive_strength": {"emissiveStrength": 1.9}}
  writeFile(source / "pack.glb", encodeGlb(emissive.doc, emissive.binary))
  discard packAssets(@[declaration], source, output)
  let
    packedEmissive = parseGlb(readFile(output / "stage/pack.glb"))
    packedExtensions = packedEmissive.doc["materials"][0]["extensions"]
    strength = packedExtensions["KHR_materials_emissive_strength"]
    emissiveExtensions = emissive.doc["materials"][0]["extensions"]
  doAssert strength["emissiveStrength"].getFloat == 1.9
  emissiveExtensions["KHR_materials_emissive_strength"]["emissiveTexture"] =
    %*{"index": 0}
  writeFile(source / "pack.glb", encodeGlb(emissive.doc, emissive.binary))
  expectAssetError(proc() =
    ## Rejects unknown reference fields inside an accepted scalar extension.
    discard packAssets(@[declaration], source, output)
  )
  let extension = unlit.doc["materials"][0]["extensions"]
  extension["KHR_materials_specular"]["specularTexture"] = %*{"index": 0}
  writeFile(source / "pack.glb", encodeGlb(unlit.doc, unlit.binary))
  expectAssetError(proc() =
    ## Rejects extension texture references that would need remapping.
    discard packAssets(@[declaration], source, output)
  )

echo "Testing cached bakes and content-based invalidation"
block:
  let
    directory = createTempDir("polyworld-cache-", "")
    source = directory / "source"
    output = directory / "output"
    stage = output / "stage"
    unchangedTime = fromUnix(1_000_000_000)
    declarations = @[fileAsset("value.txt")]
  defer:
    removeDir(directory)
  createDir(source)
  writeFile(source / "value.txt", "first")
  let expected = packAssets(declarations, source, output, "baker-v1")
  for path in ["stage/value.txt", "manifest.txt", "report.json", "cache.json"]:
    setLastModificationTime(output / path, unchangedTime)
  setLastModificationTime(source / "value.txt", unchangedTime)
  writeFile(source / "unrelated.txt", "Not selected.")
  doAssert packAssets(declarations, source, output, "baker-v1") == expected
  for path in ["stage/value.txt", "manifest.txt", "report.json", "cache.json"]:
    doAssert getLastModificationTime(output / path) == unchangedTime

  # Content changes invalidate even when both length and timestamp are equal.
  writeFile(source / "value.txt", "other")
  setLastModificationTime(source / "value.txt", unchangedTime)
  discard packAssets(declarations, source, output, "baker-v1")
  doAssert readFile(stage / "value.txt") == "other"
  setLastModificationTime(stage / "value.txt", unchangedTime)
  discard packAssets(declarations, source, output, "baker-v2")
  doAssert getLastModificationTime(stage / "value.txt") != unchangedTime

  for damage in 0 ..< 5:
    case damage
    of 0:
      writeFile(stage / "value.txt", "wrong")
    of 1:
      removeFile(stage / "value.txt")
    of 2:
      writeFile(stage / "stale.txt", "Not selected.")
    of 3:
      removeFile(output / "manifest.txt")
    else:
      writeFile(output / "cache.json", "{incomplete")
    discard packAssets(declarations, source, output, "baker-v2")
    doAssert readFile(stage / "value.txt") == "other"
    doAssert readFile(output / "manifest.txt") == "value.txt\n"
    doAssert not fileExists(stage / "stale.txt")
  var renamed = declarations
  renamed[0].output = "renamed.txt"
  discard packAssets(renamed, source, output, "baker-v2")
  doAssert not fileExists(stage / "value.txt")
  doAssert readFile(stage / "renamed.txt") == "other"

  expectAssetError(proc() =
    ## Prevents failed bakes from leaving reusable partial output.
    discard packAssets(
      declarations & @[fileAsset("missing.txt")], source, output, "baker-v2"
    )
  )
  doAssert not fileExists(output / "cache.json")
  discard packAssets(declarations, source, output, "baker-v2")
  doAssert readFile(stage / "value.txt") == "other"

  let
    image = newImage(4, 4)
    images = @[Asset(kind: ImageDirectory, source: "images")]
  image.fill(rgbx(255, 0, 0, 255))
  createDir(source / "images")
  writeFile(source / "images/a.png", encodePng(image))
  discard packAssets(images, source, output, "baker-v2")
  setLastModificationTime(stage / "images/a.png", unchangedTime)
  discard packAssets(images, source, output, "baker-v2")
  doAssert getLastModificationTime(stage / "images/a.png") == unchangedTime
  writeFile(source / "images/b.png", encodePng(image))
  discard packAssets(images, source, output, "baker-v2")
  doAssert fileExists(stage / "images/b.png")
  removeFile(source / "images/a.png")
  discard packAssets(images, source, output, "baker-v2")
  doAssert not fileExists(stage / "images/a.png")

echo "Testing cached external model dependencies and preset selections"
block:
  let
    directory = createTempDir("polyworld-dependencies-", "")
    source = directory / "source"
    output = directory / "output"
    stage = output / "stage"
    image = newImage(4, 4)
    declaration = modelAsset(
      "pack.glb", clips = @["Idle"], manifest = "parts.json",
      presets = @["Chosen"]
    )
  defer:
    removeDir(directory)
  createDir(source)
  image.fill(rgbx(255, 0, 0, 255))
  var external = parseGlb(fixture(encodePng(image)))
  external.doc["buffers"][0]["uri"] = %"geometry.bin"
  external.doc["images"].elems[0] = %*{"uri": "palette.png"}
  writeFile(source / "pack.glb", encodeGlb(external.doc, ""))
  writeFile(source / "geometry.bin", external.binary)
  writeFile(source / "palette.png", encodePng(image))
  writeFile(source / "parts.json", $(%*{
    "presets": [{"name": "Chosen", "parts": ["Keep"]}]
  }))
  discard packAssets(@[declaration], source, output, "baker")
  let original = readFile(stage / "pack.glb")
  image.fill(rgbx(0, 255, 0, 255))
  writeFile(source / "palette.png", encodePng(image))
  discard packAssets(@[declaration], source, output, "baker")
  let recolored = readFile(stage / "pack.glb")
  doAssert recolored != original
  external.binary[0] = '\1'
  writeFile(source / "geometry.bin", external.binary)
  discard packAssets(@[declaration], source, output, "baker")
  doAssert parseGlb(readFile(stage / "pack.glb")).binary[0] == '\1'
  writeFile(source / "parts.json", $(%*{
    "presets": [{"name": "Chosen", "parts": ["Unused"]}]
  }))
  discard packAssets(@[declaration], source, output, "baker")
  let doc = parseGlb(readFile(stage / "pack.glb")).doc
  doAssert "mesh" notin doc["nodes"][1]
  doAssert "mesh" in doc["nodes"][3]

echo "Asset packaging tests passed"
