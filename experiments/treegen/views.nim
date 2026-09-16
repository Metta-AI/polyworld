import
  std/os,
  chroma, gltf, jsony, pixie, vmath,
  trees

const
  ExperimentDirectory* = currentSourcePath().parentDir
  AtlasPath* = ExperimentDirectory / "assets/tree-foliage-atlas.png"
  BarkPath* = ExperimentDirectory / "assets/bark.png"
  StumpPath* = ExperimentDirectory / "assets/stump-rings.png"
  CustomPath* = ExperimentDirectory / "presets/custom.json"

type TreeMaterials* = object
  bark*, foliage*, cut*: Material

proc loadMaterials*(textureStrength: float32): TreeMaterials =
  ## Loads leaf, repeating bark, and cut-wood textures for the tree materials.
  var atlas, bark, rings: Image
  try:
    atlas = loadStraightAlphaImage(AtlasPath)
  except IOError, PixieError:
    raise newException(TreegenError, "Cannot load tree atlas: " &
      getCurrentExceptionMsg())
  if atlas.width != 512 or atlas.height != 512:
    raise newException(TreegenError, "Tree atlas must be 512 by 512")
  try:
    bark = loadStraightAlphaImage(BarkPath)
  except IOError, PixieError:
    raise newException(TreegenError, "Cannot load bark texture: " &
      getCurrentExceptionMsg())
  if bark.width != 512 or bark.height != 512:
    raise newException(TreegenError, "Bark texture must be 512 by 512")
  try:
    rings = loadStraightAlphaImage(StumpPath)
  except IOError, PixieError:
    raise newException(TreegenError, "Cannot load stump texture: " &
      getCurrentExceptionMsg())
  if rings.width != 512 or rings.height != 512:
    raise newException(TreegenError, "Stump texture must be 512 by 512")
  for pixel in bark.data.mitems:
    let
      luminance = min(1.0'f, (pixel.r.float32 * 0.2126'f +
        pixel.g.float32 * 0.7152'f + pixel.b.float32 * 0.0722'f) / 170.0'f)
      value = ((1.0'f - textureStrength +
        luminance * textureStrength) * 255.0'f).uint8
    pixel = rgbx(value, value, value, 255)
  let
    barkSampler = TextureSampler(
      magFilter: LinearMagFilter, minFilter: LinearMipmapLinearMinFilter,
      wrapS: RepeatWrap, wrapT: RepeatWrap)
    leafSampler = TextureSampler(
      magFilter: LinearMagFilter, minFilter: LinearMipmapLinearMinFilter,
      wrapS: ClampToEdgeWrap, wrapT: ClampToEdgeWrap)
  result.bark = Material(
    name: "Tintable bark", baseColor: bark, baseColorSampler: barkSampler,
    baseColorFactor: color(1, 1, 1, 1), roughnessFactor: 1,
    alphaMode: OpaqueAlphaMode)
  result.foliage = Material(
    name: "White foliage", baseColor: atlas, baseColorSampler: leafSampler,
    baseColorFactor: color(1, 1, 1, 1), roughnessFactor: 1,
    alphaMode: MaskAlphaMode, alphaCutoff: 0.45, doubleSided: true)
  result.cut = Material(
    name: "Stump rings", baseColor: rings, baseColorSampler: leafSampler,
    baseColorFactor: color(1, 1, 1, 1), roughnessFactor: 1,
    alphaMode: OpaqueAlphaMode)

proc tint*(materials: TreeMaterials, settings: TreeSettings) =
  ## Updates material factors without rebuilding tree geometry.
  materials.bark.baseColorFactor = color(
    settings.barkColor.x, settings.barkColor.y, settings.barkColor.z, 1)
  materials.foliage.baseColorFactor = color(
    settings.leafColor.x, settings.leafColor.y, settings.leafColor.z, 1)

proc primitive(mesh: TreeMesh, material: Material): Primitive =
  ## Converts flat generator data into the shared toon renderer's format.
  result = Primitive(material: material, mode: TrianglesMode,
    indices32: mesh.indices)
  for vertex in mesh.vertices:
    result.points.add vertex.position
    result.normals.add vertex.normal
    result.uvs.add vertex.uv
    let value = (vertex.shade * 255.0'f).uint8
    result.colors.add rgbx(value, value, value, 255)

proc treeNode*(geometry: TreeGeometry, materials: TreeMaterials): Node =
  ## Makes one node with opaque bark, optional cut wood, and cutout leaves.
  result = Node(name: "Generated tree", visible: true,
    scale: vec3(1), rot: quat(0, 0, 0, 1), mesh: Mesh(name: "Tree"))
  result.mesh.primitives.add geometry.bark.primitive(materials.bark)
  if geometry.foliage.vertices.len > 0:
    result.mesh.primitives.add geometry.foliage.primitive(materials.foliage)
  if geometry.cut.vertices.len > 0:
    result.mesh.primitives.add geometry.cut.primitive(materials.cut)

proc groundNode*(): Node =
  ## Creates a neutral ground plane for the shared toon shadow pass.
  let
    white = newImage(1, 1)
    material = Material(name: "Ground", baseColor: white,
      baseColorSampler: defaultTextureSampler(),
      baseColorFactor: color(0.72, 0.74, 0.67, 1), roughnessFactor: 1)
  white.fill(color(1, 1, 1, 1))
  result = Node(name: "Ground", visible: true, scale: vec3(1),
    rot: quat(0, 0, 0, 1), mesh: Mesh(primitives: @[
      Primitive(
        mode: TrianglesMode, material: material,
        points: @[vec3(-100, -0.04, -100), vec3(-100, -0.04, 100),
          vec3(100, -0.04, 100), vec3(100, -0.04, -100)],
        normals: @[vec3(0, 1, 0), vec3(0, 1, 0),
          vec3(0, 1, 0), vec3(0, 1, 0)],
        indices32: @[0'u32, 1, 2, 0, 2, 3])]))

proc saveSettings*(settings: TreeSettings, path: string) =
  ## Saves a validated recipe with library-specific file errors.
  settings.validate()
  try:
    createDir(path.parentDir)
    writeFile(path, settings.toJson())
  except IOError, OSError:
    raise newException(TreegenError, "Cannot save tree preset: " &
      getCurrentExceptionMsg())

proc newHook(settings: var TreeSettings) =
  ## Supplies newly added controls when loading an older saved recipe.
  settings = preset(0)

proc loadSettings*(path: string): TreeSettings =
  ## Parses and validates a saved recipe before applying it to the editor.
  try:
    result = readFile(path).fromJson(TreeSettings)
  except IOError, JsonError, ValueError:
    raise newException(TreegenError, "Cannot load tree preset: " &
      getCurrentExceptionMsg())
  result.validate()

proc exportTree*(settings: TreeSettings, path: string) =
  ## Exports a portable GLB with the tree's textures embedded.
  let
    geometry = generate(settings)
    materials = loadMaterials(settings.barkTexture)
  materials.tint(settings)
  try:
    createDir(path.parentDir)
    treeNode(geometry, materials).writeGLB(path)
  except IOError, OSError, GltfError:
    raise newException(TreegenError, "Cannot export tree: " &
      getCurrentExceptionMsg())
