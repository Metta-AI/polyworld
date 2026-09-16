import
  std/[math, os, tables],
  gltf, vmath,
  polyworld/rockgen,
  ../views

proc welded(
  points, localPoints: var seq[Vec3],
  localIndices: var seq[int],
  point: Vec3
): int =
  ## Welds face seams while keeping nearby cut vertices distinct per face.
  for i, existing in localPoints:
    if lengthSq(existing - point) < 0.000000000001'f:
      return localIndices[i]
  result = -1
  var nearest = 0.000000001'f
  for i, existing in points:
    let distance = lengthSq(existing - point)
    if i notin localIndices and distance < nearest:
      result = i
      nearest = distance
  if result < 0:
    result = points.len
    points.add point
  localPoints.add point
  localIndices.add result

proc checkGeometry(
  geometry: RockGeometry,
  context = "",
  openBase = false,
  clippedDetails = false
) =
  ## Checks topology, coplanarity, UVs, and an optional open floor boundary.
  let mesh = geometry.mesh
  doAssert mesh.indices.len mod 3 == 0
  doAssert geometry.faces.len >= (if openBase: 3 else: 6)
  var
    points: seq[Vec3]
    edges = initTable[(int, int), tuple[count, direction: int]]()
    patches = 0
    boundary = 0
  for vertex in mesh.vertices:
    for i in 0 ..< 3:
      doAssert classify(vertex.position[i]) notin {fcNan, fcInf, fcNegInf}
    doAssert abs(length(vertex.normal) - 1) < 0.0001'f
    doAssert vertex.uv.x >= 0 and vertex.uv.x <= 1
    doAssert vertex.uv.y >= 0 and vertex.uv.y <= 1
    case vertex.region
    of Edge:
      doAssert vertex.tile in 0 .. 3
      doAssert vertex.uv.y >= TrimTop - 0.000001'f
      doAssert vertex.uv.y <= TrimBottom + 0.000001'f
      doAssert vertex.uv.x > vertex.tile.float32 * 0.25'f
      doAssert vertex.uv.x < (vertex.tile + 1).float32 * 0.25'f
    of Fill:
      doAssert vertex.tile == 4
      doAssert vertex.uv == FillUv
    of Detail:
      doAssert vertex.tile in 5 .. 15
      doAssert floor(vertex.uv.x * 4).int == vertex.tile mod 4
      doAssert floor(vertex.uv.y * 4).int == vertex.tile div 4
  for face in geometry.faces:
    var
      expected, actual: float32
      details = 0
      localPoints: seq[Vec3]
      localIndices: seq[int]
    for i in 1 ..< face.points.high:
      expected += dot(cross(face.points[i] - face.points[0],
        face.points[i + 1] - face.points[0]), face.normal) * 0.5'f
    for i in countup(face.firstIndex, face.firstIndex + face.indexCount - 1, 3):
      var
        triangle: array[3, RockVertex]
        indices: array[3, int]
      for j in 0 ..< 3:
        doAssert mesh.indices[i + j].int < mesh.vertices.len
        triangle[j] = mesh.vertices[mesh.indices[i + j]]
        indices[j] = points.welded(
          localPoints, localIndices, triangle[j].position
        )
        doAssert abs(dot(triangle[j].position - face.points[0],
          face.normal)) < 0.00001'f
        doAssert triangle[j].normal == face.normal
      let signedArea = dot(cross(
        triangle[1].position - triangle[0].position,
        triangle[2].position - triangle[0].position
      ), face.normal) * 0.5'f
      doAssert signedArea > 0, "Collapsed or reversed triangle"
      actual += signedArea
      if triangle[0].region == Detail:
        inc details
      for j in 0 ..< 3:
        let
          a = indices[j]
          b = indices[(j + 1) mod 3]
          key = (min(a, b), max(a, b))
        doAssert a != b, context & " collapsed edge: " &
          $length(triangle[j].position - triangle[(j + 1) mod 3].position) &
          ", region " & $triangle[j].region & ", face " & $face.points
        var edge = edges.getOrDefault(key)
        inc edge.count
        edge.direction += (if a < b: 1 else: -1)
        edges[key] = edge
    doAssert abs(actual - expected) < max(0.00001'f, expected * 0.0001'f)
    if face.detailTile >= 0:
      inc patches
      if clippedDetails:
        doAssert details in 1 .. 4
      else:
        doAssert details == 2
      let
        a = face.patch[1] - face.patch[0]
        b = face.patch[2] - face.patch[1]
      doAssert abs(length(a) - length(b)) < 0.00001'f
      doAssert abs(dot(normalize(a), normalize(b))) < 0.0001'f
    else:
      doAssert details == 0
  doAssert patches == geometry.details
  for key, edge in edges:
    if openBase and edge.count == 1:
      doAssert abs(points[key[0]].y) < 0.00001'f
      doAssert abs(points[key[1]].y) < 0.00001'f
      inc boundary
      continue
    doAssert edge.count == 2,
      context & " has a gap, overlap, or T junction"
    doAssert edge.direction == 0, "Neighboring triangles disagree on winding"
  doAssert (boundary > 0) == openBase

proc testRecipes() =
  ## Exercises deterministic presets and varied topology over many seeds.
  for index in 0 .. PresetNames.high:
    for seed in 0 ..< 40:
      let
        settings = preset(index, seed)
        geometry = generateGeometry(settings)
      geometry.checkGeometry("Preset " & $index & ", seed " & $seed)
      doAssert geometry == generateGeometry(settings)
      doAssert length(geometry.maximum - geometry.minimum -
        vec3(settings.width, settings.height, settings.depth)) < 0.0001'f
      doAssert abs(geometry.minimum.y) < 0.00001'f
    doAssert generateGeometry(preset(index, 42)) !=
      generateGeometry(preset(index, 43))

proc testControls() =
  ## Checks parameter limits, disabled regions, and independent tinting.
  var settings = preset(0)
  let original = generateGeometry(settings)
  settings.tint = vec3(1, 0, 0)
  doAssert generateGeometry(settings) == original
  for seed in [0, 42, 999, 1_000_000_000]:
    for sides in [4, 12]:
      for trim in [0.0'f, 0.4'f]:
        for detail in [0.0'f, 1.0'f]:
          settings = preset(0, seed)
          settings.sides = sides
          settings.crownCuts = 12
          settings.irregularity = 0.4
          settings.trimWidth = trim
          settings.detailChance = detail
          settings.detailSize = 0.9
          settings.detailOffset = 0.6
          let geometry = generateGeometry(settings)
          geometry.checkGeometry("Controls " & $seed & "/" & $sides &
            "/" & $trim & "/" & $detail)
          if detail == 0:
            doAssert geometry.details == 0
          if trim == 0:
            for vertex in geometry.mesh.vertices:
              doAssert vertex.region != Edge
  for kind in [Cracks, Scuffs]:
    settings = preset(0)
    settings.detailKind = kind
    settings.detailChance = 1
    for face in generateGeometry(settings).faces:
      if face.detailTile >= 0:
        if kind == Cracks:
          doAssert face.detailTile in 5 .. 10
        else:
          doAssert face.detailTile in 11 .. 15
  for dimensions in [vec3(0.5, 10, 0.5), vec3(8, 0.5, 8)]:
    for taper in [-0.3'f, 0.45'f]:
      for crown in [0.4'f, 1.6'f]:
        settings = preset(0)
        settings.width = dimensions.x
        settings.height = dimensions.y
        settings.depth = dimensions.z
        settings.taper = taper
        settings.crown = crown
        settings.lean = -0.5
        settings.detailChance = 1
        generateGeometry(settings).checkGeometry("Dimensions " & $dimensions &
          "/" & $taper & "/" & $crown)
  for bad in [NaN.float32, Inf.float32, -1.0'f, 11.0'f]:
    settings = preset(0)
    settings.height = bad
    var rejected = false
    try:
      discard generateGeometry(settings)
    except RockgenError:
      rejected = true
    doAssert rejected

proc testCuts() =
  ## Exercises block cuts, tiny chips, and surface controls at their limits.
  for seed in 0 ..< 20:
    for amount in [0.0'f, 1.0'f]:
      var settings = preset(seed mod PresetNames.len, seed)
      settings.chips = (amount * 12).int
      settings.chipSize = amount * 0.25'f
      settings.cornerClip = amount * 0.45'f
      settings.shoulder = amount * 0.85'f
      settings.trimChance = amount
      settings.mottling = amount * 0.4'f
      settings.detailChance = 1
      let geometry = generateGeometry(settings)
      geometry.checkGeometry("Cuts " & $seed & "/" & $amount)
      for vertex in geometry.mesh.vertices:
        doAssert vertex.shade >= 0 and vertex.shade <= 1
        if amount == 0:
          doAssert vertex.region != Edge
  var settings = preset(0)
  settings.mottling = 0
  let plain = generateGeometry(settings)
  settings.mottling = 0.4
  let painted = generateGeometry(settings)
  doAssert plain.mesh.indices == painted.mesh.indices
  doAssert plain.mesh.vertices.len == painted.mesh.vertices.len
  var changed = false
  for i, vertex in painted.mesh.vertices:
    doAssert vertex.position == plain.mesh.vertices[i].position
    doAssert vertex.normal == plain.mesh.vertices[i].normal
    doAssert vertex.uv == plain.mesh.vertices[i].uv
    if vertex.shade != plain.mesh.vertices[i].shade:
      changed = true
  doAssert changed

proc testFiles() =
  ## Round-trips recipes and checks portable atlas-backed GLB exports.
  let
    directory = getTempDir() / "polyworld-rockgen-tests"
    recipe = directory / "recipe.json"
    model = directory / "rock.glb"
    settings = preset(1, 73)
  createDir(directory)
  settings.saveSettings(recipe)
  doAssert loadSettings(recipe) == settings
  var detailed = settings
  detailed.fillSubdivisions = 2
  detailed.removeBottom = true
  detailed.floorCut = 0.5
  detailed.saveSettings(recipe)
  doAssert loadSettings(recipe) == detailed
  writeFile(recipe, "{\"seed\":19}")
  doAssert loadSettings(recipe) == preset(0, 19)
  writeFile(recipe, "{broken")
  var rejected = false
  try:
    discard loadSettings(recipe)
  except RockgenError:
    rejected = true
  doAssert rejected
  let
    materials = loadMaterials()
    geometry = generateGeometry(settings)
    node = rockNode(geometry, materials)
  materials.tint(settings)
  doAssert node.mesh.primitives.len == 1
  doAssert node.mesh.primitives[0].points.len == geometry.mesh.vertices.len
  doAssert materials.stone.baseColor.width == 512
  doAssert materials.stone.baseColorSampler.minFilter == LinearMinFilter
  settings.exportRock(model)
  let data = readFile(model)
  doAssert data[0 .. 3] == "glTF"
  doAssert data.len > 100_000
  let imported = loadModel(model)
  var
    nodes = @[imported]
    triangleCount = 0
  while nodes.len > 0:
    let current = nodes.pop()
    nodes.add current.nodes
    if current.mesh != nil:
      for primitive in current.mesh.primitives:
        triangleCount += (primitive.indices32.len +
          primitive.indices16.len) div 3
        doAssert primitive.material.baseColor.width == 512
        doAssert primitive.material.baseColorSampler.minFilter ==
          LinearMinFilter
  doAssert triangleCount == geometry.mesh.indices.len div 3
  detailed.exportRock(model)
  nodes = @[loadModel(model)]
  triangleCount = 0
  while nodes.len > 0:
    let current = nodes.pop()
    nodes.add current.nodes
    if current.mesh != nil:
      for primitive in current.mesh.primitives:
        triangleCount += (primitive.indices32.len +
          primitive.indices16.len) div 3
        for point in primitive.points:
          doAssert point.y >= 0
          doAssert point.y <= detailed.height * 0.5'f + 0.00001'f
  doAssert triangleCount == generateGeometry(detailed).mesh.indices.len div 3
  removeFile(recipe)
  removeFile(model)
  removeDir(directory)

proc testFloor() =
  ## Checks an open base, partial burial, texture stability, and cut limits.
  for index in 0 .. PresetNames.high:
    for seed in [0, 42, 999]:
      var settings = preset(index, seed)
      let closed = generateGeometry(settings)
      settings.removeBottom = true
      let opened = generateGeometry(settings)
      opened.checkGeometry("Open bottom " & $index & "/" & $seed, true)
      doAssert opened.minimum == closed.minimum
      doAssert opened.maximum == closed.maximum
      doAssert opened.mesh.indices.len < closed.mesh.indices.len
      var expected: seq[RockVertex]
      for face in closed.faces:
        var ground = true
        for point in face.points:
          ground = ground and abs(point.y) < 0.00001'f
        if not ground:
          for i in face.firstIndex ..< face.firstIndex + face.indexCount:
            expected.add closed.mesh.vertices[closed.mesh.indices[i]]
      doAssert opened.mesh.vertices == expected
      for subdivisions in [0, 2]:
        settings.fillSubdivisions = subdivisions
        for cut in [0.1'f, 0.5'f, 0.9'f]:
          settings.floorCut = cut
          settings.removeBottom = false
          let buried = generateGeometry(settings)
          buried.checkGeometry(
            "Floor " & $index & "/" & $seed & "/" & $cut,
            openBase = true,
            clippedDetails = true
          )
          doAssert abs(buried.minimum.y) < 0.00001'f
          doAssert abs(buried.maximum.y - settings.height * (1 - cut)) <
            0.00001'f
          for vertex in buried.mesh.vertices:
            doAssert vertex.position.y >= 0
          settings.removeBottom = true
          doAssert generateGeometry(settings) == buried
  for invalid in [NaN.float32, -0.1'f, 1.0'f]:
    var settings = preset(0)
    settings.floorCut = invalid
    var rejected = false
    try:
      discard generateGeometry(settings)
    except RockgenError:
      rejected = true
    doAssert rejected

proc textureVertices(geometry: RockGeometry): seq[RockVertex] =
  ## Collects trim and detail data independently of the fill triangulation.
  for vertex in geometry.mesh.vertices:
    if vertex.region != Fill:
      result.add vertex

proc testFill() =
  ## Checks the triangle budget and preserves shape across fill densities.
  for index in 0 .. PresetNames.high:
    var settings = preset(index)
    let sparse = generateGeometry(settings)
    doAssert sparse.mesh.indices.len div 3 < 500
    settings.trimChance = 0
    settings.detailChance = 0
    let plain = generateGeometry(settings)
    plain.checkGeometry("Plain fill " & $index)
    for face in plain.faces:
      doAssert face.indexCount == (face.points.len - 2) * 3
    for seed in 0 ..< 10:
      settings = preset(index, seed)
      let simple = generateGeometry(settings)
      for subdivisions in 1 .. 2:
        settings.fillSubdivisions = subdivisions
        let dense = generateGeometry(settings)
        dense.checkGeometry("Fill density " & $index & "/" & $seed &
          "/" & $subdivisions)
        doAssert dense.faces.len == simple.faces.len
        doAssert dense.minimum == simple.minimum
        doAssert dense.maximum == simple.maximum
        doAssert dense.textureVertices() == simple.textureVertices()
        doAssert dense.mesh.indices.len > simple.mesh.indices.len
        for i, face in dense.faces:
          doAssert face.points == simple.faces[i].points
          doAssert face.normal == simple.faces[i].normal
          doAssert face.patch == simple.faces[i].patch
        settings.mottling = 0
        let unpainted = generateGeometry(settings)
        settings.fillSubdivisions = 0
        doAssert unpainted == generateGeometry(settings)
        settings.mottling = preset(index).mottling
  for invalid in [-1, 3]:
    var settings = preset(0)
    settings.fillSubdivisions = invalid
    var rejected = false
    try:
      discard generateGeometry(settings)
    except RockgenError:
      rejected = true
    doAssert rejected

echo "Checking rock presets and closed face triangulation"
testRecipes()
echo "Checking controls and texture region boundaries"
testControls()
echo "Checking corner cuts and surface wash"
testCuts()
echo "Checking minimal fill and optional subdivisions"
testFill()
echo "Checking bottom removal and floor cuts"
testFloor()
echo "Checking recipe and GLB files"
testFiles()
echo "Rockgen tests passed"
