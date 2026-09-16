import
  std/math,
  pixie, vmath,
  polyworld/treegen

type
  Face = object
    vertices: array[3, TreeVertex]
    minimum, maximum: Vec3
    patch: int

proc faces(geometry: TreeGeometry): seq[Face] =
  ## Prepares independent triangle bounds for the intersection check.
  let mesh = geometry.foliage
  for i in countup(0, mesh.indices.high, 3):
    var face = Face(minimum: vec3(Inf.float32), maximum: vec3(-Inf.float32))
    face.patch = min(i div LeafIndices, geometry.cards)
    for j in 0 .. 2:
      face.vertices[j] = mesh.vertices[mesh.indices[i + j]]
      face.minimum = min(face.minimum, face.vertices[j].position)
      face.maximum = max(face.maximum, face.vertices[j].position)
    result.add face

proc segmentHit(start, finish: Vec3, face: Face, point: var Vec3): bool =
  ## Intersects a finite edge with a triangle using barycentric coordinates.
  let
    a = face.vertices[0].position
    edge = face.vertices[1].position - a
    side = face.vertices[2].position - a
    direction = finish - start
    perpendicular = cross(direction, side)
    determinant = dot(edge, perpendicular)
  if abs(determinant) < 0.00000001'f:
    return
  let
    relative = start - a
    u = dot(relative, perpendicular) / determinant
    across = cross(relative, edge)
    v = dot(direction, across) / determinant
    t = dot(side, across) / determinant
  if u < 0 or v < 0 or u + v > 1 or t < 0 or t > 1:
    return
  point = start + direction * t
  result = true

proc texturePoint(face: Face, point: Vec3): Vec2 =
  ## Finds the atlas coordinate of a point on a triangle's plane.
  let
    a = face.vertices[0]
    b = face.vertices[1]
    c = face.vertices[2]
    edge = b.position - a.position
    side = c.position - a.position
    relative = point - a.position
    aa = dot(edge, edge)
    ab = dot(edge, side)
    bb = dot(side, side)
    pa = dot(relative, edge)
    pb = dot(relative, side)
    determinant = aa * bb - ab * ab
    u = (bb * pa - ab * pb) / determinant
    v = (aa * pb - ab * pa) / determinant
  a.uv + (b.uv - a.uv) * u + (c.uv - a.uv) * v

proc opaque(atlas: Image, uv: Vec2): bool =
  ## Samples the supplied atlas at its alpha cutoff.
  let
    x = clamp((uv.x * atlas.width.float32).int, 0, atlas.width - 1)
    y = clamp((uv.y * atlas.height.float32).int, 0, atlas.height - 1)
  atlas.data[y * atlas.width + x].a >= 115

proc visibleCrossing(a, b: Face, atlas: Image): bool =
  ## Samples both textures along their triangles' 3D intersection segment.
  var points: seq[Vec3]
  for i in 0 .. 2:
    var point: Vec3
    if segmentHit(a.vertices[i].position,
      a.vertices[(i + 1) mod 3].position, b, point):
        points.add point
    if segmentHit(b.vertices[i].position,
      b.vertices[(i + 1) mod 3].position, a, point):
        points.add point
  if points.len < 2:
    return
  var
    distance = 0.0'f
    first, last: Vec3
  for i in 0 ..< points.len:
    for j in i + 1 ..< points.len:
      let separation = length(points[j] - points[i])
      if separation > distance:
        distance = separation
        first = points[i]
        last = points[j]
  if distance < 0.00001'f:
    return
  let
    uvA = a.texturePoint(first)
    uvB = b.texturePoint(first)
    endA = a.texturePoint(last)
    endB = b.texturePoint(last)
    steps = max(4, ceil(max(length(endA - uvA), length(endB - uvB)) *
      atlas.width.float32 * 2.0'f).int)
  for i in 0 .. steps:
    let t = i.float32 / steps.float32
    if atlas.opaque(mix(uvA, endA, t)) and atlas.opaque(mix(uvB, endB, t)):
      return true

proc crossings(geometry: TreeGeometry, atlas: Image): int =
  ## Counts visible intersections between distinct cards and the crown cap.
  let triangles = geometry.faces()
  for i, a in triangles:
    for j in i + 1 ..< triangles.len:
      let b = triangles[j]
      if a.patch == b.patch or
        a.maximum.x < b.minimum.x or a.minimum.x > b.maximum.x or
        a.maximum.y < b.minimum.y or a.minimum.y > b.maximum.y or
        a.maximum.z < b.minimum.z or a.minimum.z > b.maximum.z:
          continue
      if visibleCrossing(a, b, atlas):
        inc result

proc testCrossings*() =
  ## Verifies visible intersections disappear without thinning the presets.
  let atlas = loadMaterials(1).foliage.baseColor
  for index in 0 .. 5:
    for seed in [0, 42, 999]:
      var settings = preset(index, seed)
      let separated = generateGeometry(settings)
      settings.separateLeaves = false
      let
        original = generateGeometry(settings)
        before = original.crossings(atlas)
        after = separated.crossings(atlas)
      echo PresetNames[index], " seed ", seed, ": ", before, " -> ", after,
        " crossings; ", separated.cards, "/", original.cards, " cards"
      doAssert before > 0
      doAssert after == 0
      doAssert separated.cards * 10 >= original.cards * 7
      doAssert separated.cards + separated.omittedCards == original.cards
      doAssert separated.bark == original.bark
  for index in [0, 3]:
    var settings = preset(index, 2718)
    settings.shells = 2
    settings.irregularity = 0.65'f
    settings.leafJitter = 0.6'f
    settings.leafWidth = 2.0'f
    settings.droop = 1.5'f
    settings.curl = 0.8'f
    let geometry = generateGeometry(settings)
    doAssert geometry.cards > 0
    doAssert geometry.crossings(atlas) == 0
