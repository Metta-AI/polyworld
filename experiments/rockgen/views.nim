import
  std/[json, os],
  chroma, flatty/binny, gltf, jsony, pixie, vmath,
  polyworld/rockgen

const
  ExperimentDirectory* = currentSourcePath().parentDir
  CustomPath* = ExperimentDirectory / "presets/custom.json"

proc groundNode*(): Node =
  ## Creates a neutral floor for the common toon renderer's sun shadows.
  let
    white = newImage(1, 1)
    material = Material(
      name: "Ground", baseColor: white,
      baseColorSampler: defaultTextureSampler(),
      baseColorFactor: color(0.52, 0.51, 0.50, 1), roughnessFactor: 1
    )
  white.fill(color(1, 1, 1, 1))
  result = Node(
    name: "Ground", visible: true, scale: vec3(1),
    rot: quat(0, 0, 0, 1), mesh: Mesh(primitives: @[
      Primitive(
        mode: TrianglesMode, material: material,
        points: @[vec3(-100, -0.025, -100), vec3(-100, -0.025, 100),
          vec3(100, -0.025, 100), vec3(100, -0.025, -100)],
        normals: @[vec3(0, 1, 0), vec3(0, 1, 0),
          vec3(0, 1, 0), vec3(0, 1, 0)],
        indices32: @[0'u32, 1, 2, 0, 2, 3]
      )
    ])
  )

proc saveSettings*(settings: RockSettings, path: string) =
  ## Saves a validated recipe and wraps filesystem errors.
  settings.validate()
  try:
    createDir(path.parentDir)
    writeFile(path, settings.toJson())
  except IOError, OSError:
    raise newException(RockgenError, "Cannot save rock preset: " &
      getCurrentExceptionMsg())

proc newHook(settings: var RockSettings) =
  ## Supplies defaults for fields omitted by an older recipe.
  settings = preset(0)

proc loadSettings*(path: string): RockSettings =
  ## Loads a recipe with defaults and validates every parameter.
  try:
    result = readFile(path).fromJson(RockSettings)
  except IOError, OSError, jsony.JsonError, ValueError:
    raise newException(RockgenError, "Cannot load rock preset: " &
      getCurrentExceptionMsg())
  result.validate()

proc preserveSampler(path: string, sampler: TextureSampler) =
  ## Restores atlas filtering omitted by the current GLB base-color writer.
  let data = readFile(path)
  if data.len < 20 or data[0 .. 3] != "glTF":
    raise newException(RockgenError, "The exporter produced an invalid GLB")
  let size = data.readUint32(12).int
  if size > data.len - 20:
    raise newException(RockgenError, "The exported GLB JSON is truncated")
  let document = parseJson(data[20 ..< 20 + size])
  if not document.hasKey("samplers"):
    raise newException(RockgenError, "The exported GLB has no texture sampler")
  for item in document["samplers"]:
    item["magFilter"] = %sampler.magFilter.int
    item["minFilter"] = %sampler.minFilter.int
    item["wrapS"] = %sampler.wrapS.int
    item["wrapT"] = %sampler.wrapT.int
  var encoded = $document
  while encoded.len mod 4 != 0:
    encoded.add ' '
  var output = data[0 ..< 20] & encoded & data[20 + size .. ^1]
  output.writeUint32(8, output.len.uint32)
  output.writeUint32(12, encoded.len.uint32)
  writeFile(path, output)

proc exportRock*(settings: RockSettings, path: string) =
  ## Writes a portable GLB with the supplied atlas embedded in its material.
  let
    node = generate(settings)
    sampler = node.mesh.primitives[0].material.baseColorSampler
  try:
    createDir(path.parentDir)
    node.writeGLB(path)
    preserveSampler(path, sampler)
  except IOError, OSError, GltfError, ValueError, JsonParsingError:
    raise newException(RockgenError, "Cannot export rock: " &
      getCurrentExceptionMsg())
