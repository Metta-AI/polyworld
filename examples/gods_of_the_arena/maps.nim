## Gods of the Arena map generation.
##
## Builds the packed terrain and its walkability from an explicit seed using
## only integers. Writes `pathing.layers` once and returns a `MapData`. The
## simulation never writes terrain. Graphics may sample `surfaceHeight` and
## must not write simulation state.

import
  polyworld/[fixed, hashes, noises, pathing, profiles, rngs]

const
  FordCenters = [(107, 21), (21, 107)]
  MidCausewayCenter* = (64, 64)
  RedFortTile* = 20
  BlueFortTile* = GridTiles - 1 - RedFortTile
  FortPlateauRadius* = 15
  FortOuterRadius* = 12
  FortWallRadius* = 11
  FortLedgeRadius* = FortWallRadius - 1
  FortRampSideOffset* = 7
  GroundLayer* = 0
  RedFortLayer* = 1
  BlueFortLayer* = 2
  WaterLayer* = 3
  RedFortKind* = 6'u32
  BlueFortKind* = 7'u32
  LaneShoulderKind* = 8'u32
  WetBankKind* = 9'u32
  TowerCourtKind* = 10'u32
  LandmarkHillKind* = 11'u32
  QuarryFloorKind* = 12'u32
  QuarryRimKind* = 13'u32
  HillRockKind* = 14'u32
  PerimeterForestMin* = 4
  PerimeterForestMax* = 6
  TerrainAmplitudeSteps = 11'i32
  RiverBedSteps = -16'i32
  WaterDepthSteps* = 3'i32
    ## Caps wading depth at 3/8 of a tile, around a footman's knees.
  WaterLevelSteps = RiverBedSteps + WaterDepthSteps
  FordBedSteps = -4'i32
  FortWallHeightSteps = 36'i32
  FortCrenellationRiseSteps* = 12'i32
  FortGateClearanceSteps = 24'i32
  FortKeepHeightSteps = 11'i32
  ForestNoiseStream = 0xD1B54A32D192ED03'u64
  ForestDetailStream = 0x8CB92BA72F3D8DD7'u64
  HillDetailStream = 0x6A09E667F3BCC909'u64
  ForestRollStream = 0x2545F4914F6CDD1D'u64
  ForestDensityPercent = 90'i64
    ## Chance of a candidate at the forest map's peak.
  ForestPatchRadius = 4'i32
    ## Fills neighbouring tiles into compact, solid patches of woods.

type
  LaneStop* = tuple[layer, x, z: int]
  TowerSite* = tuple[x, z, faceX, faceZ: int]

const
  ## The authored arena skeleton. Rendering, terrain painting, creep routes,
  ## barracks, and tower courts all derive from these same lane stops.
  LaneRoutes*: array[3, seq[LaneStop]] = [
    @[(GroundLayer, 23, 20), (GroundLayer, 34, 20),
      (GroundLayer, 52, 18), (GroundLayer, 72, 18),
      (GroundLayer, 91, 20), (GroundLayer, 104, 28),
      (GroundLayer, 107, 45), (GroundLayer, 107, 78),
      (GroundLayer, 107, 96), (GroundLayer, 107, 104)],
    @[(GroundLayer, 26, 26), (GroundLayer, 33, 33),
      (GroundLayer, 43, 38), (GroundLayer, 53, 51),
      (GroundLayer, 61, 59), (GroundLayer, 63, 63),
      (GroundLayer, 64, 64), (GroundLayer, 66, 68),
      (GroundLayer, 74, 76), (GroundLayer, 84, 89),
      (GroundLayer, 94, 94), (GroundLayer, 101, 101)],
    @[(GroundLayer, 20, 23), (GroundLayer, 20, 34),
      (GroundLayer, 18, 52), (GroundLayer, 18, 72),
      (GroundLayer, 20, 91), (GroundLayer, 28, 104),
      (GroundLayer, 45, 107), (GroundLayer, 78, 107),
      (GroundLayer, 96, 107), (GroundLayer, 104, 107)]
  ]

  ## Explicit tower compositions, indexed by lane, team, then tier
  ## (outer, inner, gate). Point symmetry maps red top to blue bottom and
  ## red bottom to blue top while mid maps onto itself.
  TowerSites*: array[3, array[2, array[3, TowerSite]]] = [
    [
      [(76, 23, 76, 18), (51, 13, 51, 18), (34, 25, 34, 20)],
      [(102, 52, 107, 52), (112, 78, 107, 78), (100, 93, 107, 96)]
    ],
    [
      [(53, 57, 56, 54), (40, 41, 43, 38), (37, 31, 33, 33)],
      [(74, 70, 71, 73), (87, 86, 84, 89), (90, 96, 94, 94)]
    ],
    [
      [(25, 75, 20, 75), (15, 49, 20, 49), (27, 34, 20, 31)],
      [(51, 104, 51, 109), (76, 114, 76, 109), (93, 102, 93, 107)]
    ]
  ]

  ForestHillocks = [
    (43, 30, 8, 6), (30, 43, 8, 6),
    (55, 38, 7, 5), (38, 55, 7, 5),
    (84, 97, 8, 6), (97, 84, 8, 6),
    (72, 89, 7, 5), (89, 72, 7, 5)
  ]
  ## Ten compact grove anchors on one half of the point-symmetric map. Each
  ## is mirrored below, producing twenty deliberate woodland islands in the
  ## broad spaces between lanes without turning those spaces into jungles.
  AuthoredGroveSites*: array[10, tuple[x, z: int]] = [
    (44, 27), (51, 27), (47, 34), (29, 82), (33, 44),
    (42, 50), (33, 51), (49, 31), (27, 47), (38, 49)
  ]
  AuthoredGroveOffsets = [
    (0, 0), (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (1, -1), (-1, 1), (1, 1),
    (-2, 0), (2, 0), (0, -2), (0, 2)
  ]
  LandmarkHillSites* = [(63, 37), (64, 90)]
  LandmarkHillAccessMouths* = [(63, 24), (64, 103)]
  LandmarkHillRadius* = 14
  LandmarkHillTopSteps* = 28'i32
  QuarrySites* = [(37, 63), (90, 64)]
  QuarryAccessMouths* = [(24, 63), (103, 64)]
  QuarryRadius* = 9
  QuarryFloorRadius* = 3
  QuarryFloorSteps* = -20'i32
  HillRockOutcrops* = [
    (55, 36, 58, 42, 2), (71, 37, 68, 43, 2),
    (59, 45, 67, 46, 1),
    (72, 91, 69, 85, 2), (56, 90, 59, 84, 2),
    (68, 82, 60, 81, 1)
  ]
  BarracksSites*: array[2, array[3, TowerSite]] = [
    [(28, 14, 31, 20), (29, 24, 31, 31), (14, 28, 20, 31)],
    [(113, 99, 107, 96), (98, 103, 96, 96),
      (99, 113, 96, 107)]
  ]
  FortGateSites*: array[2, array[3, tuple[
      outsideX, outsideZ, insideX, insideZ: int]]] = [
    [(33, 20, 29, 20), (33, 33, 29, 29), (20, 33, 20, 29)],
    [(107, 94, 107, 98), (94, 94, 98, 98), (94, 107, 98, 107)]
  ]

type MapData* = object
  seed*: int32
  hash*: uint64

proc triangleWave(value, period: int): int32 =
  ## Returns a deterministic signed triangle wave in fixed integer units.
  let
    phase = ((value mod period) + period) mod period
    quarter = period div 4
  if phase < quarter:
    int32(phase * MapBlendScale div quarter)
  elif phase < quarter * 2:
    int32((quarter * 2 - phase) * MapBlendScale div quarter)
  elif phase < quarter * 3:
    -int32((phase - quarter * 2) * MapBlendScale div quarter)
  else:
    -int32((period - phase) * MapBlendScale div quarter)

proc mapFingerprint(): uint64 =
  ## Hashes the packed map and its derived walkability in stable sequence order.
  var hash = HashySeed
  hash.addHashy(layers.len)
  for layerIndex, layer in layers:
    hash.addHashy(layer.originX)
    hash.addHashy(layer.originZ)
    hash.addHashy(layer.width)
    hash.addHashy(layer.depth)
    hash.addHashy(layer.slab)
    hash.addHashy(layer.water)
    for tileIndex, tile in layer.tiles:
      hash.addHashy(uint32(tile.flags))
      hash.addHashy(uint32(tile.kind))
      for value in tile.tops:
        hash.addHashy(value)
      for value in tile.bottoms:
        hash.addHashy(value)
      hash.addHashy(layerWalkable[layerIndex][tileIndex])
  uint64(hash)

var battleMapHash*: uint64

proc generateMap*(seed: int32): MapData {.measure.} =
  ## Builds the authored arena skeleton, then varies only natural detail.
  ## Gameplay geometry remains point-symmetric for every seed.
  var
    laneCore: array[GridTiles * GridTiles, bool]
    laneShoulder: array[GridTiles * GridTiles, bool]
    laneClear: array[GridTiles * GridTiles, bool]
    towerCourts: array[GridTiles * GridTiles, bool]
    towerCourtCenters: array[GridTiles * GridTiles, bool]
    hillockTerrain: array[GridTiles * GridTiles, bool]
    landmarkHill: array[GridTiles * GridTiles, bool]
    hillRock: array[GridTiles * GridTiles, bool]
    quarryTerrain: array[GridTiles * GridTiles, bool]
    quarryFloor: array[GridTiles * GridTiles, bool]
    landmarkAccess: array[GridTiles * GridTiles, bool]
    barracksPads: array[GridTiles * GridTiles, bool]
    causeway: array[GridTiles * GridTiles, bool]

  proc stamp(
      mask: var array[GridTiles * GridTiles, bool],
      cx, cz, radius: int
  ) =
    for dz in -radius .. radius:
      for dx in -radius .. radius:
        if dx * dx + dz * dz > radius * radius:
          continue
        let
          x = cx + dx
          z = cz + dz
        if x >= 0 and x < GridTiles and z >= 0 and z < GridTiles:
          mask[z * GridTiles + x] = true

  proc stroke(
      mask: var array[GridTiles * GridTiles, bool],
      ax, az, bx, bz, radius: int
  ) =
    let steps = max(abs(bx - ax), abs(bz - az)) * 4
    for step in 0 .. steps:
      let
        divisor = max(steps, 1)
        x = ax + int(roundDivision(int64(bx - ax) * step, divisor))
        z = az + int(roundDivision(int64(bz - az) * step, divisor))
      stamp(mask, x, z, radius)

  for route in LaneRoutes:
    for i in 0 ..< route.len - 1:
      let
        a = route[i]
        b = route[i + 1]
      stroke(laneCore, a.x, a.z, b.x, b.z, 2)
      stroke(laneShoulder, a.x, a.z, b.x, b.z, 3)
      stroke(laneClear, a.x, a.z, b.x, b.z, 6)
    # Bends and route beats widen into brief lay-bys instead of giving every
    # road the same mechanically even shoulder.
    for i in 1 ..< route.len - 1:
      stamp(laneShoulder, route[i].x, route[i].z, 4)
  for lane in 0 .. 2:
    for team in 0 .. 1:
      for tier in 0 .. 2:
        let site = TowerSites[lane][team][tier]
        stamp(towerCourts, site.x, site.z, 5)
        stamp(towerCourtCenters, site.x, site.z, 3)
        stamp(laneClear, site.x, site.z, 8)
  stroke(causeway, 57, 57, 71, 71, 2)
  for (x, z, radius, _) in ForestHillocks:
    stamp(hillockTerrain, x, z, radius)
  for (x, z) in LandmarkHillSites:
    stamp(landmarkHill, x, z, LandmarkHillRadius)
  for i, site in LandmarkHillSites:
    let mouth = LandmarkHillAccessMouths[i]
    stroke(landmarkAccess, mouth[0], mouth[1], site[0], site[1], 2)
  for (ax, az, bx, bz, radius) in HillRockOutcrops:
    stroke(hillRock, ax, az, bx, bz, radius)
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      if laneClear[z * GridTiles + x] or landmarkAccess[z * GridTiles + x]:
        hillRock[z * GridTiles + x] = false
      for (hillX, hillZ) in LandmarkHillSites:
        let
          dx = x - hillX
          dz = z - hillZ
        if dx * dx + dz * dz <= 9:
          hillRock[z * GridTiles + x] = false
  for (x, z) in QuarrySites:
    stamp(quarryTerrain, x, z, QuarryRadius)
    stamp(quarryFloor, x, z, QuarryFloorRadius)
  for i, site in QuarrySites:
    let mouth = QuarryAccessMouths[i]
    stroke(landmarkAccess, mouth[0], mouth[1], site[0], site[1], 2)
  for teamSites in BarracksSites:
    for site in teamSites:
      stamp(barracksPads, site.x, site.z, 2)

  proc touches(
      mask: var array[GridTiles * GridTiles, bool], cx, cz: int
  ): bool =
    ## A corner belongs to a mask when any tile sharing it belongs.
    for dz in -1 .. 0:
      for dx in -1 .. 0:
        let
          x = cx + dx
          z = cz + dz
        if x >= 0 and x < GridTiles and z >= 0 and z < GridTiles and
            mask[z * GridTiles + x]:
          return true

  proc ground(cx, cz: int): int32 =
    let value =
      valueNoise(seed, 0xA0761D6478BD642F'u64, cx, cz, 24) * 4 +
      valueNoise(seed, 0xE7037ED1A0B428DB'u64, cx, cz, 12) * 2 +
      valueNoise(seed, 0x8EBC6AF09C88C6E3'u64, cx, cz, 6)
    int32(roundDivision(
      int64(value) * TerrainAmplitudeSteps,
      int64(MapBlendScale) * 7
    ))

  proc laneElevation(cx, cz: int): int32 =
    ## Calm, low-frequency terrain shared by roads and tower courts.
    int32(roundDivision(
      int64(valueNoise(seed, 0x589965CC75374CC3'u64, cx, cz, 42)) * 4,
      MapBlendScale
    ))

  let
    redPlateau = ground(RedFortTile, RedFortTile)
    bluePlateau = ground(BlueFortTile, BlueFortTile)

  proc crossingDistance(cx2, cz2, x, z: int): int32 =
    let
      dx = int64(cx2 - x * 2)
      dz = int64(cz2 - z * 2)
    int32(integerSqrt(dx * dx + dz * dz))

  proc riverBlend(cx2, cz2: int): int32 =
    ## Blends from the river banks to the bed using doubled coordinates.
    let
      wiggle2 = int(triangleWave(cx2 - cz2, 168)) * 8 div MapBlendScale
      axisDistance2 = abs(cx2 + cz2 - GridTiles * 2 - wiggle2)
    var width2 = 27'i32
    for (x, z) in FordCenters:
      let distance = crossingDistance(cx2, cz2, x, z)
      if distance < 28:
        width2 = min(width2, 18'i32 + distance div 3)
    let midDistance = crossingDistance(
      cx2, cz2, MidCausewayCenter[0], MidCausewayCenter[1]
    )
    if midDistance < 30:
      width2 = min(width2, 20'i32 + midDistance div 3)
    let
      ratio = clamp(
        int32(axisDistance2 * MapBlendScale div width2),
        0'i32,
        MapBlendScale
      )
      cubic = int32(roundDivision(
        int64(ratio) * int64(ratio) * int64(ratio),
        int64(MapBlendScale) * int64(MapBlendScale)
      ))
    MapBlendScale - cubic

  proc makeCorner(cx, cz: int): int32 =
    ## Corner height as a pure function of the corner coordinate: tiles that
    ## share a corner always agree, so the surface has no accidental walls.
    result = ground(cx, cz)
    # Roads cross broad, calm land instead of inheriting noisy one-tile
    # bumps. Their low-frequency roll still varies naturally with the seed.
    let laneHeight = laneElevation(cx, cz)
    if touches(laneCore, cx, cz):
      result = blendHeight(result, laneHeight, MapBlendScale)
    elif touches(laneShoulder, cx, cz):
      result = blendHeight(result, laneHeight, MapBlendScale div 2)

    # Four shallow authored terraces give the forest masses a composed
    # silhouette. The paired centres preserve point symmetry.
    for (terraceX, terraceZ) in [(50, 31), (31, 50), (77, 96), (96, 77)]:
      let
        dx = int64(cx - terraceX)
        dz = int64(cz - terraceZ)
        distance = int32(integerSqrt(dx * dx + dz * dz))
      if distance < 16:
        let amount = smoothstep(
          (16'i32 - distance) * MapBlendScale div 8
        )
        result = blendHeight(
          result, ground(terraceX, terraceZ) + 5, amount
        )

    # Smaller hillocks roll around the woodland edges. The lane and tower
    # clear mask wins completely, keeping combat routes calm and readable.
    if not touches(laneClear, cx, cz):
      for (hillX, hillZ, radius, rise) in ForestHillocks:
        let
          dx = int64(cx - hillX)
          dz = int64(cz - hillZ)
          distance = int32(integerSqrt(dx * dx + dz * dz))
          mirrorX = GridTiles - cx
          mirrorZ = GridTiles - cz
          edgeOffset = int32(roundDivision(
            int64(valueNoise(seed, HillDetailStream, cx, cz, 7)) +
              int64(valueNoise(
                seed, HillDetailStream, mirrorX, mirrorZ, 7)),
            MapBlendScale
          ))
          shapedDistance = max(distance + edgeOffset, 0'i32)
        if shapedDistance < radius:
          let amount = smoothstep(
            (int32(radius) - shapedDistance) * MapBlendScale div int32(radius)
          )
          result += int32(roundDivision(
            int64(rise) * amount, MapBlendScale
          ))

      # A broad landmark hill rises through the open inter-lane meadow. Its
      # long falloff stays under the terrain walkability limit, including the
      # final approach to the small, readable summit.
      for (hillX, hillZ) in LandmarkHillSites:
        let
          dx2 = int64(cx * 2 - (hillX * 2 + 1))
          dz2 = int64(cz * 2 - (hillZ * 2 + 1))
          distance2 = int32(integerSqrt(dx2 * dx2 + dz2 * dz2))
        if distance2 < LandmarkHillRadius * 2:
          let amount = smoothstep(
            (LandmarkHillRadius.int32 * 2 - distance2) * MapBlendScale div
              (LandmarkHillRadius.int32 * 2)
          )
          result = blendHeight(result, LandmarkHillTopSteps, amount)

    result = blendHeight(result, RiverBedSteps, riverBlend(cx * 2, cz * 2))
    for (fordX, fordZ) in FordCenters:
      let
        deltaX = int64(cx - fordX)
        deltaZ = int64(cz - fordZ)
        distance = integerSqrt(
          (deltaX * deltaX + deltaZ * deltaZ) *
          int64(MapBlendScale) * int64(MapBlendScale)
        )
        amount = smoothstep(MapBlendScale - int32(distance div 8))
      result = blendHeight(result, FordBedSteps, amount)
    let
      midX = int64(cx - MidCausewayCenter[0])
      midZ = int64(cz - MidCausewayCenter[1])
      midDistance = integerSqrt(
        (midX * midX + midZ * midZ) *
        int64(MapBlendScale) * int64(MapBlendScale)
      )
      midAmount = smoothstep(MapBlendScale - int32(midDistance div 8))
    result = blendHeight(result, FordBedSteps, midAmount)

    # The quarry is a shallow, fully traversable excavation below world zero.
    # A smooth outer cut leads to a flatter working floor rather than a pit
    # with cliff-like collision around its lip.
    if not touches(laneClear, cx, cz):
      for (quarryX, quarryZ) in QuarrySites:
        let
          dx2 = int64(cx * 2 - (quarryX * 2 + 1))
          dz2 = int64(cz * 2 - (quarryZ * 2 + 1))
          distance2 = int32(integerSqrt(dx2 * dx2 + dz2 * dz2))
        if distance2 < QuarryRadius * 2:
          let amount = smoothstep(
            (QuarryRadius.int32 * 2 - distance2) * MapBlendScale div
              ((QuarryRadius - QuarryFloorRadius).int32 * 2)
          )
          result = blendHeight(result, QuarryFloorSteps, amount)

    # Tower courts are deliberately flat combat rooms. Their shoulders fade
    # into the surrounding terrain over two tiles.
    for lane in 0 .. 2:
      for team in 0 .. 1:
        for tier in 0 .. 2:
          let
            site = TowerSites[lane][team][tier]
            distance = max(abs(cx - site.x), abs(cz - site.z))
          if distance <= 7:
            let amount = smoothstep(
              int32(7 - distance) * MapBlendScale div 2
            )
            result = blendHeight(
              result, laneElevation(site.x, site.z), amount
            )
    for (fortTile, plateau) in [
      (RedFortTile, redPlateau), (BlueFortTile, bluePlateau)
    ]:
      let ring = max(abs(cx - fortTile), abs(cz - fortTile))
      if ring <= FortPlateauRadius + 4:
        let amount = smoothstep(
          int32(FortPlateauRadius + 4 - ring) * MapBlendScale div 4
        )
        result = blendHeight(result, plateau, amount)

  var cornerHeights: array[(GridTiles + 1) * (GridTiles + 1), int16]
  for z in 0 .. GridTiles:
    for x in 0 .. GridTiles:
      cornerHeights[z * (GridTiles + 1) + x] = int16(makeCorner(x, z))
  template corner(cx, cz: int): int32 =
    int32(cornerHeights[(cz) * (GridTiles + 1) + (cx)])

  var groundLayer = QuadLayer(
    originX: 0, originZ: 0,
    width: GridTiles, depth: GridTiles,
    slab: false,
    tiles: newSeq[Tile](GridTiles * GridTiles)
  )
  template gtile(x, z: int): var Tile = groundLayer.tiles[(z) * GridTiles + (x)]

  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        tops = [corner(x, z), corner(x + 1, z),
                corner(x, z + 1), corner(x + 1, z + 1)]
        heightSum = tops[0] + tops[1] + tops[2] + tops[3]
        riverAmount = riverBlend(x * 2 + 1, z * 2 + 1)
        nearRiver = riverAmount > 102
        kind =
          if quarryFloor[z * GridTiles + x]:
            QuarryFloorKind
          elif quarryTerrain[z * GridTiles + x]:
            QuarryRimKind
          elif hillRock[z * GridTiles + x]:
            HillRockKind
          elif landmarkHill[z * GridTiles + x]:
            LandmarkHillKind
          elif nearRiver and heightSum < 10:
            MarshTile
          elif riverAmount > MapBlendScale div 5 and heightSum < 28:
            WetBankKind
          elif heightSum > TerrainAmplitudeSteps * 2 and
              not hillockTerrain[z * GridTiles + x]:
            RockTile
          else:
            GrassTile
      gtile(x, z) = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: kind,
        tops: packedHeights(tops)
      )

  for (fortTile, plateau) in [
    (RedFortTile, redPlateau),
    (BlueFortTile, bluePlateau)
  ]:
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let ring = max(abs(x - fortTile), abs(z - fortTile))
        if ring < FortWallRadius:
          gtile(x, z).kind = StoneTile
        elif ring <= FortPlateauRadius:
          gtile(x, z).kind = LaneShoulderKind

  # A compact cobbled apron grounds each barracks in the courtyard. Roads are
  # painted afterward and therefore retain priority through every gate.
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      if barracksPads[z * GridTiles + x]:
        gtile(x, z).kind = TowerCourtKind

  # Broad road cores, gravel shoulders, and circular tower courts all come
  # from the same authored blueprint the simulation follows.
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let fortRing = min(
        max(abs(x - RedFortTile), abs(z - RedFortTile)),
        max(abs(x - BlueFortTile), abs(z - BlueFortTile)))
      if causeway[z * GridTiles + x] and laneCore[z * GridTiles + x] and
          gtile(x, z).kind in [MarshTile, WetBankKind]:
        gtile(x, z).kind = StoneTile
      elif towerCourtCenters[z * GridTiles + x] and fortRing > 1 and
          gtile(x, z).kind notin [MarshTile, WetBankKind] and
          not gtile(x, z).impassable:
        gtile(x, z).kind = StoneTile
      elif towerCourts[z * GridTiles + x] and fortRing > 1 and
          gtile(x, z).kind notin [StoneTile, MarshTile, WetBankKind] and
          not gtile(x, z).impassable:
        gtile(x, z).kind = TowerCourtKind
      elif laneCore[z * GridTiles + x] and fortRing > 1 and
          gtile(x, z).kind notin [StoneTile, MarshTile] and
          not gtile(x, z).impassable:
        gtile(x, z).kind = RoadTile
      elif laneShoulder[z * GridTiles + x] and fortRing > 1 and
          gtile(x, z).kind notin [StoneTile, MarshTile, RoadTile] and
          not gtile(x, z).impassable:
        gtile(x, z).kind = LaneShoulderKind

  proc isGate(fortTile, x, z: int, redSide: bool): bool =
    ## Two cardinal arches serve the outer lanes. A broad L-shaped opening at
    ## the inward corner gives the diagonal middle lane its own third gate.
    if redSide:
      (x == fortTile + FortWallRadius and abs(z - fortTile) <= 1) or
        (z == fortTile + FortWallRadius and abs(x - fortTile) <= 1) or
        (x == fortTile + FortWallRadius and
          z >= fortTile + FortWallRadius - 2) or
        (z == fortTile + FortWallRadius and
          x >= fortTile + FortWallRadius - 2)
    else:
      (x == fortTile - FortWallRadius and abs(z - fortTile) <= 1) or
        (z == fortTile - FortWallRadius and abs(x - fortTile) <= 1) or
        (x == fortTile - FortWallRadius and
          z <= fortTile - FortWallRadius + 2) or
        (z == fortTile - FortWallRadius and
          x <= fortTile - FortWallRadius + 2)

  proc buildFort(
      fortTile: int,
      plateau: int32,
      redSide: bool
  ): QuadLayer =
    ## Builds a fort slab with a walkable rampart, arches, ramps, and dais.
    const FortSize = FortOuterRadius * 2 + 1
    result = QuadLayer(
      originX: fortTile - FortOuterRadius,
      originZ: fortTile - FortOuterRadius,
      width: FortSize,
      depth: FortSize,
      slab: true,
      tiles: newSeq[Tile](FortSize * FortSize)
    )
    template ftile(x, z: int): var Tile =
      result.tiles[
        (z - result.originZ) * result.width + (x - result.originX)
      ]
    let
      wallTop = plateau + FortWallHeightSteps
      keepTop = plateau + FortKeepHeightSteps
      kind =
        if redSide:
          RedFortKind
        else:
          BlueFortKind
      stoneFlags =
        TileExists or TileConnectedEast or TileConnectedSouth

    proc isCrenellation(x, z: int): bool =
      ## Five teeth sit on the outer tile of each parapet, leaving the
      ## widened inner ring as an uninterrupted circulation route.
      let
        dx = x - fortTile
        dz = z - fortTile
        spacedX = dx in [-8, -4, 0, 4, 8]
        spacedZ = dz in [-8, -4, 0, 4, 8]
      (abs(dx) == FortWallRadius and spacedZ) or
        (abs(dz) == FortWallRadius and spacedX)

    for z in result.originZ ..< result.originZ + result.depth:
      for x in result.originX ..< result.originX + result.width:
        let ring = max(abs(x - fortTile), abs(z - fortTile))
        if ring == FortWallRadius:
          let
            crenellated = isCrenellation(x, z)
            bottom =
              if isGate(fortTile, x, z, redSide):
                plateau + FortGateClearanceSteps
              else:
                plateau - 1
            tileTopHeight =
              if crenellated:
                wallTop + FortCrenellationRiseSteps
              else:
                wallTop
          ftile(x, z) = Tile(
            flags:
              if crenellated: stoneFlags or TileImpassable
              else: stoneFlags,
            kind: kind,
            tops: packedHeights([
              tileTopHeight, tileTopHeight, tileTopHeight, tileTopHeight
            ]),
            bottoms: packedHeights([bottom, bottom, bottom, bottom])
          )
          if not isGate(fortTile, x, z, redSide):
            gtile(x, z).impassable = true
        elif ring == FortLedgeRadius:
          # A thin inner overhang widens the top patrol shelf without
          # consuming another ring of courtyard pathing below it.
          ftile(x, z) = Tile(
            flags: stoneFlags,
            kind: kind,
            tops: packedHeights([wallTop, wallTop, wallTop, wallTop]),
            bottoms: packedHeights([
              wallTop - 1, wallTop - 1, wallTop - 1, wallTop - 1
            ])
          )
        elif ring <= 1:
          ftile(x, z) = Tile(
            flags: stoneFlags,
            kind: kind,
            tops: packedHeights([keepTop, keepTop, keepTop, keepTop]),
            bottoms: packedHeights([plateau, plateau, plateau, plateau])
          )
          gtile(x, z).impassable = true

    if redSide:
      let rampX = fortTile - FortRampSideOffset
      for z in fortTile - FortWallRadius + 1 .. fortTile - 2:
        proc rampHeight(cz: int): int32 =
          plateau + int32(roundDivision(
            int64(FortWallHeightSteps) * (fortTile - 1 - cz),
            FortWallRadius - 2
          ))
        ftile(rampX, z) = Tile(
          flags: stoneFlags,
          kind: kind,
          tops: packedHeights([
            rampHeight(z),
            rampHeight(z),
            rampHeight(z + 1),
            rampHeight(z + 1)
          ]),
          bottoms: packedHeights([
            plateau - 1,
            plateau - 1,
            plateau - 1,
            plateau - 1
          ])
        )
        gtile(rampX, z).impassable = true
      ftile(fortTile + 2, fortTile) = Tile(
        flags: stoneFlags,
        kind: kind,
        tops: packedHeights([keepTop, plateau, keepTop, plateau]),
        bottoms: packedHeights([plateau, plateau, plateau, plateau])
      )
      gtile(fortTile + 2, fortTile).impassable = true
    else:
      let rampX = fortTile + FortRampSideOffset
      for z in fortTile + 2 .. fortTile + FortWallRadius - 1:
        proc rampHeight(cz: int): int32 =
          plateau + int32(roundDivision(
            int64(FortWallHeightSteps) * (cz - fortTile - 2),
            FortWallRadius - 2
          ))
        ftile(rampX, z) = Tile(
          flags: stoneFlags,
          kind: kind,
          tops: packedHeights([
            rampHeight(z),
            rampHeight(z),
            rampHeight(z + 1),
            rampHeight(z + 1)
          ]),
          bottoms: packedHeights([
            plateau - 1,
            plateau - 1,
            plateau - 1,
            plateau - 1
          ])
        )
        gtile(rampX, z).impassable = true
      ftile(fortTile - 2, fortTile) = Tile(
        flags: stoneFlags,
        kind: kind,
        tops: packedHeights([plateau, keepTop, plateau, keepTop]),
        bottoms: packedHeights([plateau, plateau, plateau, plateau])
      )
      gtile(fortTile - 2, fortTile).impassable = true

  let
    redFort = buildFort(RedFortTile, redPlateau, true)
    blueFort = buildFort(BlueFortTile, bluePlateau, false)

  proc openForTree(x, z: int): bool =
    ## Keeps each tree clear of lanes, forts, and blocked terrain.
    if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
      return false
    let fortRing = min(
      max(abs(x - RedFortTile), abs(z - RedFortTile)),
      max(abs(x - BlueFortTile), abs(z - BlueFortTile))
    )
    if gtile(x, z).kind != GrassTile or gtile(x, z).impassable or
      laneClear[z * GridTiles + x] or landmarkAccess[z * GridTiles + x] or
      fortRing <= FortPlateauRadius + 4:
        return false
    true

  proc groveBonus(x, z: int): int64 =
    ## Concentrates woods into four recognizable masses between the lanes.
    ## Clear masks still decide actual navigation, so groves cannot crowd a
    ## road or tower court.
    for (groveX, groveZ) in [(50, 31), (31, 50), (77, 96), (96, 77)]:
      let distance = max(abs(x - groveX), abs(z - groveZ))
      if distance < 18:
        result = max(
          result,
          int64(18 - distance) * int64(MapBlendScale) div 18
        )

  # These small authored islands restore woodland rhythm to the enlarged
  # inter-lane spaces. Collision is stamped as an exact rotated pair and
  # still passes through the common lane/base/landmark clearance predicate.
  # Procedural woods are generated afterwards and naturally grow around
  # them, while never consuming this pass's dedicated tree count.
  for site in AuthoredGroveSites:
    for offset in AuthoredGroveOffsets:
      let
        x = site.x + offset[0]
        z = site.z + offset[1]
        mirrorX = GridTiles - 1 - x
        mirrorZ = GridTiles - 1 - z
      if openForTree(x, z) and openForTree(mirrorX, mirrorZ):
        gtile(x, z).kind = TreeTile
        gtile(x, z).impassable = true
        gtile(mirrorX, mirrorZ).kind = TreeTile
        gtile(mirrorX, mirrorZ).impassable = true

  # Noise chooses paired patch centres and their shared density. Mirroring
  # every planted tile keeps forest collision exactly point-symmetric while
  # the seed still changes the natural edge detail.
  var
    forestRng = initRng(seed, ForestRollStream)
    forestTiles: seq[tuple[x, z: int]]
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        mirrorX = GridTiles - 1 - x
        mirrorZ = GridTiles - 1 - z
      if z * GridTiles + x >= mirrorZ * GridTiles + mirrorX or
          not openForTree(x, z) or not openForTree(mirrorX, mirrorZ):
        continue
      let
        firstForest = int64(
          valueNoise(seed, ForestNoiseStream, x, z, 20) * 2 +
          valueNoise(seed, ForestDetailStream, x, z, 10))
        secondForest = int64(
          valueNoise(seed, ForestNoiseStream, mirrorX, mirrorZ, 20) * 2 +
          valueNoise(seed, ForestDetailStream, mirrorX, mirrorZ, 10))
        forest = (firstForest + secondForest) div 2 + groveBonus(x, z)
        roll = int64(forestRng.below(int32(MapBlendScale)))
      if forest <= 0 or roll * 300 >= forest * ForestDensityPercent:
        continue
      forestTiles.add((x, z))

  for i in countdown(forestTiles.high, 1):
    let j = int(forestRng.below(int32(i + 1)))
    swap(forestTiles[i], forestTiles[j])

  var planted = 0
  let treeBudget = forestTiles.len * 2
  proc plantPatch(x, z: int) =
    ## Fills outwards from one forest centre and its rotated partner.
    let radius = int(3 + forestRng.below(ForestPatchRadius - 2))
    for ring in 0 .. radius:
      for dz in -ring .. ring:
        for dx in -ring .. ring:
          if max(abs(dx), abs(dz)) != ring or
            dx * dx + dz * dz > radius * radius:
              continue
          if planted >= treeBudget:
            return
          let
            tx = x + dx
            tz = z + dz
            mirrorX = GridTiles - 1 - tx
            mirrorZ = GridTiles - 1 - tz
          if openForTree(tx, tz) and openForTree(mirrorX, mirrorZ):
            gtile(tx, tz).kind = TreeTile
            gtile(tx, tz).impassable = true
            gtile(mirrorX, mirrorZ).kind = TreeTile
            gtile(mirrorX, mirrorZ).impassable = true
            planted += 2

  for (x, z) in forestTiles:
    if planted >= treeBudget:
      break
    plantPatch(x, z)

  proc perimeterDepth(x, z: int): int =
    ## Gives the boundary a soft, symmetric woodland silhouette rather than
    ## a ruler-straight hedge. Averaging rotated samples preserves gameplay
    ## symmetry for every seed.
    let
      mirrorX = GridTiles - 1 - x
      mirrorZ = GridTiles - 1 - z
      first = valueNoise(seed, ForestDetailStream, x, z, 13)
      second = valueNoise(seed, ForestDetailStream, mirrorX, mirrorZ, 13)
      variation = abs(first + second) div MapBlendScale
    PerimeterForestMin + min(variation, PerimeterForestMax - PerimeterForestMin)

  # A collision-bearing forest skirt makes the arena boundary physical. The
  # two river mouths remain visible, but rocky shallows close their last two
  # rows so players never discover an invisible edge in the water.
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        mirrorX = GridTiles - 1 - x
        mirrorZ = GridTiles - 1 - z
        index = z * GridTiles + x
        mirrorIndex = mirrorZ * GridTiles + mirrorX
        edge = min(min(x, z), min(GridTiles - 1 - x, GridTiles - 1 - z))
      if index > mirrorIndex:
        continue
      if edge >= perimeterDepth(x, z):
        continue
      if gtile(x, z).kind in [MarshTile, WetBankKind] or
          gtile(mirrorX, mirrorZ).kind in [MarshTile, WetBankKind]:
        if edge <= 1:
          gtile(x, z).impassable = true
          gtile(mirrorX, mirrorZ).impassable = true
        continue
      gtile(x, z).kind = TreeTile
      gtile(x, z).impassable = true
      gtile(mirrorX, mirrorZ).kind = TreeTile
      gtile(mirrorX, mirrorZ).impassable = true

  let water = QuadLayer(
    originX: 0,
    originZ: 0,
    width: GridTiles,
    depth: GridTiles,
    slab: true,
    water: true,
    tiles: newSeq[Tile](GridTiles * GridTiles)
  )
  for i, tile in groundLayer.tiles:
    # Cover every submerged corner so the ground clips the shoreline smoothly.
    # Only the authored marsh channel carries water; low corners beneath the
    # perimeter forest remain terrain instead of flooding tree trunks.
    if tile.kind != MarshTile:
      continue
    var submerged = false
    for height in tile.tops:
      if height < WaterLevelSteps:
        submerged = true
    if not submerged:
      continue
    water.tiles[i] = Tile(
      flags: TileExists,
      tops: packedHeights([
        WaterLevelSteps, WaterLevelSteps, WaterLevelSteps, WaterLevelSteps
      ]),
      bottoms: packedHeights([
        RiverBedSteps, RiverBedSteps, RiverBedSteps, RiverBedSteps
      ])
    )

  layers = @[groundLayer, redFort, blueFort, water]
  computeWalkable()
  result.seed = seed
  result.hash = mapFingerprint()
  battleMapHash = result.hash
