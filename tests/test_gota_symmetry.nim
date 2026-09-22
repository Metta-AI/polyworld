import
  std/strformat,
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

proc opposite(layer: int32): int32 =
  ## Exchanges the two fort layers under a half turn.
  case layer
  of RedFortLayer: BlueFortLayer
  of BlueFortLayer: RedFortLayer
  else: layer

proc rotated(point: WorldPoint): WorldPoint =
  ## Rotates a world point by exactly 180 degrees around the arena center.
  WorldPoint(x: -point.x, y: point.y, z: -point.z)

proc checkMap(game: Game) =
  ## Exhaustively checks terrain, navigation links, occupancy, and vision.
  let size = mapTiles()
  for hero in game.world.heroes:
    var found = false
    for other in game.world.heroes:
      if other.team != hero.team and other.position == hero.position.rotated:
        doAssert hero.facing.x == -other.facing.x
        doAssert hero.facing.z == -other.facing.z
        found = true
    doAssert found, &"Unpaired hero spawn: {hero.id}, {hero.position}."
  for building in game.world.buildings:
    var found = false
    for other in game.world.buildings:
      if other.team != building.team and
        other.position == building.position.rotated:
          doAssert other.kind == building.kind
          doAssert other.tier == building.tier
          doAssert other.hp == building.hp
          found = true
    doAssert found, &"Unpaired structure: {building.id}, {building.position}."
  for layer, floor in layers:
    let otherLayer = opposite(layer.int32).int
    for z in 0 ..< size:
      for x in 0 ..< size:
        let
          first = floor.tiles[z * size + x]
          otherX = size - 1 - x
          otherZ = size - 1 - z
          second = layers[otherLayer].tiles[otherZ * size + otherX]
          label = &"Layer {layer}, cell {x}, {z}."
        doAssert first.exists == second.exists, label
        doAssert (first.kind in [TreeTile, ArenaRockKind]) ==
          (second.kind in [TreeTile, ArenaRockKind]), label
        if first.exists:
          for corner in 0 .. 3:
            doAssert first.tops[corner] == second.tops[3 - corner], label
        doAssert isWalkable(layer, x, z) ==
          isWalkable(otherLayer, otherX, otherZ), label
        doAssert navigationOpen(layer, x, z) ==
          navigationOpen(otherLayer, otherX, otherZ), label
        for direction in 0 .. 3:
          let
            a = edgeLink(layer, x, z, direction)
            b = edgeLink(otherLayer, otherX, otherZ, (direction + 2) mod 4)
          doAssert a.open == b.open, label
          if a.open:
            doAssert opposite(a.layer.int32) == b.layer.int32, label
            doAssert a.x + b.x == size - 1, label
            doAssert a.z + b.z == size - 1, label
  for i in 0 ..< size * size:
    doAssert game.world.teamVisible[0][i] ==
      game.world.teamVisible[1][size * size - 1 - i],
      &"Visibility mismatch at {i mod size}, {i div size}."

proc checkSpawns(game: Game) =
  ## Compares each barracks' creeps with its rotated barracks and unit slot.
  var
    sites: seq[Building]
    positions: seq[WorldPoint]
    facings: seq[Heading]
  for building in game.world.buildings:
    if building.kind == BarracksBuilding:
      sites.add building
  game.world.heroTurnTicks = 1
  game.tickWorld(proc() =
    ## Captures the newly spawned units before any movement or collision.
    for footman in game.world.footmen:
      positions.add footman.position
      facings.add footman.facing
  )
  doAssert positions.len == sites.len * CreepsPerBarracks
  for i, site in sites:
    var partner = -1
    for j, other in sites:
      if other.position == site.position.rotated:
        doAssert other.team != site.team
        partner = j
    doAssert partner >= 0
    for unit in 0 ..< CreepsPerBarracks:
      let
        first = i * CreepsPerBarracks + unit
        second = partner * CreepsPerBarracks + unit
        label = &"Barracks {i}, unit {unit}."
      doAssert positions[first].rotated == positions[second], label
      doAssert facings[first].x == -facings[second].x, label
      doAssert facings[first].z == -facings[second].z, label
      doAssert facings[first].x != 0 or facings[first].z != 0, label

proc checkPaths(game: Game) =
  ## Compares pulled hero routes, including requests for blocked destinations.
  let
    red = game.world.heroes[0]
    blue = game.world.heroes[5]
  blue.place(red.position.rotated)
  var checked = 0
  for z in countup(3, mapTiles() - 4, 11):
    for x in countup(3, mapTiles() - 4, 11):
      let
        redAccepted = game.world.applyWalkTo(red.id, x.int32, z.int32)
        blueAccepted = game.world.applyWalkTo(
          blue.id,
          mapTiles().int32 - 1 - x.int32,
          mapTiles().int32 - 1 - z.int32
        )
        label = &"Destination {x}, {z}."
      doAssert redAccepted == blueAccepted, label
      if not redAccepted:
        continue
      doAssert red.movePath.len == blue.movePath.len, label
      for i, point in red.movePath:
        doAssert point.rotated == blue.movePath[i], label
        doAssert red.movePathLayers[i].opposite == blue.movePathLayers[i], label
      inc checked
  doAssert checked > 0
  echo "Mirrored hero destinations checked: ", checked

proc checkPortals(game: Game) =
  ## Checks portal landing cells and tower selection on mirrored requests.
  for z in countup(2, mapTiles() - 3, 7):
    for x in countup(2, mapTiles() - 3, 7):
      let
        cell = pathPoint(GroundLayer, x, z)
        aim = WorldPoint(
          x: cell.x * (WorldScale div PathUnitsPerTile),
          y: cell.y * (WorldScale div PathUnitsPerTile),
          z: cell.z * (WorldScale div PathUnitsPerTile)
        )
      var
        first, second: WorldPoint
        firstTower, secondTower: int32
      let
        red = game.world.portalLanding(RedTeam, aim, first, firstTower)
        blue = game.world.portalLanding(
          BlueTeam, aim.rotated, second, secondTower
        )
      doAssert red == blue
      if red:
        doAssert first.rotated == second,
          &"Portal aim {x}, {z}: {first} versus {second}."
        var firstPosition, secondPosition: WorldPoint
        for building in game.world.buildings:
          if building.id == firstTower:
            firstPosition = building.position
          if building.id == secondTower:
            secondPosition = building.position
        doAssert firstPosition.rotated == secondPosition

echo "Testing exact arena rotation, wave spawns, and navigation"
for (size, seed) in [(116, 54), (64, 54), (116, 0), (116, 55),
  (128, 54), (256, 54)]:
  var preset = defaultConfig()
  preset.mapSize = size
  preset.seed = seed
  echo "Map size ", size, ", seed ", seed
  let game = newGame(generateMap(7, preset), 100_000, 10, false,
    ReplayData(), drafting = false)
  game.checkMap()
  game.checkSpawns()
  game.checkPaths()
  game.checkPortals()
