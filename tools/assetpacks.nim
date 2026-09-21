import
  std/[algorithm, base64, json, os, sets, sha1, strutils, tables, uri],
  gltf/ktx2, jsony, pixie, pixie/fileformats/png, zippy, zippy/crc,
  polyworld/assets

type
  PackedFile* = object
    path*: string
    bytes*: int
  HashedFile = object
    path, hash: string
  AssetCache = object
    recipe: string
    inputs, outputs: seq[HashedFile]
    files: seq[PackedFile]
  AssetPacker* = object
    source*, stage*: string
    files*: Table[string, int]
    images: Table[string, string]
    inputs: Table[string, string]

const CacheVersion = 1

proc read32(data: string, offset: int): uint32 =
  ## Reads a bounded little-endian integer.
  if offset < 0 or offset + 4 > data.len:
    raise newException(AssetError, "Truncated binary asset.")
  for i in 0 ..< 4:
    result = result or (data[offset + i].ord.uint32 shl (i * 8))

proc add32(data: var string, value: uint32) =
  ## Appends a little-endian integer.
  for i in 0 ..< 4:
    data.add char((value shr (i * 8)) and 255)

proc readBe(data: string, offset: int): uint32 =
  ## Reads a bounded PNG integer.
  for i in 0 ..< 4:
    if offset + i >= data.len:
      raise newException(AssetError, "Truncated PNG chunk.")
    result = (result shl 8) or data[offset + i].ord.uint32

proc addBe(data: var string, value: uint32) =
  ## Appends a PNG integer.
  for i in countdown(3, 0):
    data.add char((value shr (i * 8)) and 255)

proc pngChunk(kind, data: string): string =
  ## Encodes a PNG chunk with a fresh checksum.
  result.addBe(data.len.uint32)
  result.add kind
  result.add data
  let checked = kind & data
  result.addBe(crc32(checked))

proc compressPng*(data: string): string =
  ## Recompresses scanlines without changing pixels or ancillary metadata.
  if not data.startsWith("\x89PNG\r\n\x1a\n"):
    raise newException(AssetError, "Invalid PNG signature.")
  var
    offset = 8
    compressed = ""
    chunks: seq[tuple[kind, bytes: string]]
  while offset < data.len:
    let size = data.readBe(offset).int
    if size > data.len - offset - 12:
      raise newException(AssetError, "Truncated PNG payload.")
    let
      kind = data[offset + 4 ..< offset + 8]
      payload = data[offset + 8 ..< offset + 8 + size]
    if crc32(kind & payload) != data.readBe(offset + 8 + size):
      raise newException(AssetError, "Invalid PNG checksum.")
    chunks.add (kind, data[offset ..< offset + size + 12])
    if kind == "IDAT":
      compressed.add payload
    offset += size + 12
  try:
    compressed = compress(uncompress(compressed, dfZlib), BestCompression, dfZlib)
  except ZippyError as error:
    raise newException(AssetError, "Invalid PNG image data: " & error.msg)
  result = data[0 ..< 8]
  var written = false
  for chunk in chunks:
    if chunk.kind == "IDAT":
      if not written:
        result.add pngChunk("IDAT", compressed)
        written = true
    else:
      result.add chunk.bytes
  if not written:
    raise newException(AssetError, "PNG has no image data.")
  if result.len >= data.len:
    result = data

proc safeName*(name: string): string =
  ## Rejects paths outside the declared asset tree.
  result = name.replace('\\', '/').normalizedPath.replace('\\', '/')
  if result.len == 0 or result == "." or result.isAbsolute or
    result == ".." or result.startsWith("../") or ':' in result:
      raise newException(AssetError, "Invalid asset path: " & name)

proc save(packer: var AssetPacker, name, bytes: string) =
  ## Writes a generated file once and rejects conflicting declarations.
  let
    name = name.safeName
    path = packer.stage / name
  if name in packer.files:
    if readFile(path) != bytes:
      raise newException(AssetError, "Conflicting asset declarations: " & name)
    return
  createDir(path.parentDir)
  writeFile(path, bytes)
  packer.files[name] = bytes.len

proc sourceFile(packer: var AssetPacker, name: string): string =
  ## Reads and fingerprints a declared file or a discovered model dependency.
  let
    name = name.safeName
    path = packer.source / name
  if not fileExists(path):
    raise newException(AssetError, "Missing asset: " & name)
  result = readFile(path)
  let hash = $secureHash(result)
  if name in packer.inputs and packer.inputs[name] != hash:
    raise newException(AssetError, "Asset changed while packing: " & name)
  packer.inputs[name] = hash

proc copyAsset(packer: var AssetPacker, source, output: string) =
  ## Copies a file while applying lossless PNG compression.
  let data = packer.sourceFile(source)
  packer.save(output, if source.endsWith(".png"): compressPng(data) else: data)

proc parseGlb*(data: string): tuple[doc: JsonNode, binary: string] =
  ## Reads a validated glTF 2 binary container.
  if data.len < 20 or data.read32(0) != 0x46546C67 or
    data.read32(4) != 2 or data.read32(8).int != data.len:
      raise newException(AssetError, "Invalid GLB header.")
  var
    offset = 12
    hasBinary = false
  while offset < data.len:
    let
      size = data.read32(offset).int
      kind = data.read32(offset + 4)
    if size mod 4 != 0 or size > data.len - offset - 8:
      raise newException(AssetError, "Invalid GLB chunk length.")
    let chunk = data[offset + 8 ..< offset + 8 + size]
    if offset == 12 and kind != 0x4E4F534A:
      raise newException(AssetError, "GLB must begin with a JSON chunk.")
    case kind
    of 0x4E4F534A:
      if result.doc != nil:
        raise newException(AssetError, "Duplicate GLB JSON chunk.")
      try:
        result.doc = parseJson(chunk)
      except JsonParsingError as error:
        raise newException(AssetError, "Invalid GLB JSON: " & error.msg)
    of 0x004E4942:
      if hasBinary:
        raise newException(AssetError, "Duplicate GLB binary chunk.")
      result.binary = chunk
      hasBinary = true
    else:
      raise newException(AssetError, "Unsupported GLB chunk.")
    offset += size + 8
  if result.doc == nil:
    raise newException(AssetError, "GLB has no JSON document.")

proc encodeGlb*(doc: JsonNode, binary: string): string =
  ## Writes deterministic, four-byte-aligned GLB chunks.
  var
    json = $doc
    binary = binary
  while json.len mod 4 != 0:
    json.add ' '
  while binary.len mod 4 != 0:
    binary.add '\0'
  result = "glTF"
  result.add32(2)
  result.add32((28 + json.len + binary.len).uint32)
  result.add32(json.len.uint32)
  result.add "JSON"
  result.add json
  result.add32(binary.len.uint32)
  result.add "BIN\0"
  result.add binary

proc rejectExtensions(node: JsonNode) =
  ## Refuses opaque references that this model compactor cannot remap.
  case node.kind
  of JObject:
    for key, child in node:
      if key == "extensions":
        for name, extension in child:
          # These material values contain no indices needing remapping.
          var supported = extension.kind == JObject
          case name
          of "KHR_materials_unlit":
            supported = supported and extension.len == 0
          of "KHR_materials_specular":
            if supported:
              for field, value in extension:
                supported = supported and
                  field in ["specularFactor", "specularColorFactor"]
          else:
            supported = false
          if not supported:
            raise newException(
              AssetError, "Unsupported GLB extension: " & name
            )
      if key != "extras":
        rejectExtensions(child)
  of JArray:
    for child in node:
      rejectExtensions(child)
  else:
    discard

proc entries(doc: JsonNode, key: string): JsonNode =
  ## Returns an optional array without modifying the document.
  if key in doc: doc[key] else: newJArray()

proc compact(doc: JsonNode, key: string, refs: seq[JsonNode]) =
  ## Keeps referenced array entries and rewrites their integer references.
  let values = doc.entries(key)
  var
    used = newSeq[bool](values.len)
    remap = newSeq[int](values.len)
    kept = newJArray()
  for reference in refs:
    let index = reference.getInt(-1)
    if index < 0 or index >= values.len:
      raise newException(AssetError, "Invalid GLB " & key & " reference.")
    used[index] = true
  for i in 0 ..< values.len:
    if used[i]:
      remap[i] = kept.len
      kept.add values[i]
  for reference in refs:
    reference.num = remap[reference.getInt].BiggestInt
  if kept.len > 0:
    doc[key] = kept
  elif key in doc:
    doc.delete(key)

proc fieldRefs(values: JsonNode, field: string): seq[JsonNode] =
  ## Collects direct references in an array of objects.
  for value in values:
    if field in value:
      result.add value[field]

proc checkReference(values, reference: JsonNode, label: string) =
  ## Rejects a missing, non-integer, or out-of-range model reference.
  if reference == nil or reference.kind != JInt or
    reference.getInt < 0 or reference.getInt >= values.len:
      raise newException(AssetError, "Invalid GLB " & label & " reference.")

proc validateNodes(doc: JsonNode) =
  ## Checks preserved transforms, scene roots, skin joints, and clip targets.
  if doc{"asset", "version"}.getStr != "2.0":
    raise newException(AssetError, "Expected a glTF 2.0 model.")
  let nodes = doc.entries("nodes")
  var
    parents = newSeq[int](nodes.len)
    visited = newSeq[uint8](nodes.len)
  for node in nodes:
    for child in node.entries("children"):
      checkReference(nodes, child, "child node")
      inc parents[child.getInt]
      if parents[child.getInt] > 1:
        raise newException(AssetError, "GLB node has multiple parents.")
    for (field, array) in [("mesh", "meshes"), ("skin", "skins")]:
      if field in node:
        checkReference(doc.entries(array), node[field], field)
  proc visit(index: int) =
    ## Rejects cyclic transform graphs before the runtime traverses them.
    if visited[index] == 1:
      raise newException(AssetError, "Cyclic GLB node hierarchy.")
    if visited[index] == 2:
      return
    visited[index] = 1
    for child in nodes[index].entries("children"):
      visit(child.getInt)
    visited[index] = 2
  for i in 0 ..< nodes.len:
    visit(i)
  for scene in doc.entries("scenes"):
    for node in scene.entries("nodes"):
      checkReference(nodes, node, "scene node")
  if "scene" in doc:
    checkReference(doc.entries("scenes"), doc["scene"], "scene")
  for skin in doc.entries("skins"):
    for joint in skin.entries("joints"):
      checkReference(nodes, joint, "skin joint")
    if "skeleton" in skin:
      checkReference(nodes, skin["skeleton"], "skeleton")
  for animation in doc.entries("animations"):
    for channel in animation.entries("channels"):
      checkReference(
        animation.entries("samplers"), channel{"sampler"}, "clip sampler"
      )
      checkReference(nodes, channel{"target", "node"}, "clip target")
      if channel{"target", "path"}.getStr notin
        ["translation", "rotation", "scale", "weights"]:
          raise newException(AssetError, "Unsupported GLB animation target.")

proc textureRefs(node: JsonNode): seq[JsonNode] =
  ## Finds texture slots in the core glTF material schema.
  if node.kind != JObject:
    return
  for key, value in node:
    if key.endsWith("Texture") and value.kind == JObject and "index" in value:
      result.add value["index"]
    elif key == "pbrMetallicRoughness":
      result.add textureRefs(value)

proc viewBytes(doc: JsonNode, buffers: seq[string], index: int): string =
  ## Returns the exact bytes of a validated buffer view.
  let views = doc.entries("bufferViews")
  if index < 0 or index >= views.len:
    raise newException(AssetError, "Invalid GLB buffer view.")
  let
    view = views[index]
    buffer = view["buffer"].getInt
    offset = view{"byteOffset"}.getInt
    size = view["byteLength"].getInt
  if buffer < 0 or buffer >= buffers.len or offset < 0 or size < 0 or
    offset > buffers[buffer].len or size > buffers[buffer].len - offset:
      raise newException(AssetError, "GLB buffer view exceeds its buffer.")
  buffers[buffer][offset ..< offset + size]

proc uriBytes(packer: var AssetPacker, directory, value: string): string =
  ## Resolves a local or embedded image or buffer dependency.
  if value.startsWith("data:"):
    let comma = value.find(',')
    if comma < 0 or not value[0 ..< comma].endsWith(";base64"):
      raise newException(AssetError, "Unsupported data URI.")
    try:
      return decode(value[comma + 1 .. ^1])
    except ValueError as error:
      raise newException(AssetError, "Invalid data URI: " & error.msg)
  if ":" in value:
    raise newException(AssetError, "Remote asset URI is unsupported: " & value)
  packer.sourceFile(directory / decodeUrl(value, false))

proc packModel(packer: var AssetPacker, asset: Asset) =
  ## Removes unused model data while preserving transforms and animation rigs.
  let
    loaded = parseGlb(packer.sourceFile(asset.source))
    doc = loaded.doc
    directory = asset.source.parentDir
  rejectExtensions(doc)
  validateNodes(doc)
  var
    buffers: seq[string]
    names = asset.nodes
  for i in 0 ..< doc.entries("buffers").len:
    let buffer = doc["buffers"][i]
    if i > 0 and "uri" notin buffer:
      raise newException(AssetError, "Only the first GLB buffer may be embedded.")
    let bytes =
      if "uri" in buffer:
        packer.uriBytes(directory, buffer["uri"].getStr)
      else:
        loaded.binary
    if bytes.len < buffer["byteLength"].getInt:
      raise newException(AssetError, "Truncated model buffer: " & asset.source)
    buffers.add bytes
  if asset.presets.len > 0:
    let manifest = parseJson(packer.sourceFile(asset.manifest))
    for preset in asset.presets:
      var found = false
      for entry in manifest["presets"]:
        if entry["name"].getStr == preset:
          found = true
          for part in entry["parts"]:
            names.add part.getStr
      if not found:
        raise newException(AssetError, "Missing character preset: " & preset)
  let nodes = doc.entries("nodes")
  if names.len > 0:
    var found: HashSet[string]
    for node in nodes:
      if "mesh" in node:
        let name = node{"name"}.getStr
        if name in names:
          found.incl name
        else:
          node.delete("mesh")
          if "skin" in node:
            node.delete("skin")
          if "weights" in node:
            node.delete("weights")
    for name in names:
      if name notin found:
        raise newException(AssetError, asset.source & ": missing mesh " & name)
  if asset.clips.len > 0:
    var
      kept = newJArray()
      found: HashSet[string]
    for animation in doc.entries("animations"):
      let name = animation{"name"}.getStr
      if name in asset.clips:
        kept.add animation
        found.incl name
    for name in asset.clips:
      if name notin found:
        raise newException(AssetError, asset.source & ": missing clip " & name)
    doc["animations"] = kept
  for animation in doc.entries("animations"):
    for channel in animation.entries("channels"):
      if channel["target"]["path"].getStr == "weights" and
        "mesh" notin nodes[channel["target"]["node"].getInt]:
          raise newException(
            AssetError, "Cannot retain morph animation for a removed mesh."
          )
  doc.compact("meshes", nodes.fieldRefs("mesh"))
  doc.compact("skins", nodes.fieldRefs("skin"))
  var
    materials, accessors, textures, views: seq[JsonNode]
  for mesh in doc.entries("meshes"):
    for primitive in mesh["primitives"]:
      if "indices" in primitive:
        accessors.add primitive["indices"]
      for _, index in primitive["attributes"]:
        accessors.add index
      for target in primitive.entries("targets"):
        for _, index in target:
          accessors.add index
      if "material" in primitive:
        materials.add primitive["material"]
  accessors.add doc.entries("skins").fieldRefs("inverseBindMatrices")
  for animation in doc.entries("animations"):
    accessors.add animation["samplers"].fieldRefs("input")
    accessors.add animation["samplers"].fieldRefs("output")
  doc.compact("materials", materials)
  for material in doc.entries("materials"):
    textures.add textureRefs(material)
  doc.compact("textures", textures)
  doc.compact("samplers", doc.entries("textures").fieldRefs("sampler"))
  doc.compact("images", doc.entries("textures").fieldRefs("source"))
  for image in doc.entries("images"):
    var bytes =
      if "uri" in image:
        packer.uriBytes(directory, image["uri"].getStr)
      else:
        doc.viewBytes(buffers, image["bufferView"].getInt)
    var png = bytes.startsWith("\x89PNG")
    let jpeg = bytes.startsWith("\xff\xd8")
    if asset.size > 0 and (png or jpeg):
      let sourceImage = decodeImage(bytes)
      if max(sourceImage.width, sourceImage.height) > asset.size:
        let scale = asset.size.float / max(
          sourceImage.width, sourceImage.height).float
        bytes = sourceImage.resize(
          max(1, int(sourceImage.width.float * scale)),
          max(1, int(sourceImage.height.float * scale))
        ).encodePng()
        png = true
    let
      extension =
        if png: ".png"
        elif jpeg: ".jpg"
        elif bytes.startsWith("\xABKTX 20"): ".ktx2"
        elif bytes.startsWith("RIFF"): ".webp"
        else:
          raise newException(AssetError, "Unsupported embedded image.")
      digest = $secureHash(bytes)
    var name = packer.images.getOrDefault(digest)
    if name.len == 0:
      if png:
        bytes = compressPng(bytes)
      name = "textures/" & digest.toLowerAscii & extension
      packer.save(name, bytes)
      packer.images[digest] = name
    image["uri"] = %relativePath(name, asset.output.parentDir).replace('\\', '/')
    if "bufferView" in image:
      image.delete("bufferView")
    if "mimeType" in image:
      image.delete("mimeType")
  doc.compact("accessors", accessors)
  for accessor in doc.entries("accessors"):
    if "bufferView" in accessor:
      views.add accessor["bufferView"]
    if "sparse" in accessor:
      views.add accessor["sparse"]["indices"]["bufferView"]
      views.add accessor["sparse"]["values"]["bufferView"]
  doc.compact("bufferViews", views)
  var binary = ""
  for view in doc.entries("bufferViews"):
    while binary.len mod 4 != 0:
      binary.add '\0'
    let
      offset = binary.len
      source = view["buffer"].getInt
      start = view{"byteOffset"}.getInt
      size = view["byteLength"].getInt
    if source < 0 or source >= buffers.len or start < 0 or size < 0 or
      start > buffers[source].len or size > buffers[source].len - start:
        raise newException(AssetError, "Invalid retained model buffer view.")
    binary.add buffers[source][start ..< start + size]
    view["buffer"] = %0
    view["byteOffset"] = %offset
  doc["buffers"] = %*[{"byteLength": binary.len}]
  packer.save(asset.output, encodeGlb(doc, binary))

proc encodeTerrain*(color, height: Image): string =
  ## Packs independently filtered color and height into linear BC3 mip levels.
  if color.width != height.width or color.height != height.height or
    color.width != color.height or color.width < 4 or
    (color.width and (color.width - 1)) != 0:
      raise newException(
        AssetError, "Terrain images must be matching power-of-two squares."
      )
  let size = color.width
  var
    color = color
    height = height
    levels: seq[string]
  while color.width >= 4:
    let
      colors = encodeKtx2ImageLevel(color, VkFormatBc1RgbUnormBlock)
      heights = encodeKtx2ImageLevel(height, VkFormatBc4UnormBlock)
    var bytes = ""
    for i in 0 ..< colors.len div 8:
      bytes.add heights[i * 8 ..< i * 8 + 8]
      bytes.add colors[i * 8 ..< i * 8 + 8]
    levels.add bytes
    color = color.minifyBy2()
    height = height.minifyBy2()
  encodeKtx2(VkFormatBc3UnormBlock, size, size, levels)

proc packTerrain(packer: var AssetPacker, asset: Asset) =
  ## Resizes one material pair and emits its requested browser representation.
  let
    color = decodeImage(packer.sourceFile(asset.source & "_color.png")).resize(
      asset.size, asset.size
    )
    height = decodeImage(packer.sourceFile(asset.source & "_height.png")).resize(
      asset.size, asset.size
    )
  if asset.compressed:
    packer.save(asset.source & ".ktx2", encodeTerrain(color, height))
  else:
    packer.save(asset.source & "_color.png", compressPng(color.encodePng()))
    packer.save(asset.source & "_height.png", compressPng(height.encodePng()))

proc imageFiles(source, name: string): seq[string] =
  ## Lists selected directory members so additions and removals invalidate it.
  let directory = source / name.safeName
  if not dirExists(directory):
    raise newException(AssetError, "Missing image directory: " & directory)
  for kind, path in walkDir(directory):
    if kind == pcFile and path.endsWith(".png"):
      result.add relativePath(path, source).replace('\\', '/')
  result.sort()

proc outputFiles(output: string): seq[string] =
  ## Lists staged files, packaging reports, and the optional HTML logo.
  let stage = output / "stage"
  if dirExists(stage):
    for path in walkDirRec(stage, yieldFilter = {
      pcFile, pcLinkToFile, pcLinkToDir
    }):
      result.add relativePath(path, output).replace('\\', '/')
  result.add "manifest.txt"
  result.add "report.json"
  if fileExists(output / "loading-logo.png"):
    result.add "loading-logo.png"
  result.sort()

proc matchingFiles(root: string, files: seq[HashedFile]): bool =
  ## Checks contents rather than timestamps, including missing dependencies.
  for file in files:
    let path = root / file.path.safeName
    if not fileExists(path) or symlinkExists(path) or
      $secureHashFile(path) != file.hash:
        return false
  true

proc cachedAssets(
  source, output, recipe: string, cache: var AssetCache
): bool =
  ## Reuses only a complete cache with unchanged inputs and generated files.
  let path = output / "cache.json"
  if not fileExists(path) or not dirExists(output / "stage"):
    return false
  try:
    cache = readFile(path).fromJson(AssetCache)
  except jsony.JsonError:
    # Interrupted or obsolete cache metadata is disposable and can be rebuilt.
    return false
  if cache.recipe != recipe:
    return false
  let names = outputFiles(output)
  if names.len != cache.outputs.len:
    return false
  for i, name in names:
    if name != cache.outputs[i].path:
      return false
  matchingFiles(source, cache.inputs) and matchingFiles(output, cache.outputs)

proc packAssets*(
  declarations: seq[Asset], source, output: string, revision = "", logo = ""
): seq[PackedFile] =
  ## Reuses verified assets or rebuilds the stage, using an executable revision.
  let
    source = source.absolutePath.normalizedPath
    output = output.absolutePath.normalizedPath
    stage = output / "stage"
  if source == stage or source.startsWith(stage & DirSep) or
    stage.startsWith(source & DirSep) or symlinkExists(stage):
      raise newException(AssetError, "Asset output must be separate from sources.")
  try:
    var directoryFiles: seq[seq[string]]
    for asset in declarations:
      if asset.kind == ImageDirectory:
        directoryFiles.add imageFiles(source, asset.source)
    let
      revision =
        if revision.len > 0: revision
        else: $secureHashFile(getAppFilename())
      recipe = $secureHash($(%*{
        "version": CacheVersion,
        "revision": revision,
        "source": source,
        "assets": declarations,
        "logo": logo,
        "directories": directoryFiles
      }))
      cachePath = output / "cache.json"
    var cache: AssetCache
    if cachedAssets(source, output, recipe, cache):
      echo "Assets unchanged, skipping bake: ", stage
      return cache.files
    if fileExists(cachePath):
      removeFile(cachePath)
    if dirExists(stage):
      removeDir(stage)
    createDir(stage)
    var packer = AssetPacker(source: source, stage: stage)
    let logoPath = output / "loading-logo.png"
    if fileExists(logoPath):
      removeFile(logoPath)
    if logo.len > 0:
      let
        image = decodeImage(packer.sourceFile(logo.assetName))
        scale = min(1.0, min(320 / image.width, 240 / image.height))
        preview = image.resize(
          max(1, int(image.width.float * scale)),
          max(1, int(image.height.float * scale))
        )
      writeFile(logoPath, compressPng(preview.encodePng()))
    for asset in declarations:
      case asset.kind
      of FileAsset:
        packer.copyAsset(asset.source, asset.output)
      of ImageAsset:
        let
          image = decodeImage(packer.sourceFile(asset.source))
          scale = min(1.0, asset.size.float / max(image.width, image.height).float)
          resized = image.resize(
            max(1, int(image.width.float * scale)),
            max(1, int(image.height.float * scale))
          )
        packer.save(asset.output, compressPng(resized.encodePng()))
      of ImageDirectory:
        for name in imageFiles(source, asset.source):
          packer.copyAsset(name, name)
      of ModelAsset:
        packer.packModel(asset)
      of TerrainAsset:
        packer.packTerrain(asset)
    for path, bytes in packer.files:
      result.add PackedFile(path: path, bytes: bytes)
    result.sort(proc(a, b: PackedFile): int =
      ## Orders output independently of declaration or directory iteration.
      cmp(a.path, b.path)
    )
    var
      total = 0
      manifest = ""
      report = newJArray()
    for file in result:
      total += file.bytes
      manifest.add file.path & "\n"
      report.add %*{"path": file.path, "bytes": file.bytes}
    writeFile(output / "manifest.txt", manifest)
    writeFile(output / "report.json", $(%*{"bytes": total, "files": report}))
    cache = AssetCache(recipe: recipe, files: result)
    for path, hash in packer.inputs:
      cache.inputs.add HashedFile(path: path, hash: hash)
    cache.inputs.sort(proc(a, b: HashedFile): int =
      ## Keeps dependency metadata stable between equivalent builds.
      cmp(a.path, b.path)
    )
    for path in outputFiles(output):
      cache.outputs.add HashedFile(
        path: path, hash: $secureHashFile(output / path)
      )
    writeFile(cachePath & ".tmp", cache.toJson())
    moveFile(cachePath & ".tmp", cachePath)
    echo result.len, " files, ", formatFloat(total.float / 1048576, ffDecimal, 2),
      " MiB: ", stage
  except AssetError:
    raise
  except CatchableError as error:
    raise newException(AssetError, "Asset packaging failed: " & error.msg)
