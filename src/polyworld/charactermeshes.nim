import
  std/tables,
  chroma, gltf, pixie, vmath

const
  AtlasSize = 512
  AtlasPadding = 4
  JointLimit = 128

type
  CharacterMeshError* = object of CatchableError
  TextureRegion = object
    x, y, width, height: int

proc tint(a, b: Color): Color =
  ## Multiplies material and vertex colors component by component.
  color(a.r * b.r, a.g * b.g, a.b * b.b, a.a * b.a)

proc straight(pixel: ColorRGBX): Color =
  ## Reads the straight RGBA bytes used by glTF GPU textures and attributes.
  color(pixel.r.float32 / 255, pixel.g.float32 / 255,
    pixel.b.float32 / 255, pixel.a.float32 / 255)

proc addTexture(
  atlas, image: Image,
  regions: var Table[pointer, TextureRegion],
  x, y, rowHeight: var int
): TextureRegion =
  ## Packs a face texture with extruded borders, retaining its original size.
  let key = cast[pointer](image)
  if key in regions:
    return regions[key]
  let
    width = image.width + AtlasPadding * 2
    height = image.height + AtlasPadding * 2
  if x + width > AtlasSize:
    x = 0
    y += rowHeight
    rowHeight = 0
  if width > AtlasSize or y + height > AtlasSize - AtlasPadding * 2:
    raise newException(CharacterMeshError, "Character face atlas exceeds 512.")
  result = TextureRegion(x: x + AtlasPadding, y: y + AtlasPadding,
    width: image.width, height: image.height)
  for dz in -AtlasPadding ..< image.height + AtlasPadding:
    for dx in -AtlasPadding ..< image.width + AtlasPadding:
      atlas[result.x + dx, result.y + dz] = image[
        clamp(dx, 0, image.width - 1), clamp(dz, 0, image.height - 1)]
  regions[key] = result
  x += width
  rowHeight = max(rowHeight, height)

proc jointIndex(skin: gltf.Skin, joint: Node, inverseBind: Mat4): uint16 =
  ## Shares a joint only when both its node and inverse bind matrix match.
  for i, existing in skin.joints:
    if existing == joint and skin.inverseBindMatrices[i] == inverseBind:
      return i.uint16
  if skin.joints.len >= JointLimit:
    raise newException(CharacterMeshError, "Character exceeds 128 skin joints.")
  result = skin.joints.len.uint16
  skin.joints.add joint
  skin.inverseBindMatrices.add inverseBind

proc mergePrimitive(
  merged: Primitive,
  skin: gltf.Skin,
  node: Node,
  source: Primitive,
  unlit: bool,
  atlas: Image,
  regions: var Table[pointer, TextureRegion],
  x, y, rowHeight: var int
) =
  ## Appends triangles, preserving skin weights and baking material colors.
  let material = source.material
  if source.mode != TrianglesMode or source.morphTargets.len > 0:
    raise newException(
      CharacterMeshError, "Unsupported character geometry: " & node.name
    )
  if source.normals.len != source.points.len:
    raise newException(CharacterMeshError, "Character needs vertex normals.")
  if node.skin != nil and
    (source.jointIds.len != source.points.len or
    source.jointWeights.len != source.points.len):
      raise newException(
        CharacterMeshError, "Character has incomplete weights."
      )
  if material.baseColorKtx2.len > 0:
    raise newException(CharacterMeshError,
      "Character texture needs CPU pixels: " & node.name)
  if material.emissive != nil and
    (material.emissive.width > 1 or material.emissive.height > 1):
      raise newException(CharacterMeshError,
        "Character emissive texture needs an atlas: " & node.name)
  var emission = vec3(material.emissiveFactor.r,
    material.emissiveFactor.g, material.emissiveFactor.b)
  if material.emissive != nil:
    let pixel = material.emissive.data[0].straight
    emission *= vec3(pixel.r, pixel.g, pixel.b)
  var
    region: TextureRegion
    solid = material.baseColorFactor
  let textured = material.baseColor != nil and
    (material.baseColor.width > 1 or material.baseColor.height > 1)
  if textured:
    region = addTexture(atlas, material.baseColor, regions, x, y, rowHeight)
    if source.uvs.len != source.points.len:
      raise newException(
        CharacterMeshError, "Face texture needs UV coordinates."
      )
  elif material.baseColor != nil:
    solid = tint(solid, material.baseColor.data[0].straight)
  let offset = merged.points.len.uint32
  for i, point in source.points:
    var
      ids: JointIds
      weights = vec4(1, 0, 0, 0)
      vertexColor = solid
      uv = vec2((AtlasSize - 1).float32 / AtlasSize.float32)
    if source.colors.len > 0:
      vertexColor = tint(vertexColor, source.colors[i].straight)
    if textured:
      uv = vec2(
        (region.x.float32 + source.uvs[i].x * region.width.float32) /
          AtlasSize.float32,
        (region.y.float32 + source.uvs[i].y * region.height.float32) /
          AtlasSize.float32
      )
    if node.skin == nil:
      ids[0] = skin.jointIndex(node, mat4())
    else:
      weights = source.jointWeights[i]
      for component in 0 ..< 4:
        if weights[component] == 0:
          continue
        let index = source.jointIds[i][component].int
        if index >= node.skin.joints.len:
          raise newException(CharacterMeshError, "Skin joint index is invalid.")
        let inverseBind =
          if index < node.skin.inverseBindMatrices.len:
            node.skin.inverseBindMatrices[index]
          else:
            mat4()
        ids[component] = skin.jointIndex(node.skin.joints[index], inverseBind)
    merged.points.add point
    merged.normals.add source.normals[i]
    merged.tangents.add vec4(
      emission.x, emission.y, emission.z, material.doubleSided.ord.float32
    )
    let bytes = vertexColor.rgba
    merged.colors.add rgbx(bytes.r, bytes.g, bytes.b, bytes.a)
    merged.uvs.add uv
    merged.uvs1.add vec2(
      (unlit or material.unlit).ord.float32,
      (if material.alphaMode == MaskAlphaMode: material.alphaCutoff else: -1'f)
    )
    merged.jointIds.add ids
    merged.jointWeights.add weights
  if source.indices16.len > 0:
    for index in source.indices16:
      merged.indices32.add offset + index.uint32
  elif source.indices32.len > 0:
    for index in source.indices32:
      merged.indices32.add offset + index
  else:
    for i in 0 ..< source.points.len:
      merged.indices32.add offset + i.uint32

proc appendNodes(
  node: Node,
  opaque, blended: Primitive,
  skin: gltf.Skin,
  unlitParts: openArray[string],
  atlas: Image,
  regions: var Table[pointer, TextureRegion],
  x, y, rowHeight: var int
) =
  ## Combines visible meshes while retaining the original animated rig.
  if not node.visible:
    return
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      let destination =
        if primitive.material.alphaMode == BlendAlphaMode:
          blended
        else:
          opaque
      mergePrimitive(
        destination,
        skin, node, primitive, node.name in unlitParts,
        atlas, regions, x, y, rowHeight
      )
  for child in node.nodes:
    appendNodes(child, opaque, blended, skin, unlitParts, atlas,
      regions, x, y, rowHeight)

proc mergeCharacterMesh*(root: Node, unlitParts: openArray[string]): Node =
  ## Creates an immutable toon mesh for the visible outfit and expression.
  ## UV1 stores unlit/cutout settings, and tangents store emission/sidedness.
  root.ensureNormals()
  let
    atlas = newImage(AtlasSize, AtlasSize)
    material = Material(
      name: "Character atlas",
      baseColor: atlas,
      baseColorFactor: color(1, 1, 1, 1),
      baseColorSampler: defaultTextureSampler(),
      alphaMode: MaskAlphaMode,
      alphaCutoff: -1,
      doubleSided: true
    )
    primitive = Primitive(material: material, mode: TrianglesMode)
    blendMaterial = Material()
    blended = Primitive(material: blendMaterial, mode: TrianglesMode)
    skin = gltf.Skin()
  blendMaterial[] = material[]
  blendMaterial.alphaMode = BlendAlphaMode
  atlas.fill(rgbx(255, 255, 255, 255))
  var
    regions: Table[pointer, TextureRegion]
    x, y, rowHeight: int
  appendNodes(root, primitive, blended, skin, unlitParts, atlas,
    regions, x, y, rowHeight)
  var primitives: seq[Primitive]
  for buffer in [primitive, blended]:
    if buffer.points.len == 0:
      continue
    if buffer.points.len <= uint16.high.int + 1:
      for index in buffer.indices32:
        buffer.indices16.add index.uint16
      buffer.indices32.setLen(0)
    primitives.add buffer
  result = Node(
    name: "Merged character",
    mesh: Mesh(primitives: primitives),
    skin: skin,
    visible: true,
    baseVisible: true,
    rot: quat(), baseRot: quat(),
    scale: vec3(1), baseScale: vec3(1)
  )
