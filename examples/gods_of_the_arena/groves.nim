import
  std/[math, random],
  chroma, gltf, vmath,
  polyworld/[assets, pathing, quadterrain],
  polyworld/treegen as trees,
  polyworld/rockgen as rocks,
  brushes, maps

const
  BrushVariants* = 10
  LightRockColor = vec3(0.86, 0.85, 0.86)
  DarkRockColor = vec3(0.49, 0.45, 0.63)
  TreePresets = [0, 0, 2, 3, 4, 5, 0, 0, 2, 1]
  LeafColors = [
    vec3(0.35, 0.57, 0.15), vec3(0.42, 0.62, 0.19),
    vec3(0.52, 0.66, 0.23), vec3(0.25, 0.48, 0.25),
    vec3(0.30, 0.52, 0.19), vec3(0.42, 0.59, 0.23),
    vec3(0.47, 0.63, 0.17), vec3(0.75, 0.69, 0.20),
    vec3(0.83, 0.73, 0.27), vec3(0.79, 0.25, 0.10)
  ]

type
  BrushKind* = enum
    LightTree, DarkTree, LightRock, DarkRock
  Grove* = object
    trees, rocks: PropPack
    colors*: seq[Vec3]

proc modelName(kind: BrushKind, variant: int): string =
  ## Names one of the forty reusable generated brush models.
  $kind & $variant

proc material(source: Material, tint: Vec3): Material =
  ## Shares the texture while giving each variant its own material tint.
  new(result)
  result[] = source[]
  result.baseColorFactor = color(tint.x, tint.y, tint.z, 1)

proc treeSettings*(dark: bool, variant, seed: int): trees.TreeSettings =
  ## Creates ten related silhouettes with green, yellow, or rare red foliage.
  result = trees.preset(
    if dark: 6 + variant mod 3 else: TreePresets[variant],
    seed = seed
  )
  result.roots = 4
  result.radialSides = 5
  result.trunkSegments = 6
  result.branchSegments = 3
  result.branches = if dark: 5 + variant mod 3 else: 5
  result.forks = if dark and variant mod 3 == 1: 1 else: 0
  result.barkColor =
    if dark: vec3(0.23, 0.18, 0.22)
    else: vec3(0.43, 0.31, 0.19)
  result.colorVariation = 0.08'f
  if not dark:
    result.leafColor = LeafColors[variant]
    result.rings = 6
    result.cardsPerRing = 7
    result.density = 0.8'f
    result.packing = 1.1'f
    result.shells = 1

proc rockSettings*(dark: bool, variant, seed: int): rocks.RockSettings =
  ## Cuts every boulder at half height before its exposed mesh is planted.
  const
    LightPresets = [1, 3, 4, 8, 5, 1, 3, 6, 8, 2]
    DarkPresets = [0, 7, 5, 8, 0, 7, 6, 5, 8, 2]
  result = rocks.preset(
    if dark: DarkPresets[variant] else: LightPresets[variant],
    seed = seed
  )
  result.width = 1.45'f + (variant mod 4).float32 * 0.14'f
  result.depth = 1.35'f + (variant mod 3).float32 * 0.18'f
  result.height = 1.8'f + (variant mod 5).float32 * 0.18'f
  result.floorCut = 0.5'f
  result.removeBottom = true
  result.fillSubdivisions = 0
  result.tint =
    if dark: DarkRockColor
    else: LightRockColor
  result.tint *= 0.92'f + (variant mod 4).float32 * 0.045'f

proc generateGrove*(seed: int): Grove =
  ## Generates forty models once and shares their textures from polyworld_data.
  let
    treeMaterials = trees.loadMaterials(1)
    rockMaterials = rocks.loadMaterials()
  var treeNodes, rockNodes: seq[Node]
  for kind in BrushKind:
    for variant in 0 ..< BrushVariants:
      let modelSeed = int(
        (seed.int64 * 104_729 + kind.ord.int64 * 7_919 +
          variant.int64 * 997 + 42) mod 1_000_000_000
      )
      case kind
      of LightTree, DarkTree:
        let
          settings = treeSettings(kind == DarkTree, variant, modelSeed)
          geometry = trees.generateGeometry(settings)
          materials = trees.TreeMaterials(
            bark: material(treeMaterials.bark, settings.barkColor),
            foliage: material(treeMaterials.foliage, settings.leafColor),
            cut: treeMaterials.cut
          )
          node = trees.treeNode(geometry, materials)
          size = geometry.maximum - geometry.minimum
          height = 2.6'f + (variant mod 4).float32 * 0.18'f
          scale = height / size.y
          width = min(scale, 2.1'f / max(size.x, size.z))
        node.name = modelName(kind, variant)
        node.scale = vec3(width, scale, width)
        treeNodes.add node
      of LightRock, DarkRock:
        let
          settings = rockSettings(kind == DarkRock, variant, modelSeed)
          materials = rocks.RockMaterials(
            stone: material(rockMaterials.stone, settings.tint)
          )
          node = rocks.rockNode(rocks.generateGeometry(settings), materials)
        node.name = modelName(kind, variant)
        rockNodes.add node
  result.trees = createPropPack(
    treeNodes, textureSize = GeneratorTextureSize, repeatTexture = true
  )
  result.rocks = createPropPack(
    rockNodes, textureSize = GeneratorTextureSize, mipmaps = false
  )

proc plantGrove*(grove: var Grove, brush: BrushMix, seed: int) =
  ## Reuses seeded models on blocked brush tiles without changing navigation.
  let ground = layers[GroundLayer]
  grove.colors = newSeq[Vec3](ground.tiles.len)
  for index, tile in ground.tiles:
    if not tile.exists or not tile.impassable:
      continue
    var kind: BrushKind
    if brush.trees[index] > 0:
      kind = LightTree
    elif brush.darkTrees[index]:
      kind = DarkTree
    elif brush.lightRocks[index]:
      kind = LightRock
    elif brush.darkRocks[index]:
      kind = DarkRock
    else:
      continue
    let
      x = index mod ground.width
      z = index div ground.width
    var rng = initRand(
      x.int64 * 73_856_093 + z.int64 * 19_349_663 +
        seed.int64 * 83_492_791 + 1
    )
    let
      roll = rng.rand(99)
      variant =
        if kind != LightTree: rng.rand(BrushVariants - 1)
        elif roll < 75: rng.rand(6)
        elif roll < 95: rng.rand(7 .. 8)
        else: 9
      worldX = (ground.originX + x).float32 - HalfGrid + 0.5'f
      worldZ = (ground.originZ + z).float32 - HalfGrid + 0.5'f
      size =
        if kind in {LightTree, DarkTree}: 0.85'f + rng.rand(0.45).float32
        else: 0.5'f + rng.rand(1.0).float32
      pack = if kind in {LightTree, DarkTree}: grove.trees else: grove.rocks
    var base = groundHeight(worldX, worldZ) + groundOffset(worldX, worldZ)
    if kind in {LightRock, DarkRock}:
      # Tuck the open cut beneath the lowest local ground instead of floating.
      for dx in [-0.45'f, 0.45'f]:
        for dz in [-0.45'f, 0.45'f]:
          base = min(base, groundHeight(worldX + dx, worldZ + dz) +
            groundOffset(worldX + dx, worldZ + dz))
    base -= 0.04'f
    pack.placeProp(
      modelName(kind, variant),
      vec3(worldX, base, worldZ),
      rotation = rng.rand(2 * PI).float32,
      scale = size
    )
    grove.colors[index] =
      case kind
      of LightTree: LeafColors[variant] * 0.58'f
      of DarkTree: vec3(0.18, 0.14, 0.17)
      of LightRock: LightRockColor * 0.5'f
      of DarkRock: DarkRockColor * 0.5'f
