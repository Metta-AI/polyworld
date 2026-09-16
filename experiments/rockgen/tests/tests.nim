import
  std/[math, os, tables],
  gltf, vmath,
  ../[rocks, views]

proc welded(points: var seq[Vec3], point: Vec3): int =
  ## Identifies coincident vertices across normal and UV seams.
  for i, existing in points:
    if lengthSq(existing - point) < 0.000000001'f:
      return i
  result = points.len
  points.add point

proc checkGeometry(geometry: RockGeometry, context = "") =
  ## Checks closed topology, coplanarity, coverage, UV regions, and winding.
  let mesh = geometry.mesh
  doAssert mesh.indices.len mod 3 == 0
  doAssert geometry.faces.len >= 6
  var
    points: seq[Vec3]
    edges = initTable[(int, int), tuple[count, direction: int]]()
    patches = 0
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
        indices[j] = points.welded(triangle[j].position)
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
      doAssert details == 2
      let
        a = face.patch[1] - face.patch[0]
        b = face.patch[2] - face.patch[1]
      doAssert abs(length(a) - length(b)) < 0.00001'f
      doAssert abs(dot(normalize(a), normalize(b))) < 0.0001'f
    else:
      doAssert details == 0
  doAssert patches == geometry.details
  for edge in edges.values:
    doAssert edge.count == 2,
      context & " has a gap, overlap, or T junction"
    doAssert edge.direction == 0, "Neighboring triangles disagree on winding"

proc testRecipes() =
  ## Exercises deterministic presets and varied topology over many seeds.
  for index in 0 .. PresetNames.high:
    for seed in 0 ..< 40:
      let
        settings = preset(index, seed)
        geometry = generate(settings)
      geometry.checkGeometry("Preset " & $index & ", seed " & $seed)
      doAssert geometry == generate(settings)
      doAssert length(geometry.maximum - geometry.minimum -
        vec3(settings.width, settings.height, settings.depth)) < 0.0001'f
      doAssert abs(geometry.minimum.y) < 0.00001'f
    doAssert generate(preset(index, 42)) != generate(preset(index, 43))

proc testControls() =
  ## Checks parameter limits, disabled regions, and independent tinting.
  var settings = preset(0)
  let original = generate(settings)
  settings.tint = vec3(1, 0, 0)
  doAssert generate(settings) == original
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
          let geometry = generate(settings)
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
    for face in generate(settings).faces:
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
        generate(settings).checkGeometry("Dimensions " & $dimensions &
          "/" & $taper & "/" & $crown)
  for bad in [NaN.float32, Inf.float32, -1.0'f, 11.0'f]:
    settings = preset(0)
    settings.height = bad
    var rejected = false
    try:
      discard generate(settings)
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
      let geometry = generate(settings)
      geometry.checkGeometry("Cuts " & $seed & "/" & $amount)
      for vertex in geometry.mesh.vertices:
        doAssert vertex.shade >= 0 and vertex.shade <= 1
        if amount == 0:
          doAssert vertex.region != Edge
  var settings = preset(0)
  settings.mottling = 0
  let plain = generate(settings)
  settings.mottling = 0.4
  let painted = generate(settings)
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
    geometry = generate(settings)
    node = rockNode(geometry, materials)
  materials.tint(settings)
  doAssert node.mesh.primitives.len == 1
  doAssert node.mesh.primitives[0].points.len == geometry.mesh.vertices.len
  doAssert materials.stone.baseColor.width == 1254
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
        doAssert primitive.material.baseColor.width == 1254
        doAssert primitive.material.baseColorSampler.minFilter ==
          LinearMinFilter
  doAssert triangleCount == geometry.mesh.indices.len div 3
  removeFile(recipe)
  removeFile(model)
  removeDir(directory)

echo "Checking rock presets and closed face triangulation"
testRecipes()
echo "Checking controls and texture region boundaries"
testControls()
echo "Checking corner cuts and surface wash"
testCuts()
echo "Checking recipe and GLB files"
testFiles()
echo "Rockgen tests passed"
