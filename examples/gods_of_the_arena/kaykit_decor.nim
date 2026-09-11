## Rich, deterministic landmark dressing made from the shared KayKit models.
##
## The props are presentation-only. Placements follow the terrain height and
## reject the authored lane envelope, so they cannot hide combat silhouettes.

import
  std/math,
  vmath,
  decor, maps,
  polyworld/[pathing, quadterrain, rngs]

const
  KayKitDecorStream = 0xBB67AE8584CAA73B'u64
  LaneClearance = 4.25'f32
  ForestTrees = [
    "Tree_3_A_Color1", "Tree_6_A_Color1", "Tree_Bare_1_B_Color1"
  ]
  ForestBushes = [
    "Bush_1_A_Color1", "Bush_3_A_Color1", "Bush_4_B_Color1"
  ]

type LandmarkCenter* = tuple[x, z: int]

proc unit(rng: var Rng): float32 =
  rng.below(10_000).float32 / 10_000.0'f32

proc placeAt(
    pack: PropPack,
    name: string,
    x, z: float32,
    rotation, propScale: float32,
    tint = vec3(1, 1, 1),
    clearance = LaneClearance
) =
  if x < 1 or z < 1 or x >= GridTiles.float32 - 1 or
      z >= GridTiles.float32 - 1 or not besideLane(x, z, clearance):
    return
  let
    tileX = clamp(int(floor(x)), 0, GridTiles - 1)
    tileZ = clamp(int(floor(z)), 0, GridTiles - 1)
  var position = tileCenter(GroundLayer, tileX, tileZ)
  position.x += x - tileX.float32
  position.z += z - tileZ.float32
  position.y = groundHeight(position.x, position.z)
  pack.placeProp(name, position, rotation, propScale, tint)

proc placePair(
    pack: PropPack,
    name: string,
    x, z: float32,
    rotation, propScale: float32,
    tint = vec3(1, 1, 1),
    clearance = LaneClearance
) =
  pack.placeAt(name, x, z, rotation, propScale, tint, clearance)
  pack.placeAt(
    name,
    (GridTiles - 1).float32 - x,
    (GridTiles - 1).float32 - z,
    rotation + PI.float32,
    propScale,
    tint,
    clearance
  )

proc placeForestEdgeGroves(pack: PropPack, rng: var Rng) =
  ## Layered silhouettes at woodland edges: tall canopy, deadwood, then
  ## bushes/grass. These are sparse enough to complement the existing forest.
  for (centerX, centerZ, turn) in [
    (50.0'f32, 30.0'f32, 0.2'f32),
    (30.0'f32, 50.0'f32, 1.1'f32),
    (58.0'f32, 38.0'f32, -0.5'f32)
  ]:
    let tree = ForestTrees[int(rng.below(ForestTrees.len.int32))]
    pack.placePair(
      tree, centerX, centerZ, turn, 3.6'f32 + rng.unit() * 0.8'f32,
      vec3(0.72'f32, 0.82'f32, 0.68'f32))
    pack.placePair(
      ForestBushes[int(rng.below(ForestBushes.len.int32))],
      centerX + 2.1'f32, centerZ - 1.3'f32, turn + 0.7'f32,
      1.15'f32 + rng.unit() * 0.25'f32,
      vec3(0.76'f32, 0.86'f32, 0.72'f32))
    pack.placePair(
      "Grass_1_C_Color1", centerX - 1.8'f32, centerZ + 1.5'f32,
      turn - 0.4'f32, 0.65'f32,
      vec3(0.88'f32, 0.96'f32, 0.83'f32))

  # A rare warmer tree gives the forest a readable landmark without turning
  # the arena into a brightly coloured garden.
  pack.placePair(
    "Tree_5_A_Color2", 47.0'f32, 33.0'f32, 0.35'f32, 3.9'f32,
    vec3(0.78'f32, 0.76'f32, 0.68'f32))
  pack.placePair(
    "Bush_2_A_Color3", 45.5'f32, 34.5'f32, -0.2'f32, 1.25'f32,
    vec3(0.94'f32, 0.90'f32, 0.86'f32))
  pack.placePair(
    "Food_Basket_A_Berries", 52.4'f32, 32.2'f32, 0.6'f32, 0.72'f32,
    vec3(1.0'f32, 0.94'f32, 0.86'f32))

proc placeHillCrown(pack: PropPack, center: LandmarkCenter, rng: var Rng) =
  ## A lone wind-shaped tree accents the crown while boulders reinforce the
  ## rocky shoulder bands. The climb and summit center stay unobstructed.
  for (name, dx, dz, scale) in [
    ("Tree_Bare_2_A_Color8", -4.0'f32, 0.8'f32, 3.6'f32),
    ("Rock_5_B_Color1", -5.2'f32, 3.0'f32, 1.55'f32),
    ("Rock_3_A_Color6", 5.0'f32, 3.2'f32, 1.45'f32),
    ("Rock_2_E_Color1", 2.8'f32, 6.2'f32, 1.20'f32)
  ]:
    pack.placePair(
      name, center.x.float32 + dx, center.z.float32 + dz,
      rng.unit() * 2.0'f32 * PI.float32, scale,
      vec3(0.94'f32, 0.95'f32, 0.88'f32))

proc placeQuarry(pack: PropPack, center: LandmarkCenter, rng: var Rng) =
  ## Broken rock on the lip and a small work site in the hollow communicate
  ## the negative terrain form without filling its walkable floor.
  for (name, dx, dz, scale) in [
    ("Rock_3_A_Color6", -5.2'f32, -1.8'f32, 1.65'f32),
    ("Rock_2_E_Color1", 4.8'f32, -2.6'f32, 1.35'f32),
    ("Rock_5_B_Color1", 5.5'f32, 2.0'f32, 1.15'f32),
    ("Stone_Chunks_Large", -3.8'f32, 3.8'f32, 1.05'f32),
    ("bucket_pickaxes", 2.8'f32, 4.0'f32, 0.95'f32),
    ("scaffold_frame_large", -5.4'f32, 1.7'f32, 1.8'f32),
    ("Containers_Crate_Medium_Wood", -1.8'f32, 4.7'f32, 0.48'f32),
    ("rope_bundle_A", -0.4'f32, 4.4'f32, 0.20'f32),
    ("lantern", 1.0'f32, 4.5'f32, 0.52'f32),
    ("pickaxe", 2.0'f32, -4.0'f32, 0.85'f32),
    ("shovel", 3.0'f32, -3.6'f32, 0.85'f32)
  ]:
    pack.placePair(
      name, center.x.float32 + dx, center.z.float32 + dz,
      rng.unit() * 2.0'f32 * PI.float32, scale,
      vec3(0.95'f32, 0.91'f32, 0.82'f32))

proc placeKayKitDecor*(
    pack: PropPack,
    seed: int32,
    hillCenter, quarryCenter: LandmarkCenter
) =
  ## Adds forest-edge richness plus landmark-specific hill/quarry dressing.
  ## The caller supplies centers owned by maps.nim so visual and terrain
  ## compositions stay in sync.
  if pack == nil or layers.len == 0:
    return
  var rng = initRng(seed, KayKitDecorStream)
  pack.placeForestEdgeGroves(rng)
  pack.placeHillCrown(hillCenter, rng)
  pack.placeQuarry(quarryCenter, rng)
