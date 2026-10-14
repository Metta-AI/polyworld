## The authored ship skin, with atlas UV transforms baked for toon rendering.

import
  std/math,
  chroma, flatty/binny, gltf, jsony, vmath,
  polyworld/common,
  sim

const
  ShipModelPath* = DataRoot & "/crewrift/crewRift-map1-textured.glb"
  ShipModelScale* = 12.5'f

type
  ShipPlacement = object
    name: string
    matrix: seq[float32]
    children: seq[int]
  ShipScene = object
    nodes: seq[int]
  ShipDocument = object
    nodes: seq[ShipPlacement]
    scenes: seq[ShipScene]
    scene: int

proc restoreShipMatrices(file: GltfFile, path: string) =
  ## Keeps authored mirror transforms exact while baking the static ship.
  var document: ShipDocument
  try:
    let bytes = readFile(path)
    if bytes.len < 20:
      raise newException(CrewriftError, "Ship GLB header is incomplete.")
    let length = bytes.readUint32(12).int
    if length < 2 or length > bytes.len - 20 or
      bytes.readUint32(16) != 0x4E4F534A'u32:
        raise newException(CrewriftError, "Ship GLB JSON chunk is invalid.")
    document = bytes[20 ..< 20 + length].fromJson(ShipDocument)
  except JsonError, IOError:
    raise newException(
      CrewriftError,
      "Cannot read ship placements: " & getCurrentExceptionMsg()
    )
  if document.scene < 0 or document.scene >= document.scenes.len:
    raise newException(CrewriftError, "Ship scene index is invalid.")
  let indices = document.scenes[document.scene].nodes
  if indices.len != file.root.nodes.len:
    raise newException(CrewriftError, "Ship scene placements do not match.")
  for i, index in indices:
    if index < 0 or index >= document.nodes.len:
      raise newException(CrewriftError, "Ship placement index is invalid.")
    let
      placement = document.nodes[index]
      node = file.root.nodes[i]
    if placement.name != node.name or placement.matrix.len != 16 or
      placement.children.len != 0:
        raise newException(
          CrewriftError,
          "Ship requires flat matrix placements: " & placement.name
        )
    for column in 0 ..< 4:
      for row in 0 ..< 4:
        node.mat[column, row] = placement.matrix[column * 4 + row]

proc combineShipSkin*(root: Node): Node =
  ## Bakes positions, normals, UVs, and mirrored face winding into one batch.
  let combined = Primitive(mode: TrianglesMode)
  for node in root.walkNodes():
    if not node.visible or node.mesh == nil:
      continue
    let mirrored = node.mat.determinant() < 0
    for primitive in node.mesh.primitives:
      if primitive.mode != TrianglesMode:
        raise newException(CrewriftError, "Ship geometry must use triangles.")
      if combined.material == nil:
        combined.material = primitive.material
      elif primitive.material.baseColor != combined.material.baseColor:
        raise newException(CrewriftError, "Ship model needs one texture atlas.")
      let
        offset = combined.points.len.uint32
        transform = primitive.material.baseColorTransform
        cosine = cos(transform.rotation)
        sine = sin(transform.rotation)
        normal = node.mat.normalMatrix()
      for i, point in primitive.points:
        combined.points.add (node.mat * point).xyz * ShipModelScale
        combined.normals.add normalize(normal * primitive.normals[i])
        let uv = primitive.uvs[i] * transform.scale
        combined.uvs.add transform.offset + vec2(
          cosine * uv.x - sine * uv.y,
          sine * uv.x + cosine * uv.y
        )
        combined.colors.add rgbx(255, 255, 255, 255)
      let
        first = combined.indices32.len
        count =
          if primitive.indices16.len > 0:
            primitive.indices16.len
          elif primitive.indices32.len > 0:
            primitive.indices32.len
          else:
            primitive.points.len
      if count mod 3 != 0:
        raise newException(CrewriftError, "Ship triangle indices are invalid.")
      for i in 0 ..< count:
        let index =
          if primitive.indices16.len > 0:
            primitive.indices16[i].uint32
          elif primitive.indices32.len > 0:
            primitive.indices32[i]
          else:
            i.uint32
        combined.indices32.add offset + index
      if mirrored:
        for i in countup(first, combined.indices32.high, 3):
          swap(combined.indices32[i + 1], combined.indices32[i + 2])
  if combined.material == nil:
    raise newException(CrewriftError, "Ship model has no visible geometry.")
  combined.material.baseColorTransform = TextureTransform(scale: vec2(1))
  result = Node(
    name: "Crewrift map 1", visible: true,
    rot: quat(0, 0, 0, 1), scale: vec3(1),
    mesh: Mesh(primitives: @[combined])
  )

proc loadShipSkin*(path = ShipModelPath): Node =
  ## Loads the exact authored placements into one static atlas batch.
  var file: GltfFile
  try:
    file = readGltfFile(path)
  except GltfError, IOError:
    raise newException(
      CrewriftError,
      "Cannot load ship model: " & getCurrentExceptionMsg()
    )
  file.root.updateTransforms()
  file.restoreShipMatrices(path)
  combineShipSkin(file.root)
