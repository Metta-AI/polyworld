import
  std/math,
  vmath,
  polyworld/rngs

const
  TownHouses* = [
    (0, -25), (-14, -20), (14, -18), (-16, -7), (16, -5),
    (-17, 9), (16, 11), (-10, 26), (10, 26)
  ]
  HouseScale* = 0.5'f
  HouseMeshScale* = 1.95'f * HouseScale
  HouseMeshOffset* = vec3(0, 0.06, 0.76) * HouseMeshScale
  HouseHillRadius* = 3.85'f * HouseMeshScale
  HouseHillCenterZ* = -1.39'f * HouseMeshScale
  HouseTurns* = [
    (996, -87), (940, -342), (883, 469), (906, -423), (829, 559),
    (839, -545), (788, 616), (819, -574), (875, 485)
  ]
  HouseGardenOffsets* = [
    (-1'i32, 2'i32), (1'i32, 2'i32), (4'i32, 2'i32)
  ]
  TownMinX* = -24'i32
  TownMaxX* = 24'i32
  TownMinZ* = -33'i32
  TownMaxZ* = 38'i32
  BorderTreeCount* = 24
  BorderTreeVariants* = [0, 1, 2, 7, 8, 9, 10, 11, 12]
  TownPlaza* = vec2(0, 0)
  TownWell* = vec2(2, 15)
  TownIsland* = vec2(2, -13)
  TownOrchard* = vec2(-7, 15)
  TownPlazaRadius* = 6.0'f
  TownLayoutScale* = 0.75'f
  TownOverviewDistance* = 88.0'f
  TownCameraTarget* = vec3(0, 0, 3)
  TownCameraPitch* = 0.92'f
  TownCameraScale* = 0.41421356'f

type
  RoadPoint* = object
    x*, z*, width*: int32
  BorderTree* = object
    x*, z*: int32
    variant*: int
    yaw*, size*, height*: float32
  MeadowSpot* = object
    x*, z*: int32
    key*: int
  GroundPlant* = object
    x*, z*, radius*: int32
    variant*: int
    yaw*, size*, height*: float32
  GardenFence* = object
    x*, z*, ax*, az*, bx*, bz*, radius*: int32
    yaw*, size*: float32

proc referenceRoad(x, y, width: int32): RoadPoint =
  ## Converts traced reference pixels to fixed thousandths of a town tile.
  RoadPoint(x: (x - 560) * 44, z: (y - 650) * 51, width: width)

const
  TownPaths* = [
    @[referenceRoad(348, 135, 600), referenceRoad(344, 157, 700),
      referenceRoad(373, 204, 680), referenceRoad(390, 245, 730),
      referenceRoad(422, 278, 800), referenceRoad(470, 303, 760),
      referenceRoad(512, 312, 850), referenceRoad(554, 298, 780)],
    @[referenceRoad(554, 298, 780), referenceRoad(540, 329, 920),
      referenceRoad(517, 354, 820), referenceRoad(503, 384, 960),
      referenceRoad(475, 413, 1050), referenceRoad(433, 435, 1100)],
    @[referenceRoad(709, 216, 650), referenceRoad(722, 251, 730),
      referenceRoad(705, 281, 810), referenceRoad(680, 317, 700),
      referenceRoad(674, 350, 780), referenceRoad(687, 389, 830),
      referenceRoad(681, 420, 950), referenceRoad(657, 458, 1150)],
    @[referenceRoad(433, 435, 1100), referenceRoad(474, 448, 1200),
      referenceRoad(514, 470, 1050), referenceRoad(555, 485, 900),
      referenceRoad(604, 476, 950), referenceRoad(657, 458, 1150)],
    @[referenceRoad(326, 342, 700), referenceRoad(350, 376, 830),
      referenceRoad(384, 396, 700), referenceRoad(405, 417, 900),
      referenceRoad(433, 435, 1100)],
    @[referenceRoad(657, 458, 1150), referenceRoad(697, 429, 850),
      referenceRoad(730, 399, 740), referenceRoad(767, 379, 650)],
    @[referenceRoad(433, 435, 1100), referenceRoad(410, 463, 1030),
      referenceRoad(394, 498, 850), referenceRoad(366, 540, 950),
      referenceRoad(351, 579, 900), referenceRoad(337, 622, 780),
      referenceRoad(344, 668, 900), referenceRoad(349, 703, 750),
      referenceRoad(365, 739, 880), referenceRoad(384, 780, 1100)],
    @[referenceRoad(657, 458, 1150), referenceRoad(702, 490, 900),
      referenceRoad(729, 528, 800), referenceRoad(746, 561, 900),
      referenceRoad(742, 603, 820), referenceRoad(758, 643, 1100),
      referenceRoad(749, 685, 900), referenceRoad(733, 719, 780),
      referenceRoad(722, 758, 950), referenceRoad(701, 790, 1000)],
    @[referenceRoad(287, 590, 700), referenceRoad(312, 610, 830),
      referenceRoad(337, 622, 780)],
    @[referenceRoad(841, 628, 700), referenceRoad(802, 652, 820),
      referenceRoad(758, 643, 1100)],
    @[referenceRoad(384, 780, 1100), referenceRoad(423, 801, 880),
      referenceRoad(465, 814, 930), referenceRoad(502, 810, 850),
      referenceRoad(552, 824, 1100), referenceRoad(597, 815, 920),
      referenceRoad(649, 811, 780), referenceRoad(701, 790, 1000)],
    @[referenceRoad(384, 780, 1100), referenceRoad(355, 819, 950),
      referenceRoad(327, 851, 730), referenceRoad(301, 895, 900),
      referenceRoad(278, 930, 800), referenceRoad(267, 969, 750),
      referenceRoad(284, 1008, 920), referenceRoad(330, 1039, 1050),
      referenceRoad(376, 1046, 800), referenceRoad(420, 1038, 920),
      referenceRoad(473, 1047, 1050), referenceRoad(536, 1029, 1100)],
    @[referenceRoad(552, 824, 1100), referenceRoad(527, 850, 900),
      referenceRoad(513, 892, 780), referenceRoad(501, 925, 900),
      referenceRoad(504, 967, 770), referenceRoad(521, 1001, 950),
      referenceRoad(536, 1029, 1100)],
    @[referenceRoad(701, 790, 1000), referenceRoad(692, 829, 950),
      referenceRoad(703, 873, 780), referenceRoad(699, 906, 850),
      referenceRoad(721, 946, 1050), referenceRoad(715, 980, 780),
      referenceRoad(681, 1015, 870), referenceRoad(631, 1037, 940),
      referenceRoad(587, 1044, 1020), referenceRoad(536, 1029, 1100)],
    @[referenceRoad(243, 909, 670), referenceRoad(269, 921, 760),
      referenceRoad(301, 895, 900)],
    @[referenceRoad(825, 960, 690), referenceRoad(790, 970, 850),
      referenceRoad(757, 954, 720), referenceRoad(721, 946, 1050)],
    @[referenceRoad(536, 1029, 1100), referenceRoad(557, 1064, 900),
      referenceRoad(574, 1095, 780), referenceRoad(577, 1129, 850),
      referenceRoad(562, 1168, 1050), referenceRoad(555, 1209, 820),
      referenceRoad(539, 1248, 950), referenceRoad(517, 1281, 1150),
      referenceRoad(483, 1316, 900), referenceRoad(439, 1341, 760),
      referenceRoad(422, 1378, 900), referenceRoad(411, 1405, 750)],
    @[referenceRoad(412, 1262, 670), referenceRoad(450, 1282, 800),
      referenceRoad(482, 1285, 850), referenceRoad(517, 1281, 1150)],
    @[referenceRoad(723, 1275, 680), referenceRoad(690, 1301, 850),
      referenceRoad(650, 1308, 780), referenceRoad(611, 1297, 900),
      referenceRoad(576, 1276, 800), referenceRoad(539, 1248, 950)]
  ]
  HouseApproaches = [
    referenceRoad(554, 298, 780), referenceRoad(326, 342, 700),
    referenceRoad(767, 379, 650), referenceRoad(287, 590, 700),
    referenceRoad(841, 628, 700), referenceRoad(243, 909, 670),
    referenceRoad(825, 960, 690), referenceRoad(412, 1262, 670),
    referenceRoad(723, 1275, 680)
  ]

proc insideTown*(x, z: int32): bool =
  ## Clips the playable meadow to a rounded rectangle around the town.
  let
    cornerX = max(0'i32, abs(x) - 18)
    cornerZ = max(0'i32, abs(z - 3) - 30)
  x >= TownMinX and x <= TownMaxX and
    z >= TownMinZ and z <= TownMaxZ and
    cornerX * cornerX + cornerZ * cornerZ <= 36

proc houseYaw*(slot: int): float32 =
  ## Turns each cottage facade inward by its reference image angle.
  arctan2(HouseTurns[slot][1].float32, HouseTurns[slot][0].float32)

proc houseOffset*(slot: int, x, z: int32): tuple[x, z: int32] =
  ## Rotates tile offsets with fixed point arithmetic for portable replays.
  let
    turn = HouseTurns[slot]
    px = turn[0].int32 * x - turn[1].int32 * z
    pz = turn[1].int32 * x + turn[0].int32 * z
  proc rounded(value: int32): int32 =
    ## Rounds signed thousandths to the closest tile.
    if value < 0:
      -((-value + 500) div 1000)
    else:
      (value + 500) div 1000
  (rounded(px), rounded(pz))

iterator roadSegments(): tuple[a, b: RoadPoint] =
  ## Shares independently traced lanes and oblique cottage approaches.
  for path in TownPaths:
    for i in 1 ..< path.len:
      yield (path[i - 1], path[i])
  for slot, house in TownHouses:
    let offset = houseOffset(slot, 0, 2)
    yield (RoadPoint(
      x: (house[0].int32 + offset.x) * 1000,
      z: (house[1].int32 + offset.z) * 1000,
      width: 650
    ), HouseApproaches[slot])

proc roadClearance*(x, z: float32): float32 =
  ## Measures signed distance from the varying width of the traced lanes.
  result = float32.high
  let point = vec2(x, z)
  for (first, last) in roadSegments():
    let
      a = vec2(first.x.float32, first.z.float32) / 1000
      b = vec2(last.x.float32, last.z.float32) / 1000
      line = b - a
      along = clamp(dot(point - a, line) / dot(line, line), 0'f, 1'f)
      width = (first.width.float32 * (1 - along) +
        last.width.float32 * along) / 1000
    result = min(result, length(point - (a + line * along)) - width)

proc roadContains(x, z, padding: int32): bool =
  ## Tests a point in thousandths against the lanes with extra clearance.
  for (first, last) in roadSegments():
    let
      dx = (last.x - first.x).int64
      dz = (last.z - first.z).int64
      px = x.int64 - first.x
      pz = z.int64 - first.z
      span = dx * dx + dz * dz
      along = clamp(px * dx + pz * dz, 0'i64, span)
      width = first.width.int64 +
        (last.width - first.width).int64 * along div span + padding
      radiusSquared = width * width
    if along == 0:
      if px * px + pz * pz <= radiusSquared:
        return true
    elif along == span:
      let
        ex = px - dx
        ez = pz - dz
      if ex * ex + ez * ez <= radiusSquared:
        return true
    else:
      let cross = px * dz - pz * dx
      if cross * cross <= radiusSquared * span:
        return true

proc townRoad*(x, z: int32): bool =
  ## Rasterizes the same lanes with fixed point math for portable replays.
  roadContains(x * 1000, z * 1000, 450)

proc meadowSpots*(seed: int32): seq[MeadowSpot] =
  ## Shares deterministic ground planting between art and collision geometry.
  for iz in -22 .. 24:
    for ix in -16 .. 16:
      let
        key = abs(ix * 2999 + iz * 7919 + seed.int)
        x = int64(ix * 2000 + key mod 1001 - 500)
        z = int64(iz * 2000 + (key div 7) mod 1001 - 500)
      if not insideTown(int32(x div 1000), int32(z div 1000)) or
        roadContains(x.int32, z.int32, 1250) or
        x * x + z * z < 49_000_000 or
        (x - 2000) * (x - 2000) +
          (z - 15000) * (z - 15000) < 12_250_000 or
        (x - 2000) * (x - 2000) +
          (z + 13000) * (z + 13000) < 9_000_000:
          continue
      var nearHouse = false
      for slot, house in TownHouses:
        let
          dx = (x.int64 - house[0] * 1000) * 7 div 10
          dz = z.int64 - house[1] * 1000
        if dx * dx + dz * dz < 10_240_000:
          nearHouse = true
        for local in HouseGardenOffsets:
          let
            offset = houseOffset(slot, local[0], local[1])
            gx = x - (house[0] + offset.x) * 1000
            gz = z - (house[1] + offset.z) * 1000
          if gx * gx + gz * gz < 2_560_000:
            nearHouse = true
      if not nearHouse:
        result.add MeadowSpot(x: x.int32, z: z.int32, key: key)

proc borderTrees*(seed: int32): seq[BorderTree] =
  ## Scatters a small, reproducible tree border without rows or close pairs.
  var rng = initRng(seed, 0xD1B54A32D192ED03'u64)
  for attempt in 0 ..< 10000:
    let
      x = rng.between(TownMinX + 2, TownMaxX - 2)
      z = rng.between(TownMinZ + 2, TownMaxZ - 2)
    if not insideTown(x, z) or
      (abs(x) < 20 and z > -29 and z < 33) or townRoad(x, z):
        continue
    if z > 26 and abs(x) < 18:
      continue
    var clear = true
    for house in TownHouses:
      let
        dx = x - house[0].int32
        dz = z - house[1].int32
      if dx * dx + dz * dz < 36:
        clear = false
    for tree in result:
      let
        dx = x - tree.x
        dz = z - tree.z
      if dx * dx + dz * dz < 30:
        clear = false
    if not clear:
      continue
    result.add BorderTree(
      x: x, z: z,
      variant: BorderTreeVariants[rng.below(BorderTreeVariants.len.int32)],
      yaw: rng.below(6284).float32 / 1000,
      size: rng.between(70, 112).float32 / 100,
      height: rng.between(85, 125).float32 / 100
    )
    if result.len == BorderTreeCount:
      break

proc groundPlants*(seed: int32): seq[GroundPlant] =
  ## Places trunks and low crowns once for both rendering and navigation.
  result.add GroundPlant(
    variant: 6, radius: 1400, size: 1.5'f * TownLayoutScale, height: 1
  )
  result.add GroundPlant(
    x: 2000, z: -13000, variant: 4, radius: 2125,
    yaw: 0.73'f, size: 1.7'f, height: 1
  )
  for i, offset in [(-1500'i32, 0'i32), (1200'i32, -2000'i32)]:
    result.add GroundPlant(
      x: -7000 + offset[0], z: 15000 + offset[1], radius: 400,
      variant: i, yaw: i.float32, size: 0.58'f, height: 1
    )
  for tree in borderTrees(seed):
    result.add GroundPlant(
      x: tree.x * 1000, z: tree.z * 1000, radius: 500,
      variant: tree.variant, yaw: tree.yaw,
      size: tree.size, height: tree.height
    )
  for spot in meadowSpots(seed):
    let size = 750 + int32(spot.key mod 3) * 120
    if spot.key mod 4 == 0:
      result.add GroundPlant(
        x: spot.x, z: spot.z, radius: size * 5 div 4,
        variant: 3 + spot.key mod 3, yaw: spot.key.float32 * 0.73'f,
        size: size.float32 / 1000, height: 1
      )
  for slot, house in TownHouses:
    # These are the four ground shrubs from the cottage's planting ring.
    for j, offset in [(3400, 0), (-3400, 0), (-1700, -1732),
        (1700, -1732)]:
      let turn = HouseTurns[slot]
      result.add GroundPlant(
        x: int32(house[0] * 1000 +
          (turn[0] * offset[0] - turn[1] * offset[1]) div 1000),
        z: int32(house[1] * 1000 +
          (turn[1] * offset[0] + turn[0] * offset[1]) div 1000),
        radius: 531, variant: 3, yaw: (j * 3).float32 * 0.73'f,
        size: 0.85'f * HouseScale, height: 1
      )

proc makeGardenFences(): seq[GardenFence] =
  ## Builds the same tangent rails as the mesh, leaving both gate openings.
  for ring in [(2'f, 15'f, 3'f, 12), (0'f, 0'f, 6.4'f, 24),
      (2'f, -13'f, 2.6'f, 10)]:
    for i in 0 ..< ring[3]:
      let angle = i.float32 * 2'f * PI.float32 / ring[3].float32
      if abs(cos(angle)) < 0.22'f:
        continue
      let
        x = ring[0] + cos(angle) * ring[2]
        z = ring[1] + sin(angle) * ring[2]
        half = ring[2] * PI.float32 / ring[3].float32
        dx = -sin(angle) * half
        dz = cos(angle) * half
      result.add GardenFence(
        x: int32(round(x * 1000)), z: int32(round(z * 1000)),
        ax: int32(round((x - dx) * 1000)),
        az: int32(round((z - dz) * 1000)),
        bx: int32(round((x + dx) * 1000)),
        bz: int32(round((z + dz) * 1000)),
        radius: int32(round(half / 0.9'f * 100)),
        yaw: angle + PI.float32 / 2, size: half / 0.9'f
      )

const GardenFences* = makeGardenFences()

proc townCameraBounds*(
  target: Vec3, distance, aspect: float32
): tuple[minimum, maximum: Vec2] =
  ## Computes the orthographic camera footprint on level village ground.
  let
    extent = vec2(
      distance * TownCameraScale * aspect,
      distance * TownCameraScale / sin(TownCameraPitch)
    )
    center = vec2(target.x, target.z - target.y / tan(TownCameraPitch))
  (center - extent, center + extent)
