import
  chroma, gltf, vmath,
  assets, quadterrain,
  treegen as trees,
  rockgen as rocks

const
  BrushVariants* = 10
  LightRockColor* = vec3(0.86, 0.85, 0.86)
  DarkRockColor* = vec3(0.49, 0.45, 0.63)
  TreePresets = [0, 0, 2, 3, 4, 5, 0, 0, 2, 1]
  LeafColors* = [
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
    trees*, rocks*: PropPack
    colors*: seq[Vec3]

proc modelName*(kind: BrushKind, variant: int): string =
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

proc generateGrove*(
  seed: int,
  kinds: set[BrushKind] = {LightTree, DarkTree, LightRock, DarkRock}
): Grove =
  ## Generates reusable model variants with shared project textures.
  let
    treeMaterials = trees.loadMaterials(1)
    rockMaterials = rocks.loadMaterials()
  var treeNodes, rockNodes: seq[Node]
  for kind in BrushKind:
    if kind notin kinds:
      continue
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
