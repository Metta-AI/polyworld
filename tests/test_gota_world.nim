## Gods of the Arena map: dense woods must leave all three lanes open.

import
  polyworld/pathing,
  ../examples/gods_of_the_arena/maps

proc checkLane(stops: openArray[LaneStop]) =
  ## Checks each stop on a battle lane remains reachable through the woods.
  for i in 0 ..< stops.len - 1:
    let
      a = stops[i]
      b = stops[i + 1]
      route = findTilePath(a.layer, a.x, a.z, b.layer, b.x, b.z)
    doAssert route.len > 0,
      "a lane is blocked between " & $a & " and " & $b

proc checkForest(seed: int32) =
  ## Checks repeatable forest chunks and open roads across map seeds.
  let
    first = generateMap(seed)
    second = generateMap(seed)
    ground = layers[GroundLayer]
  doAssert first.hash == second.hash, "the same seed changed its forest"
  doAssert layers.len == 4, "the arena needs ground, two forts, and water"
  for layerIndex, layer in layers:
    doAssert layer.water == (layerIndex == WaterLayer)
  var
    trees = 0
    grouped = 0
    marsh = 0
    waterTiles = 0
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let tile = ground.tiles[z * GridTiles + x]
      doAssert tile.exists, "the arena should have continuous ground"
      let water = layers[WaterLayer].tiles[z * GridTiles + x]
      if water.exists:
        inc waterTiles
        let edge = min(min(x, z), min(GridTiles - 1 - x, GridTiles - 1 - z))
        if edge <= 1:
          doAssert tile.impassable and not isWalkable(GroundLayer, x, z),
            "rocky river mouths must close the playable boundary"
        else:
          doAssert isWalkable(GroundLayer, x, z) and not tile.impassable,
            "the submerged riverbed must remain walkable at " & $(x, z)
        doAssert not isWalkable(WaterLayer, x, z),
          "units must wade on the bed instead of standing on the water"
        doAssert tile.kind == MarshTile,
          "water should stay in the marsh channel"
        var submerged = false
        for corner, height in tile.tops:
          let depth = water.tops[corner].int32 - height.int32
          doAssert depth <= WaterDepthSteps, "the water is deeper than knees"
          if depth > 0:
            submerged = true
        doAssert submerged, "water should only cover a submerged tile"
      if tile.kind == MarshTile:
        inc marsh
        let edge = min(min(x, z), min(GridTiles - 1 - x, GridTiles - 1 - z))
        if edge > 1:
          doAssert not tile.impassable and isWalkable(GroundLayer, x, z),
            "the marsh channel should be walkable inside the arena"
      if tile.kind != TreeTile:
        continue
      inc trees
      doAssert tile.impassable and not isWalkable(GroundLayer, x, z),
        "a tree must block its tile"
      for fort in [RedFortTile, BlueFortTile]:
        doAssert max(abs(x - fort), abs(z - fort)) > FortPlateauRadius,
          "a forest entered a fort clearing"
      var neighbours = 0
      for dz in -2 .. 2:
        for dx in -2 .. 2:
          let
            tx = x + dx
            tz = z + dz
          if tx < 0 or tz < 0 or tx >= GridTiles or tz >= GridTiles:
            continue
          let nearby = ground.tiles[tz * GridTiles + tx].kind
          doAssert nearby != RoadTile, "a forest crowds a battle lane"
          if abs(dx) + abs(dz) == 1 and nearby == TreeTile:
            inc neighbours
      if neighbours >= 2:
        inc grouped
  doAssert trees > 0, "the forest is missing"
  doAssert marsh > GridTiles, "the former river should have marsh terrain"
  doAssert waterTiles > GridTiles, "the shallow river should span the map"
  doAssert grouped * 100 >= trees * 80,
    "seed " & $seed & ": only " & $grouped & "/" & $trees &
      " trees form dense patches"
  for site in AuthoredGroveSites:
    for (centerX, centerZ) in [
        (site.x, site.z),
        (GridTiles - 1 - site.x, GridTiles - 1 - site.z)]:
      var groveTrees = 0
      for dz in -2 .. 2:
        for dx in -2 .. 2:
          if ground.tiles[(centerZ + dz) * GridTiles + centerX + dx].kind ==
              TreeTile:
            inc groveTrees
      doAssert groveTrees >= 3,
        "authored grove has " & $groveTrees & " trees at " &
          $(centerX, centerZ)
  for i in 0 ..< GridTiles:
    for (x, z) in [(i, 0), (i, GridTiles - 1),
        (0, i), (GridTiles - 1, i)]:
      doAssert not isWalkable(GroundLayer, x, z),
        "the perimeter forest and river rocks must close every map edge"
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        mirrorX = GridTiles - 1 - x
        mirrorZ = GridTiles - 1 - z
        mirror = ground.tiles[mirrorZ * GridTiles + mirrorX]
      doAssert (ground.tiles[z * GridTiles + x].kind == TreeTile) ==
        (mirror.kind == TreeTile),
        "forest collision must remain point-symmetric"
  for lane in 0 .. 2:
    for team in 0 .. 1:
      for tier in 0 .. 2:
        let site = TowerSites[lane][team][tier]
        doAssert isWalkable(GroundLayer, site.x, site.z),
          "an authored tower court is not walkable: " & $site
        doAssert ground.tiles[site.z * GridTiles + site.x].kind == StoneTile,
          "a tower should stand on the paved centre of its plaza"
  for lane in LaneRoutes:
    checkLane(lane)

echo "Testing dense forests and clear lanes across seeds"
for seed in 1'i32 .. 50'i32:
  checkForest(seed)
checkForest(1988)
checkForest(2026)

echo "Testing point-symmetric tower compositions"
block:
  for lane in 0 .. 2:
    for team in 0 .. 1:
      for tier in 0 .. 2:
        let
          site = TowerSites[lane][team][tier]
          mirror = TowerSites[2 - lane][1 - team][tier]
        doAssert mirror.x == GridTiles - 1 - site.x
        doAssert mirror.z == GridTiles - 1 - site.z
        doAssert mirror.faceX == GridTiles - 1 - site.faceX
        doAssert mirror.faceZ == GridTiles - 1 - site.faceZ

echo "Testing climbable landmark hills and dry negative quarries"
block:
  discard generateMap(2026)
  let ground = layers[GroundLayer]
  for i, site in LandmarkHillSites:
    let tile = ground.tiles[site[1] * GridTiles + site[0]]
    doAssert tile.kind == LandmarkHillKind,
      "the landmark hill needs its distinct meadow surface"
    doAssert isWalkable(GroundLayer, site[0], site[1]),
      "the landmark hill summit must be walkable"
    for height in tile.tops:
      doAssert height >= 20,
        "the landmark hill should rise clearly above the arena"
    let mouth = LandmarkHillAccessMouths[i]
    doAssert findTilePath(
      GroundLayer, mouth[0], mouth[1],
      GroundLayer, site[0], site[1]).len > 0,
      "the landmark hill must be climbable from its lane-facing approach"
  for i, site in QuarrySites:
    let tile = ground.tiles[site[1] * GridTiles + site[0]]
    doAssert tile.kind == QuarryFloorKind,
      "the quarry needs a readable gravel working floor"
    doAssert isWalkable(GroundLayer, site[0], site[1]),
      "the quarry floor must remain traversable"
    for height in tile.tops:
      doAssert height < 0,
        "the quarry floor should sit below world zero"
    doAssert not layers[WaterLayer].tiles[
      site[1] * GridTiles + site[0]].exists,
      "the quarry should be a dry excavation"
    let mouth = QuarryAccessMouths[i]
    doAssert findTilePath(
      GroundLayer, mouth[0], mouth[1],
      GroundLayer, site[0], site[1]).len > 0,
      "the quarry must remain reachable through its single mouth"

echo "Testing three distinct fort entrances and spaced barracks"
block:
  discard generateMap(2026)
  let ground = layers[GroundLayer]
  proc inGate(team, lane, x, z: int): bool =
    if team == 0:
      case lane
      of 0: x == 31 and z in 19 .. 21
      of 1: (x == 31 and z in 29 .. 31) or
        (z == 31 and x in 29 .. 31)
      else: z == 31 and x in 19 .. 21
    else:
      case lane
      of 0: z == 96 and x in 106 .. 108
      of 1: (x == 96 and z in 96 .. 98) or
        (z == 96 and x in 96 .. 98)
      else: x == 96 and z in 106 .. 108
  for team in 0 .. 1:
    let fort = if team == 0: RedFortTile else: BlueFortTile
    var openWallTiles = 0
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        if max(abs(x - fort), abs(z - fort)) == FortWallRadius and
            isWalkable(GroundLayer, x, z):
          inc openWallTiles
    doAssert openWallTiles == 11,
      "each fort needs two three-wide arches and one five-tile corner gate"
    for gate in FortGateSites[team]:
      doAssert isWalkable(GroundLayer, gate.outsideX, gate.outsideZ)
      doAssert isWalkable(GroundLayer, gate.insideX, gate.insideZ)
      doAssert findTilePath(
        GroundLayer, gate.outsideX, gate.outsideZ,
        GroundLayer, gate.insideX, gate.insideZ).len > 0,
        "a fort entrance is not navigable: " & $gate
    for first in 0 .. 2:
      let site = BarracksSites[team][first]
      doAssert max(abs(site.x - fort), abs(site.z - fort)) < FortWallRadius,
        "a barracks should sit inside its courtyard"
      doAssert max(abs(site.x - fort), abs(site.z - fort)) >= 5,
        "a barracks crowds the central keep"
      doAssert ground.tiles[site.z * GridTiles + site.x].kind ==
        TowerCourtKind,
        "each barracks should have its own paved courtyard apron"
      if team == 0:
        doAssert site.x + site.z > RedFortTile * 2,
          "red barracks should sit on the river-facing side of the nexus"
      else:
        doAssert site.x + site.z < BlueFortTile * 2,
          "blue barracks should sit on the river-facing side of the nexus"
      for second in first + 1 .. 2:
        let other = BarracksSites[team][second]
        doAssert (site.x - other.x) * (site.x - other.x) +
          (site.z - other.z) * (site.z - other.z) >= 100,
          "the courtyard buildings need at least ten tiles of spacing"
  for lane in 0 .. 2:
    let
      red = BarracksSites[0][lane]
      blue = BarracksSites[1][2 - lane]
    doAssert blue.x == GridTiles - 1 - red.x
    doAssert blue.z == GridTiles - 1 - red.z
    doAssert blue.faceX == GridTiles - 1 - red.faceX
    doAssert blue.faceZ == GridTiles - 1 - red.faceZ
    var crossed = [false, false]
    let route = LaneRoutes[lane]
    for stop in 0 ..< route.len - 1:
      let segment = findTilePath(
        route[stop].layer, route[stop].x, route[stop].z,
        route[stop + 1].layer, route[stop + 1].x, route[stop + 1].z)
      for tile in segment:
        for team in 0 .. 1:
          if inGate(team, lane, tile.x.int, tile.z.int):
            crossed[team] = true
    doAssert crossed[0] and crossed[1],
      "each lane must cross its own entrance at both forts"

echo "Testing rocky hill outcrops remain point-symmetric"
block:
  discard generateMap(2026)
  let ground = layers[GroundLayer]
  var outcropTiles = 0
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      if ground.tiles[z * GridTiles + x].kind != HillRockKind:
        continue
      inc outcropTiles
      let mirror = ground.tiles[
        (GridTiles - 1 - z) * GridTiles + GridTiles - 1 - x]
      doAssert mirror.kind == HillRockKind,
        "a rocky hill band lost its mirrored counterpart"
  doAssert outcropTiles > 50,
    "the landmark hills need substantial exposed rock bands"

echo "Testing every lane wades through a continuous shallow river"
block:
  discard generateMap(2026)
  var tiles: seq[PathTile]
  for i in 0 ..< LaneRoutes[1].len - 1:
    let
      a = LaneRoutes[1][i]
      b = LaneRoutes[1][i + 1]
      segment = findTilePath(a.layer, a.x, a.z, b.layer, b.x, b.z)
    doAssert segment.len > 0, "each mid-lane stop must be reachable"
    for tileIndex, tile in segment:
      if tiles.len > 0 and tileIndex == 0:
        continue
      tiles.add tile
  for tile in tiles:
    doAssert tile.layer == GroundLayer,
      "the middle lane should stay on the ground"
  for (centerX, centerZ) in [(107, 21), MidFordCenter, (21, 107)]:
    let
      centre = layers[GroundLayer].tiles[centerZ * GridTiles + centerX]
      water = layers[WaterLayer].tiles[centerZ * GridTiles + centerX]
    doAssert isWalkable(GroundLayer, centerX, centerZ),
      "a shallow crossing should be walkable ground"
    doAssert centre.kind == MarshTile and water.exists,
      "the river surface should continue across every lane"
    for corner, height in centre.tops:
      let depth = water.tops[corner].int32 - height.int32
      doAssert depth > 0 and depth <= WaterDepthSteps,
        "a lane crossing should remain a visibly shallow wade"
  let pulled = smoothPathTiles(tiles)
  doAssert pulled.len >= 2, "the middle lane needs a complete route"
  for tile in pulled:
    doAssert tile.layer == GroundLayer,
      "creeps should follow the middle lane entirely on the ground"

echo "Testing distinct fort materials and flat wall tops"
block:
  discard generateMap(1988)
  for (layerIndex, kind) in [(RedFortLayer, RedFortKind),
      (BlueFortLayer, BlueFortKind)]:
    let
      fort = layers[layerIndex]
      center = FortOuterRadius
      wallHeight = fort.tiles[
        (center - FortLedgeRadius) * fort.width + center].tops[0]
    var
      walls = 0
      ledgeTiles = 0
      crenellations = 0
    for z in 0 ..< fort.depth:
      for x in 0 ..< fort.width:
        let
          tile = fort.tiles[z * fort.width + x]
          ring = max(abs(x - center), abs(z - center))
        if ring == FortOuterRadius:
          doAssert not tile.exists,
            "crenellations should sit on the rampart, not outside it"
        if not tile.exists:
          continue
        doAssert tile.kind == kind, "the fort should use its own stone"
        if ring != FortWallRadius:
          for height in tile.tops:
            doAssert height <= wallHeight,
              "only crenellations should rise above the wall"
        if ring == FortWallRadius:
          inc walls
          if tile.tops[0] > wallHeight:
            inc crenellations
            doAssert not isWalkable(layerIndex, x, z),
              "a crenellation must not become a walkable escape tile"
            for height in tile.tops:
              doAssert height.int32 == wallHeight.int32 +
                FortCrenellationRiseSteps,
                "crenellations should rise evenly above the parapet"
          else:
            doAssert isWalkable(layerIndex, x, z),
              "the outer rampart should remain walkable between merlons"
            for height in tile.tops:
              doAssert height == wallHeight,
                "open wall tops should remain level with the inner route"
        elif ring == FortLedgeRadius:
          inc ledgeTiles
          doAssert isWalkable(layerIndex, x, z),
            "the widened inner ledge should remain walkable"
    doAssert walls == FortWallRadius * 8, "the wall ring should remain complete"
    doAssert ledgeTiles == FortLedgeRadius * 8,
      "the top shelf should be two tiles wide around the fort"
    doAssert crenellations == 20,
      "all four parapets should carry five crenellations"

  let
    redRampart = findTilePath(
      GroundLayer,
      RedFortTile - FortRampSideOffset,
      RedFortTile - 1,
      RedFortLayer,
      FortOuterRadius - FortRampSideOffset,
      FortOuterRadius - FortWallRadius
    )
    blueRampart = findTilePath(
      GroundLayer,
      BlueFortTile + FortRampSideOffset,
      BlueFortTile + 1,
      BlueFortLayer,
      FortOuterRadius + FortRampSideOffset,
      FortOuterRadius + FortWallRadius
    )
  doAssert redRampart.len > 0 and blueRampart.len > 0,
    "both rear-corner ramps must reach the widened shelf"

echo "GOTA world tests passed"
