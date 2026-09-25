import
  std/[math, os],
  chroma, gltf, pixie, vmath,
  polyworld/[common, groves, pathing, quadterrain, treegen],
  content, maps, layouts

const
  VillageRoot* = DataRoot & "/terrain/blender_village/models/"
  VillageModels* = [
    "hobbit_house", "well", "hobbit_barrel_planter", "hobbit_box_planter",
    "hobbit_chimney"
  ]
  DetailsPath* = DataRoot & "/terrain/heartleaf/models/village_details.glb"
  GardenCropLift* = 0.5'f * HouseScale

type
  RoofTriangle* = array[3, Vec3]
  VillageArt* = object
    props*: array[VillageModels.len, PropPack]
    names*: array[VillageModels.len, string]
    placeholders*: PropPack
    grove*: Grove
    houses*, trees*, details*: PropPack
    roof*: seq[RoofTriangle]

proc placeholderNode*(): Node =
  ## Builds a unit box for missing props and unmodeled vegetables.
  const
    Points = [
      vec3(-0.5, 0, -0.5), vec3(0.5, 0, -0.5),
      vec3(0.5, 1, -0.5), vec3(-0.5, 1, -0.5),
      vec3(-0.5, 0, 0.5), vec3(0.5, 0, 0.5),
      vec3(0.5, 1, 0.5), vec3(-0.5, 1, 0.5)
    ]
    Faces = [
      [0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3],
      [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]
    ]
  let primitive = Primitive(
    mode: TrianglesMode,
    material: Material(baseColorFactor: color(1, 1, 1, 1))
  )
  for face in Faces:
    let normal = normalize(cross(
      Points[face[1]] - Points[face[0]],
      Points[face[2]] - Points[face[0]]
    ))
    for corner in [0, 1, 2, 0, 2, 3]:
      primitive.indices32.add primitive.points.len.uint32
      primitive.points.add Points[face[corner]]
      primitive.normals.add normal
  Node(
    name: "placeholder", visible: true, scale: vec3(1),
    rot: quat(0, 0, 0, 1), mesh: Mesh(primitives: @[primitive])
  )

proc tintedMaterial(source: Material, tint: Vec3): Material =
  ## Shares image pixels while keeping each prop's material tint separate.
  new(result)
  result[] = source[]
  result.baseColorFactor = color(tint.x, tint.y, tint.z, 1)

proc houseNodes*(): seq[Node] =
  ## Reuses the reviewed cottage mesh with nine independently stained doors.
  const DoorColors = [
    vec3(0.24, 0.53, 0.17), vec3(0.84, 0.54, 0.20),
    vec3(0.47, 0.26, 0.08), vec3(0.16, 0.35, 0.77),
    vec3(0.92, 0.65, 0.27), vec3(0.46, 0.19, 0.70),
    vec3(0.85, 0.57, 0.24), vec3(0.24, 0.49, 0.43),
    vec3(0.12, 0.44, 0.44)
  ]
  if not fileExists(VillageRoot & "hobbit_house.glb"):
    for i in 0 ..< VillagerCount:
      let node = placeholderNode()
      node.name = "home" & $i
      node.scale = vec3(10, 4, 7) * HouseScale
      result.add node
    return
  let
    file = readGltfFile(VillageRoot & "hobbit_house.glb")
    grass = readImage(DataRoot & "/terrain/tiles/heartleaf-grass-2.rgb.png")
  for source in file.root.walkNodes:
    if source.mesh == nil:
      continue
    for i, tint in DoorColors:
      let node = Node(
        name: "home" & $i, visible: true,
        pos: HouseMeshOffset, scale: vec3(HouseMeshScale),
        rot: quat(0, 0, 0, 1), mesh: Mesh()
      )
      doAssert source.mesh.primitives.len == 3
      for materialIndex, sourcePrimitive in source.mesh.primitives:
        let primitive = Primitive()
        primitive[] = sourcePrimitive[]
        primitive.material = tintedMaterial(sourcePrimitive.material, vec3(1))
        if materialIndex == 1:
          primitive.material = tintedMaterial(primitive.material, tint)
        elif materialIndex == 2:
          primitive.material.baseColor = grass
        node.mesh.primitives.add primitive
      result.add node

proc houseRoof*(node: Node): seq[RoofTriangle] =
  ## Extracts the transformed grass shell for precise decoration placement.
  if node.mesh.primitives.len < 3:
    return
  let
    shell = Node(mesh: Mesh(primitives: @[node.mesh.primitives[2]]))
    transform = node.trs
  for (a, b, c) in shell.triangles:
    result.add [transform * a, transform * b, transform * c]

proc roofHeight*(roof: openArray[RoofTriangle], x, z: float32): float32 =
  ## Samples the upper grass surface directly from its exported triangles.
  result = 0
  for triangle in roof:
    let
      a = triangle[0]
      b = triangle[1]
      c = triangle[2]
      divisor = (b.z - c.z) * (a.x - c.x) +
        (c.x - b.x) * (a.z - c.z)
    if abs(divisor) < 0.000001'f:
      continue
    let
      first = ((b.z - c.z) * (x - c.x) +
        (c.x - b.x) * (z - c.z)) / divisor
      second = ((c.z - a.z) * (x - c.x) +
        (a.x - c.x) * (z - c.z)) / divisor
      third = 1 - first - second
    if first >= -0.0001'f and second >= -0.0001'f and third >= -0.0001'f:
      result = max(result, first * a.y + second * b.y + third * c.y)

proc broadleafNodes(seed: int32): seq[Node] =
  ## Builds a small cached bank of round spring crowns and low shrubs.
  let materials = treegen.loadMaterials(1)
  for i in 0 ..< 13:
    var settings = treegen.preset(0, seed.int + i * 997)
    settings.crownRadius = 3.0'f + (i mod 3).float32 * 0.22'f
    settings.crownHeight = 3.0'f
    settings.crownShape = 0.35'f
    settings.crownBase = 3.0'f
    settings.height = 5.8'f
    settings.branches = 7
    settings.forks = 0
    settings.rings = 7
    settings.cardsPerRing = 12
    settings.density = 1.15'f
    settings.packing = 1.05'f
    settings.crownCoverage = 0.9'f
    settings.leafSize = 1.7'f
    settings.leafWidth = 1.4'f
    settings.leafTile = MixedLeaves
    settings.colorVariation = 0.14'f
    settings.leafColor = [
      vec3(0.49, 0.69, 0.12), vec3(0.58, 0.75, 0.18),
      vec3(0.39, 0.60, 0.13)
    ][i mod 3]
    if i >= 7:
      settings.crownRadius = 2.4'f + (i mod 4).float32 * 0.35'f
      settings.crownHeight = 2.5'f + (i mod 3).float32 * 0.55'f
      settings.crownBase = 2.2'f + (i mod 4).float32 * 0.35'f
      settings.crownShape = 0.3'f + (i mod 3).float32 * 0.2'f
      settings.height = settings.crownBase + settings.crownHeight
      settings.branches = 4 + i mod 5
      settings.trunkRadius = 0.22'f + (i mod 3).float32 * 0.07'f
    if i in 3 .. 5:
      settings.height = 1.35'f
      settings.crownBase = 0.3'f
      settings.crownHeight = 1.4'f
      settings.crownRadius = 1.25'f
      settings.trunkRadius = 0.12'f
      settings.roots = 0
      settings.branches = 0
      settings.leafSize = 0.65'f
    if i == 6:
      settings.crownBase = 4.2'f
      settings.crownHeight = 3.6'f
      settings.crownRadius = 3.4'f
      settings.crownCoverage = 1
      settings.shells = 3
      settings.density = 1.4'f
      settings.leafSize = 1.3'f
      settings.cardsPerRing = 16
      settings.trunkRadius = 0.6'f
      settings.rootSpread = 1.7'f
    let node = treegen.treeNode(
      treegen.generateGeometry(settings),
      TreeMaterials(
        bark: tintedMaterial(materials.bark, vec3(0.55, 0.31, 0.12)),
        foliage: tintedMaterial(materials.foliage, settings.leafColor),
        cut: materials.cut
      )
    )
    node.name = "leaf" & $i
    result.add node

proc loadVillageArt*(seed: int32): VillageArt =
  ## Loads only reviewed CC0 props and caches generated foliage once.
  result.placeholders = createPropPack([placeholderNode()])
  result.grove = generateGrove(seed.int, {LightRock})
  result.trees = createPropPack(broadleafNodes(seed), repeatTexture = true)
  let houses = houseNodes()
  result.houses = createPropPack(houses, repeatTexture = true)
  result.roof = houseRoof(houses[0])
  if fileExists(DetailsPath):
    result.details = loadPropPack(
      DetailsPath,
      unitHeight = false,
      textured = true,
      materialColors = true,
      textureSize = 512
    )
  else:
    result.details = result.placeholders
  for i, name in VillageModels:
    let path = VillageRoot & name & ".glb"
    if fileExists(path):
      result.props[i] = loadPropPack(
        path,
        textured = true,
        materialColors = true,
        mergeNodes = true,
        repeatTexture = true,
        textureSize = 512
      )
      result.names[i] = name
    else:
      result.props[i] = result.placeholders
      result.names[i] = "placeholder"

proc villagePoint*(tile: Tile2): Vec3 =
  ## Places art at a simulation tile's ground center.
  let
    x = tile.x.float32 - HalfGrid + 0.5'f
    z = tile.y.float32 - HalfGrid + 0.5'f
  vec3(x, surfaceHeight(x, z), z)

proc placeVillage*(art: VillageArt, map: MapData, seed: int32) =
  ## Assembles the reference's nine cottages, tree square and garden lanes.
  clearProps()

  proc point(x, z: float32): Vec3 =
    ## Samples the terrain under a decorative village location.
    vec3(x + 0.5'f, surfaceHeight(x + 0.5'f, z + 0.5'f), z + 0.5'f)

  proc detail(name: string, x, z: float32, yaw = 0'f, size = 1'f) =
    ## Queues one of the reusable painted village details.
    if art.details.hasProp(name):
      art.details.placeProp(name, point(x, z), yaw, size)
    else:
      art.placeholders.placeProp("placeholder", point(x, z), yaw, size)

  proc flowers(x, z: float32, variant: int, size = 1'f) =
    ## Mixes daisies, cornflowers, purple blooms and golden flowers.
    const Names = [
      "flowers_white", "flowers_white", "flowers_blue",
      "flowers_white", "flowers_purple", "flowers_gold"
    ]
    detail(Names[abs(variant) mod Names.len], x, z, variant.float32, size)

  for plant in groundPlants(seed):
    art.trees.placeProp(
      "leaf" & $plant.variant,
      point(plant.x.float32 / 1000, plant.z.float32 / 1000),
      plant.yaw, plant.size, vec3(1, plant.height, 1)
    )
  for i, fence in GardenFences:
    let
      x = fence.x.float32 / 1000
      z = fence.z.float32 / 1000
    detail("fence", x, z, fence.yaw, fence.size)
    flowers(x * 0.98'f, z, i, 1.1'f)

  art.props[1].placeProp(art.names[1], point(TownWell.x, TownWell.y),
    scale = 4.5'f)
  for i in 0 ..< 12:
    let angle = i.float32 * 2'f * PI.float32 / 12'f
    flowers(TownWell.x + cos(angle) * 2.2'f,
      TownWell.y + sin(angle) * 2.2'f, i, 0.85'f)

  detail("tree_curb", 0, 0, size = TownLayoutScale)
  detail("plaza_paving", 0, 0, size = TownLayoutScale)
  for i in 0 ..< 4:
    let angle = 0.25'f + i.float32 * 0.88'f
    # The seat fronts point along local +Z, away from the trunk.
    detail("bench", cos(angle) * 3.7'f, sin(angle) * 3.7'f,
      angle - PI.float32 / 2, 1.2'f)
  for i in 0 ..< 14:
    let angle = i.float32 * 2'f * PI.float32 / 14'f
    flowers(cos(angle) * 2.0'f, sin(angle) * 2.0'f, i, 0.8'f)
  detail("market", -5.5, -4, 0.15'f, 1.1'f)
  detail("lantern", -6.4'f, -5.2'f)
  detail("lantern", 6.8'f, 2)
  detail("sign", -5.6, -12.7, -0.2'f)
  detail("sign", -2, 20.5, 0.2'f)
  detail("beehive", TownOrchard.x - 1.5'f,
    TownOrchard.y + 1.5'f, 0.1'f, 1.4'f)
  detail("lupins", TownIsland.x, TownIsland.y + 1, size = 1.4'f)

  for i, house in map.houses:
    let
      center = villagePoint(house.center)
      yaw = houseYaw(i)
      turnCos = cos(yaw)
      turnSin = sin(yaw)

    proc localPoint(x, z: float32, height = 0'f): Vec3 =
      ## Keeps roof planting and facade props attached to the scaled cottage.
      let
        px = center.x - 0.5'f + (turnCos * x - turnSin * z) * HouseScale
        pz = center.z - 0.5'f + (turnSin * x + turnCos * z) * HouseScale
      point(px, pz) + vec3(0, height * HouseScale, 0)

    proc localDetail(name: string, x, z: float32, size = 1'f) =
      ## Turns and scales the cottage's decorations with its facade.
      let position = localPoint(x, z)
      detail(name, position.x - 0.5'f, position.z - 0.5'f,
        yaw, size * HouseScale)

    art.houses.placeProp("home" & $i, center, yaw)
    for side in [-1'f, 1'f]:
      art.props[2].placeProp(
        art.names[2], localPoint(side * 3.1'f, 2.4'f), yaw,
        0.95'f * HouseScale
      )
      localDetail("lupins", side * 5.8'f, 0.6'f, 1.1'f)
      localDetail("lantern", side * 6.4'f, 4.1'f, 0.85'f)
    for j in 0 ..< 18:
      let
        angle = j.float32 * 2'f * PI.float32 / 18'f
        px = cos(angle) * 6.8'f
        pz = sin(angle) * 4.0'f
        position = localPoint(px, pz)
      if pz > 3 and abs(px) < 1.7'f:
        continue
      flowers(position.x - 0.5'f, position.z - 0.5'f,
        i + j, 1.2'f * HouseScale)
    localDetail("sunflowers", 5.8'f, -1.3'f, 1.2'f)
    if i in [0, 7, 8]:
      let
        px = -1.6'f
        pz = HouseHillCenterZ - 0.8'f
        height = roofHeight(art.roof, px, pz)
      art.props[4].placeProp(
        art.names[4],
        localPoint(px / HouseScale, pz / HouseScale, height / HouseScale),
        yaw, 2.7'f * HouseScale
      )
    for j in 0 ..< 11:
      let
        angle = j.float32 * 2'f * PI.float32 / 11'f
        px = cos(angle) * 2.4'f
        pz = sin(angle) * 2.15'f + HouseHillCenterZ
        height = roofHeight(art.roof, px, pz)
      if pz > HouseMeshOffset.z - 0.5'f or height < 0.5'f:
        continue
      let position = localPoint(
        px / HouseScale, pz / HouseScale, height / HouseScale)
      art.trees.placeProp(
        "leaf" & $(3 + j mod 3), position - vec3(0, 0.05, 0),
        yaw + j.float32, 0.65'f * HouseScale
      )
      if art.details.hasProp("flowers_white"):
        art.details.placeProp(
          "flowers_white", position,
          yaw + j.float32, 0.8'f * HouseScale
        )
    if i in [5, 8]:
      localDetail("laundry", 3.2'f, 2, 0.85'f)

  for i, tile in map.gardenTiles:
    art.props[3].placeProp(art.names[3], villagePoint(tile),
      houseYaw(i div GardensPerHouse), 0.9'f * HouseScale)

  for i, tree in borderTrees(seed):
    let position = point(tree.x.float32, tree.z.float32)
    if i mod 3 == 0:
      art.grove.rocks.placeProp(
        modelName(LightRock, i mod BrushVariants),
        position + vec3(1.3, 0, -1.2), tree.yaw,
        0.8'f + tree.size * 0.35'f
      )

  for spot in meadowSpots(seed):
    let
      x = spot.x.float32 / 1000
      z = spot.z.float32 / 1000
    if spot.key mod 3 != 0:
      flowers(x + 0.6'f, z + 0.5'f, spot.key, 1.15'f)
    if spot.key mod 7 == 0:
      detail("lupins", x - 0.5'f, z, size = 1.2'f)
  bakeTerrain(rebuildWalkability = false)

proc drawCrop*(
  art: VillageArt, tile: Tile2, kind: int, matrix: Mat4
) =
  ## Shows stocked gardens with colored boxes until crop models exist.
  const Colors = [
    vec3(0.9, 0.4, 0.1), vec3(0.8, 0.15, 0.1),
    vec3(0.3, 0.7, 0.2), vec3(0.6, 0.4, 0.2),
    vec3(0.9, 0.55, 0.1), vec3(0.7, 0.2, 0.5)
  ]
  let tint = Colors[kind mod Colors.len]
  art.placeholders.drawProp(
    "placeholder",
    villagePoint(tile) + vec3(0, GardenCropLift, 0),
    0,
    0.35'f * HouseScale,
    matrix,
    vec4(tint.x, tint.y, tint.z, 1)
  )
