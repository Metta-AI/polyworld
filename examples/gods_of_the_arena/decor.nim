## Deterministic, presentation-only dressing for the authored arena.
##
## Decorations never alter pathing, vision, simulation state, or the map hash.
## Low silhouettes live on lane verges and riverbanks; taller landmarks are
## limited to the central shallows. Every placement has a rotated partner.

import
  std/math,
  vmath,
  maps,
  polyworld/[pathing, quadterrain, rngs]

const
  DecorStream = 0xA24BAED4963EE407'u64
  RiverDecorStream = 0x3C6EF372FE94F82B'u64
  LandmarkDecorStream = 0xBB67AE8584CAA73B'u64
  VergeDecorBudget = 260
  VergePlants = [
    "grass_patch_01a", "grass_patch_02a", "grass_patch_03a",
    "flowers_patch_01a", "flowers_patch_02a", "flowers_patch_03a"
  ]
  BankDecor = [
    "plant_04a", "plant_05a", "plant_06a", "rock_small_01a",
    "rock_small_02a", "rock_small_03a", "rock_small_04a"
  ]
  RiverTrees = [
    "tree_01a", "tree_02a", "tree_03a", "tree_04a", "tree_05a", "tree_06a"
  ]
  Reeds = ["plant_01a", "plant_02a", "plant_03a", "plant_07a"]
  WaterLilies = ["lily_flower_01a", "lily_flower_02a", "lily_flower_03a"]

type LaneDoodad = tuple[
  name: string,
  x, z: int,
  jitterX, jitterZ, rotation, scale: float32
]

proc unit(rng: var Rng): float32 =
  rng.below(10_000).float32 / 10_000.0'f32

proc laneDistanceSquared(x, z: float32): float32 =
  ## Measures against the authored centerlines so presentation props can
  ## stay outside the space used by troops and combat silhouettes.
  result = float32.high
  for route in LaneRoutes:
    for i in 0 ..< route.len - 1:
      let
        a = route[i]
        b = route[i + 1]
        abX = (b.x - a.x).float32
        abZ = (b.z - a.z).float32
        lengthSquared = abX * abX + abZ * abZ
        t =
          if lengthSquared > 0:
            clamp(((x - a.x.float32) * abX +
              (z - a.z.float32) * abZ) / lengthSquared, 0.0'f32, 1.0'f32)
          else:
            0.0'f32
        dx = x - (a.x.float32 + abX * t)
        dz = z - (a.z.float32 + abZ * t)
      result = min(result, dx * dx + dz * dz)

proc besideLane*(x, z: float32, clearance = 3.4'f32): bool =
  ## Shared presentation clearance for every arena decoration pack.
  laneDistanceSquared(x, z) >= clearance * clearance

proc placePair(
    pack: PropPack,
    name: string,
    x, z: int,
    jitterX, jitterZ, rotation, propScale: float32,
    tint: Vec3
) =
  let
    mirrorX = GridTiles - 1 - x
    mirrorZ = GridTiles - 1 - z
  var
    first = tileCenter(GroundLayer, x, z)
    second = tileCenter(GroundLayer, mirrorX, mirrorZ)
  first.x += jitterX
  first.z += jitterZ
  second.x -= jitterX
  second.z -= jitterZ
  first.y = groundHeight(first.x, first.z)
  second.y = groundHeight(second.x, second.z)
  pack.placeProp(name, first, rotation, propScale, tint)
  pack.placeProp(name, second, rotation + PI.float32, propScale, tint)

proc placeLaneEdgePair(
    pack: PropPack,
    name: string,
    x, z: int,
    jitterX, jitterZ, rotation, propScale: float32,
    tint: Vec3,
    clearance = 3.4'f32
) =
  ## Keeps both members of a visual pair outside the authored lane envelope.
  if not besideLane(x.float32 + jitterX, z.float32 + jitterZ, clearance):
    return
  let
    mirrorX = GridTiles - 1 - x
    mirrorZ = GridTiles - 1 - z
  if not besideLane(
      mirrorX.float32 - jitterX, mirrorZ.float32 - jitterZ, clearance):
    return
  pack.placePair(
    name, x, z, jitterX, jitterZ, rotation, propScale, tint
  )

proc placeLaneVignette(
    pack: PropPack,
    doodads: openArray[LaneDoodad],
    tint: Vec3,
    clearance: float32
) =
  for doodad in doodads:
    pack.placeLaneEdgePair(
      doodad.name, doodad.x, doodad.z, doodad.jitterX, doodad.jitterZ,
      doodad.rotation, doodad.scale, tint, clearance)

proc nearWater(x, z, radius: int): bool =
  ## Finds dry bank tiles bordering the rendered channel, including its
  ## wider calm reaches around the three fords.
  let water = layers[WaterLayer]
  for dz in -radius .. radius:
    for dx in -radius .. radius:
      let
        tx = x + dx
        tz = z + dz
      if tx >= 0 and tz >= 0 and tx < water.width and tz < water.depth and
          water.tiles[tz * water.width + tx].exists:
        return true

proc placeWaterPair(
    pack: PropPack,
    name: string,
    x, z: int,
    jitterX, jitterZ, rotation, propScale: float32,
    tint: Vec3
) =
  ## Floats a symmetric pair directly on the water surface rather than on
  ## the carved riverbed sampled by groundHeight.
  let
    mirrorX = GridTiles - 1 - x
    mirrorZ = GridTiles - 1 - z
    water = layers[WaterLayer]
  if not water.tiles[z * water.width + x].exists or
      not water.tiles[mirrorZ * water.width + mirrorX].exists:
    return
  var
    first = tileCenter(WaterLayer, x, z)
    second = tileCenter(WaterLayer, mirrorX, mirrorZ)
  first.x += jitterX
  first.z += jitterZ
  second.x -= jitterX
  second.z -= jitterZ
  first.y += 0.025'f32
  second.y += 0.025'f32
  pack.placeProp(name, first, rotation, propScale, tint)
  pack.placeProp(name, second, rotation + PI.float32, propScale, tint)

proc placeRiverDecor(pack: PropPack, seed: int32) =
  ## Builds an irregular riparian silhouette with trees set back on dry land,
  ## reeds at the wet edge, and small lily groups in the quieter water tiles.
  ## All choices are point-symmetric and presentation-only.
  var rng = initRng(seed, RiverDecorStream)
  let
    ground = layers[GroundLayer]
    water = layers[WaterLayer]
  var
    riverTreesPlaced = 0
    reedsPlaced = 0
    liliesPlaced = 0
    treeSites: seq[tuple[x, z: int]]

  for z in 2 ..< GridTiles - 2:
    for x in 2 ..< GridTiles - 2:
      let
        mirrorX = GridTiles - 1 - x
        mirrorZ = GridTiles - 1 - z
        index = z * GridTiles + x
        mirrorIndex = mirrorZ * GridTiles + mirrorX
        kind = ground.tiles[index].kind
      if index >= mirrorIndex:
        continue

      if kind == GrassTile and ground.tiles[mirrorIndex].kind == GrassTile and
          nearWater(x, z, 3) and nearWater(mirrorX, mirrorZ, 3) and
          besideLane(x.float32, z.float32, 5.5'f32) and
          besideLane(mirrorX.float32, mirrorZ.float32, 5.5'f32) and
          riverTreesPlaced < 30 and rng.chance(13):
        var spaced = true
        for site in treeSites:
          if abs(site.x - x) <= 4 and abs(site.z - z) <= 4:
            spaced = false
            break
        if spaced:
          let
            jitterX = (rng.unit() - 0.5'f32) * 0.45'f32
            jitterZ = (rng.unit() - 0.5'f32) * 0.45'f32
          pack.placePair(
            RiverTrees[int(rng.below(RiverTrees.len.int32))], x, z,
            jitterX, jitterZ, rng.unit() * 2.0'f32 * PI.float32,
            3.15'f32 + rng.unit() * 1.15'f32,
            vec3(0.82'f32, 0.91'f32, 0.78'f32)
          )
          treeSites.add((x, z))
          riverTreesPlaced += 2

      if kind == WetBankKind and
          ground.tiles[mirrorIndex].kind == WetBankKind and
          nearWater(x, z, 1) and nearWater(mirrorX, mirrorZ, 1) and
          reedsPlaced < 96 and rng.chance(24):
        pack.placePair(
          Reeds[int(rng.below(Reeds.len.int32))], x, z,
          (rng.unit() - 0.5'f32) * 0.6'f32,
          (rng.unit() - 0.5'f32) * 0.6'f32,
          rng.unit() * 2.0'f32 * PI.float32,
          0.38'f32 + rng.unit() * 0.34'f32,
          vec3(0.80'f32, 0.94'f32, 0.72'f32)
        )
        reedsPlaced += 2

      if water.tiles[index].exists and water.tiles[mirrorIndex].exists and
          liliesPlaced < 48 and rng.chance(7):
        pack.placeWaterPair(
          WaterLilies[int(rng.below(WaterLilies.len.int32))], x, z,
          (rng.unit() - 0.5'f32) * 0.5'f32,
          (rng.unit() - 0.5'f32) * 0.5'f32,
          rng.unit() * 2.0'f32 * PI.float32,
          0.22'f32 + rng.unit() * 0.18'f32,
          vec3(0.92'f32, 1.0'f32, 0.90'f32)
        )
        liliesPlaced += 2

  # A sound skiff and an old wreck make the broad outer reaches feel used.
  # These sit away from all crossings, and their mirrored partners keep the
  # same amount of visual information on both team halves of the map.
  pack.placeWaterPair(
    "boat_wreck_01a", 113, 14, 0.15'f32, -0.10'f32, 0.72'f32, 0.78'f32,
    vec3(0.82'f32, 0.76'f32, 0.66'f32)
  )
  pack.placeWaterPair(
    "boat_01a", 87, 41, -0.12'f32, 0.08'f32, -0.68'f32, 0.92'f32,
    vec3(0.90'f32, 0.84'f32, 0.72'f32)
  )

proc placeLaneLandmarks(pack: PropPack) =
  ## Successive silhouettes along the outer lane give travel a readable
  ## rhythm: flower stone, abandoned cart, mushroom copse, ford cairn,
  ## supply stop, and broken fence. Point symmetry gives the opposing route
  ## the same progression in reverse without changing gameplay collision.

  # A bright verge garden is the first landmark beyond each gate court.
  pack.placeLaneVignette([
    ("rock_medium_01a", 40, 14, 0.0'f32, 0.0'f32, 0.35'f32, 0.82'f32),
    ("flower_bush_02a", 39, 13, 0.15'f32, 0.10'f32, -0.4'f32, 0.68'f32),
    ("flowers_patch_03a", 42, 13, -0.1'f32, 0.0'f32, 0.8'f32, 0.48'f32)
  ], vec3(0.96'f32, 0.94'f32, 0.84'f32), 4.0'f32)

  # A tipped cart and its loose wheel make a strong mid-field silhouette.
  pack.placeLaneVignette([
    ("wood_cart_01a", 62, 12, 0.0'f32, 0.0'f32, 1.45'f32, 1.05'f32),
    ("wood_wheel_01a", 65, 12, -0.1'f32, 0.1'f32, 0.25'f32, 0.72'f32),
    ("wood_crate_01a", 60, 13, 0.2'f32, 0.0'f32, -0.3'f32, 0.58'f32),
    ("rope_01a", 63, 13, 0.2'f32, 0.0'f32, 0.6'f32, 0.45'f32)
  ], vec3(0.90'f32, 0.82'f32, 0.68'f32), 4.25'f32)

  # Mushrooms and pale stones identify the shaded woodland bend.
  pack.placeLaneVignette([
    ("rock_small_03a", 84, 13, 0.0'f32, 0.0'f32, -0.2'f32, 0.62'f32),
    ("mushroom_01a", 82, 13, 0.2'f32, 0.1'f32, 0.4'f32, 0.34'f32),
    ("mushroom_03a", 85, 12, -0.15'f32, 0.0'f32, 1.1'f32, 0.30'f32),
    ("mushroom_06a", 86, 14, 0.1'f32, -0.1'f32, -0.7'f32, 0.38'f32),
    ("grass_patch_05a", 83, 12, 0.0'f32, 0.0'f32, 0.2'f32, 0.50'f32)
  ], vec3(0.86'f32, 0.94'f32, 0.80'f32), 4.0'f32)

  # A small cairn announces the descent toward the river ford.
  pack.placeLaneVignette([
    ("rock_medium_03a", 99, 21, 0.0'f32, 0.0'f32, 0.2'f32, 0.88'f32),
    ("rock_small_01a", 100, 20, 0.2'f32, 0.0'f32, -0.5'f32, 0.56'f32),
    ("plant_06a", 98, 20, -0.1'f32, 0.15'f32, 0.7'f32, 0.52'f32)
  ], vec3(0.86'f32, 0.90'f32, 0.78'f32), 3.6'f32)

  # Barrels and a lantern-like post form a recognizable riverside rest stop.
  pack.placeLaneVignette([
    ("wood_barrel_01a", 114, 61, 0.0'f32, 0.0'f32, 0.35'f32, 0.72'f32),
    ("wood_crate_01a", 114, 63, 0.15'f32, 0.0'f32, -0.25'f32, 0.60'f32),
    ("lamp_post_01a", 115, 59, 0.0'f32, 0.0'f32, 0.1'f32, 1.55'f32),
    ("grass_patch_04a", 113, 64, 0.0'f32, 0.0'f32, 0.8'f32, 0.52'f32)
  ], vec3(0.94'f32, 0.88'f32, 0.72'f32), 4.5'f32)

  # A collapsed fence marks the final long approach to enemy territory.
  pack.placeLaneVignette([
    ("wood_fence_01a", 114, 87, 0.0'f32, 0.0'f32, 0.1'f32, 1.08'f32),
    ("wood_fence_pole_01a", 115, 90, 0.0'f32, 0.0'f32, 0.25'f32, 0.95'f32),
    ("rock_small_04a", 113, 89, -0.1'f32, 0.1'f32, 0.5'f32, 0.58'f32),
    ("bush_02a", 114, 85, 0.2'f32, -0.1'f32, -0.35'f32, 0.64'f32)
  ], vec3(0.88'f32, 0.88'f32, 0.76'f32), 4.5'f32)

proc placeArenaDecor*(pack: PropPack, seed: int32) =
  ## Dresses symmetric road shoulders and banks without changing collision.
  if pack == nil or layers.len == 0:
    return
  var rng = initRng(seed, DecorStream)
  let ground = layers[GroundLayer]
  pack.placeRiverDecor(seed)
  pack.placeLaneLandmarks()
  var placed = 0
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        mirrorX = GridTiles - 1 - x
        mirrorZ = GridTiles - 1 - z
        index = z * GridTiles + x
        mirrorIndex = mirrorZ * GridTiles + mirrorX
      if index >= mirrorIndex or placed >= VergeDecorBudget:
        continue
      let
        kind = ground.tiles[index].kind
        mirrorKind = ground.tiles[mirrorIndex].kind
      if kind != mirrorKind:
        continue
      var
        name = ""
        scale = 0.45'f32
      if kind == LaneShoulderKind and rng.chance(17):
        name = VergePlants[int(rng.below(VergePlants.len.int32))]
        scale = 0.32'f32 + rng.unit() * 0.30'f32
      elif kind == WetBankKind and rng.chance(20):
        name = BankDecor[int(rng.below(BankDecor.len.int32))]
        scale = 0.30'f32 + rng.unit() * 0.35'f32
      elif kind == LandmarkHillKind and rng.chance(24):
        name = VergePlants[int(rng.below(VergePlants.len.int32))]
        scale = 0.34'f32 + rng.unit() * 0.38'f32
      elif kind == QuarryRimKind and rng.chance(16):
        name = BankDecor[int(rng.below(BankDecor.len.int32))]
        scale = 0.28'f32 + rng.unit() * 0.34'f32
      if name.len == 0:
        continue
      let
        jitterX = (rng.unit() - 0.5'f32) * 0.55'f32
        jitterZ = (rng.unit() - 0.5'f32) * 0.55'f32
      if not besideLane(x.float32 + jitterX, z.float32 + jitterZ):
        continue
      pack.placeLaneEdgePair(
        name, x, z,
        jitterX,
        jitterZ,
        rng.unit() * 2.0'f32 * PI.float32,
        scale,
        vec3(0.92'f32, 0.96'f32, 0.90'f32)
      )
      placed += 2

  # Four substantial lamps announce the central ford from its dry outer edges
  # while keeping the full diagonal wading route visually open.
  for (x, z, rotation) in [
    (57, 63, 0.75'f32),
    (63, 57, -0.75'f32)
  ]:
    pack.placeLaneEdgePair(
      "lamp_post_01a", x, z, 0, 0, rotation, 2.25'f32,
      vec3(0.95'f32, 0.90'f32, 0.78'f32)
    )
  for (name, x, z, rotation) in [
    ("pier_bollard_01a", 56, 62, -0.75'f32),
    ("pier_bollard_02a", 62, 56, 0.75'f32)
  ]:
    pack.placeLaneEdgePair(
      name, x, z, 0, 0, rotation, 1.05'f32,
      vec3(0.88'f32, 0.78'f32, 0.64'f32)
    )

  # Paired lamps punctuate outer and gate tower plazas. They sit beyond the
  # fighting centre and do not participate in collision or vision.
  for lane in 0 .. 2:
    for tier in [0, 2]:
      let
        site = TowerSites[lane][0][tier]
        directionX = cmp(site.faceX, site.x)
        directionZ = cmp(site.faceZ, site.z)
        sideX = directionZ
        sideZ = -directionX
      for side in [-1, 1]:
        pack.placeLaneEdgePair(
          "lamp_post_01a",
          site.x + sideX * side * 4,
          site.z + sideZ * side * 4,
          0, 0, rng.unit() * 2.0'f32 * PI.float32, 1.75'f32,
          vec3(0.92'f32, 0.88'f32, 0.74'f32)
        )

  # Stone-and-shrub vignettes mark important lane bends, while larger rocks
  # visually close the river mouths at the edge of the playable arena.
  for (name, x, z, rotation, scale) in [
    ("rock_medium_01a", 98, 31, 0.4'f32, 0.75'f32),
    ("flower_bush_01a", 96, 28, -0.3'f32, 0.65'f32),
    ("rock_medium_02a", 31, 98, 1.2'f32, 0.70'f32),
    ("bush_01a", 28, 96, 0.2'f32, 0.70'f32),
    ("rock_medium_03a", 122, 3, 0.1'f32, 1.35'f32),
    ("rock_medium_01a", 124, 5, 1.0'f32, 1.15'f32),
    ("rock_medium_02a", 120, 1, -0.6'f32, 1.10'f32)
  ]:
    pack.placeLaneEdgePair(
      name, x, z, 0, 0, rotation, scale,
      vec3(0.90'f32, 0.91'f32, 0.84'f32)
    )

  # Small supply clusters make the fort interiors feel inhabited. Their
  # positions mirror exactly; differing rotations keep the composition from
  # looking stamped while remaining presentation-only.
  for (name, x, z, rotation) in [
    ("wood_barrel_01a", 11, 19, 0.25'f32),
    ("wood_barrel_01a", 12, 19, 1.10'f32),
    ("wood_crate_01a", 11, 20, -0.20'f32),
    ("wood_fence_pole_01a", 11, 17, 0.0'f32),
    ("wood_fence_pole_01a", 17, 11, PI.float32 / 2.0'f32)
  ]:
    pack.placePair(
      name, x, z, 0, 0, rotation,
      if name == "wood_fence_pole_01a": 1.15'f32 else: 0.75'f32,
      vec3(0.96'f32, 0.92'f32, 0.82'f32)
    )

  # Exposed cliff shelves break the landmark hill's smooth silhouette. They
  # follow the painted rock bands while leaving its climb and summit open.
  for (name, x, z, rotation, scale) in [
    ("cliff_01a", 56, 39, 0.25'f32, 1.35'f32),
    ("cliff_02a", 69, 41, -0.35'f32, 1.25'f32),
    ("rock_large_03a", 58, 43, 0.55'f32, 1.12'f32),
    ("rock_large_02a", 68, 44, -0.65'f32, 1.08'f32),
    ("rock_platform_01a", 61, 45, 0.15'f32, 0.82'f32),
    ("rock_platform_02a", 66, 45, -0.2'f32, 0.78'f32)
  ]:
    pack.placeLaneEdgePair(
      name, x, z, 0, 0, rotation, scale,
      vec3(0.88'f32, 0.88'f32, 0.82'f32)
    )

  # Quarry dressing clusters on the working floor's rear edge and around the
  # rim. The centre and lane-facing cut remain visually uncluttered.
  for (name, x, z, rotation, scale) in [
    ("rock_medium_02a", 34, 56, 0.3'f32, 1.20'f32),
    ("rock_medium_03a", 43, 60, -0.8'f32, 1.08'f32),
    ("rock_small_04a", 42, 68, 0.5'f32, 0.88'f32),
    ("wood_barrel_01a", 39, 61, 0.2'f32, 0.76'f32),
    ("wood_crate_01a", 40, 62, -0.3'f32, 0.72'f32),
    ("pier_bollard_02a", 39, 66, 0.4'f32, 0.92'f32),
    ("wood_fence_pole_01a", 37, 71, PI.float32 / 2.0'f32, 1.12'f32)
  ]:
    pack.placeLaneEdgePair(
      name, x, z, 0, 0, rotation, scale,
      vec3(0.88'f32, 0.82'f32, 0.70'f32)
    )

proc placePainterlyLandmarks*(pack: PropPack, seed: int32) =
  ## Completes the landmark compositions with the same painted Meadow and
  ## Golden Valley families used by the terrain, without changing collision
  ## or lane clearance.
  if pack == nil or layers.len == 0:
    return
  var rng = initRng(seed, LandmarkDecorStream)

  # Layered forest-edge silhouettes tie the authored groves into the meadow.
  for (x, z, turn, tree) in [
    (50, 30, 0.2'f32, "tree_03a"),
    (30, 50, 1.1'f32, "tree_05a"),
    (58, 38, -0.5'f32, "tree_01a")
  ]:
    pack.placeLaneEdgePair(
      tree, x, z, 0.15'f32, -0.10'f32, turn,
      3.15'f32 + rng.unit() * 0.55'f32,
      vec3(0.82'f32, 0.91'f32, 0.78'f32), 4.25'f32)
    pack.placeLaneEdgePair(
      "bush_02a", x + 2, z - 1, 0.1'f32, -0.2'f32, turn + 0.7'f32,
      0.72'f32 + rng.unit() * 0.18'f32,
      vec3(0.86'f32, 0.94'f32, 0.81'f32), 4.25'f32)
    pack.placeLaneEdgePair(
      "grass_patch_05a", x - 2, z + 1, -0.1'f32, 0.2'f32,
      turn - 0.4'f32, 0.48'f32,
      vec3(0.90'f32, 0.96'f32, 0.84'f32), 4.25'f32)

  # A wind-shaped meadow tree and Golden Valley boulders crown each hill.
  # Their offset placement keeps the summit centre and ascent unobstructed.
  let hill = LandmarkHillSites[0]
  for (name, dx, dz, rotation, scale) in [
    ("tree_06a", -4, 1, 0.35'f32, 3.25'f32),
    ("rock_large_01a", -5, 3, 0.75'f32, 0.82'f32),
    ("rock_large_04a", 5, 3, -0.45'f32, 0.76'f32),
    ("rock_platform_02a", 3, 6, 0.2'f32, 0.58'f32),
    ("flower_bush_01a", -2, 5, -0.3'f32, 0.62'f32)
  ]:
    pack.placeLaneEdgePair(
      name, hill[0] + dx, hill[1] + dz, 0, 0,
      rotation + rng.unit() * 0.3'f32, scale,
      vec3(0.91'f32, 0.92'f32, 0.84'f32), 4.25'f32)

  # A coherent Meadow work site sits against the quarry's rear wall: a cart,
  # loose wheel, rope and supplies replace the low-poly mining kit. Golden
  # Valley stone reinforces the excavated lip while the floor stays open.
  let quarry = QuarrySites[0]
  for (name, dx, dz, rotation, scale) in [
    ("rock_large_03a", -5, -2, 0.25'f32, 0.72'f32),
    ("rock_platform_01a", 5, -2, -0.55'f32, 0.56'f32),
    ("wood_cart_01a", -4, 2, 1.25'f32, 0.88'f32),
    ("wood_wheel_01a", -2, 4, 0.15'f32, 0.62'f32),
    ("wood_crate_01a", 0, 4, -0.30'f32, 0.58'f32),
    ("wood_barrel_01a", 2, 4, 0.40'f32, 0.62'f32),
    ("rope_01a", 1, 3, 0.75'f32, 0.42'f32),
    ("wood_fence_01a", -5, 1, 1.45'f32, 0.82'f32)
  ]:
    pack.placeLaneEdgePair(
      name, quarry[0] + dx, quarry[1] + dz, 0, 0,
      rotation + rng.unit() * 0.25'f32, scale,
      vec3(0.90'f32, 0.84'f32, 0.72'f32), 4.25'f32)
