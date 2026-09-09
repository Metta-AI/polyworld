import
  std/[os, strutils],
  jsony,
  polyworld/pathing,
  maps

const
  MapFormatVersion* = 2
  MaximumMapBytes = 16 * 1024 * 1024
  MapSurfaceNames* = [
    "grass", "road", "rock", "marsh", "stone", "trees",
    "redFort", "blueFort"
  ]
  MapLayerNames = ["ground", "redFort", "blueFort", "water", "walls"]

type
  GotaMapError* = object of CatchableError
  SavedTile = object
    tops, bottoms: seq[int]
    surface: string
    exists, blocked, east, south: bool
  SavedLayer = object
    name: string
    originX, originZ, width, depth: int
    slab, water, blocking: bool
    tiles: seq[SavedTile]
  SavedMap = object
    format: string
    version, heightUnitsPerTile: int
    name: string
    seed: int64
    authoredBuildings: bool
    buildings: seq[MapBuilding]
    layers: seq[SavedLayer]
  MapDocument* = object
    name*: string
    seed*: int32
    authoredBuildings*: bool
    buildings*: seq[MapBuilding]
    layers*: seq[QuadLayer]

proc fail(message: string) {.noreturn, raises: [GotaMapError].} =
  ## Raises an actionable map format error.
  raise newException(GotaMapError, message)

proc validateDocument*(document: MapDocument) {.raises: [GotaMapError].} =
  ## Checks authored geometry and placements without requiring finished lanes.
  if document.name.len == 0 or document.name.len > 120:
    fail("Map name must contain between 1 and 120 characters.")
  if document.layers.len notin 4 .. 5:
    fail("An arena needs four base layers and an optional walls layer.")
  for i, layer in document.layers:
    if layer == nil:
      fail("Map layer " & $i & " is missing.")
    let
      fort = i in [RedFortLayer, BlueFortLayer]
      size =
        if fort: FortOuterRadius * 2 + 1
        else: GridTiles
      origin =
        if i == RedFortLayer: RedFortTile - FortOuterRadius
        elif i == BlueFortLayer: BlueFortTile - FortOuterRadius
        else: 0
    if layer.width != size or layer.depth != size or
      layer.originX != origin or layer.originZ != origin or
      layer.tiles.len != size * size or
      layer.water != (i == WaterLayer) or layer.slab != (i != GroundLayer) or
      layer.blocking != (i == WallLayer):
        fail("Invalid dimensions or role for " & MapLayerNames[i] & ".")
    for tile in layer.tiles:
      if tile.kind >= MapSurfaceNames.len.uint32 or tile.flags > 15:
        fail("Unknown surface or flags in " & MapLayerNames[i] & ".")
      if i == GroundLayer and not tile.exists:
        fail("The ground layer must cover the whole arena.")
      if tile.kind == TreeTile and tile.exists and not tile.impassable:
        fail("Tree tiles must block movement.")
      for corner in 0 .. 3:
        if tile.tops[corner] < -512 or tile.tops[corner] > 512 or
          tile.bottoms[corner] < -512 or tile.bottoms[corner] > 512:
            fail("Tile heights must be between -512 and 512 eighth-tiles.")
        if layer.slab and tile.exists and
          tile.bottoms[corner] > tile.tops[corner]:
            fail("A slab bottom cannot be higher than its top.")
  if document.buildings.len > 26:
    fail("An arena supports 18 towers, six barracks, and two gods.")
  if not document.authoredBuildings and document.buildings.len > 0:
    fail("Building records require authoredBuildings to be true.")
  for i, building in document.buildings:
    if building.team notin 0 .. 1 or building.lane notin 0 .. 2 or
      building.tier notin 0 .. 2 or building.rotation notin 0 .. 359 or
      building.layer < 0 or building.layer >= document.layers.len:
        fail("Invalid team, lane, tier, rotation, or layer for building.")
    let layer = document.layers[building.layer]
    if layer.water or building.x < layer.originX or
      building.z < layer.originZ or
      building.x >= layer.originX + layer.width or
      building.z >= layer.originZ + layer.depth:
        fail("Building must lie inside its terrain layer.")
    for j in 0 ..< i:
      let other = document.buildings[j]
      if building.kind == other.kind and building.team == other.team and
        (building.kind == GodBuilding or building.lane == other.lane) and
        (building.kind != TowerBuilding or building.tier == other.tier):
          fail("Duplicate building role. Each team/lane/tier is unique.")

proc captureDocument*(name: string, seed: int32): MapDocument =
  ## Copies the current arena so later edits cannot change this snapshot.
  result = MapDocument(name: name, seed: seed)
  result.authoredBuildings = authoredBuildings
  for building in mapBuildings:
    result.buildings.add building
  for layer in layers:
    var copy = QuadLayer(
      originX: layer.originX, originZ: layer.originZ,
      width: layer.width, depth: layer.depth,
      slab: layer.slab, water: layer.water, blocking: layer.blocking,
      tiles: newSeq[Tile](layer.tiles.len)
    )
    for i, tile in layer.tiles:
      copy.tiles[i] = tile
    result.layers.add copy

proc encodeMap*(document: MapDocument): string {.raises: [GotaMapError].} =
  ## Serializes editable tiles with one compact JSON object per tile.
  document.validateDocument()
  var saved = SavedMap(
    format: "gota-map", version: MapFormatVersion,
    heightUnitsPerTile: 8, name: document.name, seed: document.seed,
    authoredBuildings: document.authoredBuildings,
    buildings: document.buildings
  )
  for i, layer in document.layers:
    var target = SavedLayer(
      name: MapLayerNames[i], originX: layer.originX, originZ: layer.originZ,
      width: layer.width, depth: layer.depth,
      slab: layer.slab, water: layer.water, blocking: layer.blocking
    )
    for tile in layer.tiles:
      var cell = SavedTile(
        surface: MapSurfaceNames[tile.kind.int], exists: tile.exists,
        blocked: tile.impassable, east: tile.connectedEast,
        south: tile.connectedSouth
      )
      for corner in 0 .. 3:
        cell.tops.add tile.tops[corner].int
        cell.bottoms.add tile.bottoms[corner].int
      target.tiles.add cell
    saved.layers.add target
  let savedLayers = saved.layers
  saved.layers = @[]
  result = saved.toJson()
  result.setLen(result.len - 2)
  for i, layer in savedLayers:
    if i > 0:
      result.add ","
    result.add "\n"
    result.add layer.toJson().replace("\"tiles\":[", "\"tiles\":[\n")
      .replace("},{", "},\n{")
  result.add "\n]}\n"

proc decodeMap*(source: string): MapDocument {.raises: [GotaMapError].} =
  ## Parses and validates JSON completely before changing live terrain.
  if source.len > MaximumMapBytes:
    fail("Map JSON exceeds the 16 MB limit.")
  var saved: SavedMap
  try:
    saved = source.fromJson(SavedMap)
  except JsonError, ValueError:
    let error = getCurrentException()
    fail("Invalid map JSON: " & error.msg)
  if saved.format != "gota-map" or saved.version notin 1 .. MapFormatVersion:
    fail("Expected gota-map format version 1 or 2.")
  if saved.heightUnitsPerTile != 8:
    fail("Map heights must use 8 units per tile.")
  if saved.seed < int32.low or saved.seed > int32.high:
    fail("Map seed must fit a signed 32-bit integer.")
  if saved.layers.len notin 4 .. 5:
    fail("Expected four or five arena layers.")
  if saved.version == 1 and (saved.layers.len != 4 or
    saved.authoredBuildings or saved.buildings.len > 0):
      fail("Version 1 cannot contain authored buildings or walls.")
  result = MapDocument(
    name: saved.name, seed: int32(saved.seed),
    authoredBuildings: saved.authoredBuildings, buildings: saved.buildings
  )
  for i, sourceLayer in saved.layers:
    if sourceLayer.name != MapLayerNames[i]:
      fail("Expected layer " & MapLayerNames[i] & " at index " & $i & ".")
    var layer = QuadLayer(
      originX: sourceLayer.originX, originZ: sourceLayer.originZ,
      width: sourceLayer.width, depth: sourceLayer.depth,
      slab: sourceLayer.slab, water: sourceLayer.water,
      blocking: sourceLayer.blocking
    )
    for cell in sourceLayer.tiles:
      let kind = MapSurfaceNames.find(cell.surface)
      if kind < 0 or cell.tops.len != 4 or cell.bottoms.len != 4:
        fail("Each tile needs a known surface and four top/bottom heights.")
      var tile = Tile(kind: kind.uint32)
      tile.exists = cell.exists
      tile.impassable = cell.blocked
      tile.connectedEast = cell.east
      tile.connectedSouth = cell.south
      for corner in 0 .. 3:
        if cell.tops[corner] notin -512 .. 512 or
          cell.bottoms[corner] notin -512 .. 512:
            fail("Tile height is outside the supported range.")
        tile.tops[corner] = cell.tops[corner].int16
        tile.bottoms[corner] = cell.bottoms[corner].int16
      layer.tiles.add tile
    result.layers.add layer
  result.validateDocument()

proc readMap*(path: string): MapDocument {.raises: [GotaMapError].} =
  ## Reads a bounded map file and translates filesystem errors.
  try:
    if getFileSize(path) > MaximumMapBytes:
      fail("Map JSON exceeds the 16 MB limit.")
    result = decodeMap(readFile(path))
  except IOError, OSError:
    fail("Could not read map " & path & ": " & getCurrentExceptionMsg())

proc writeMap*(path: string, document: MapDocument) {.raises: [GotaMapError].} =
  ## Replaces a map atomically after writing its complete validated JSON.
  if path.strip().len == 0:
    fail("Choose a JSON file path before saving.")
  let source = encodeMap(document)
  try:
    let directory = path.parentDir
    if directory.len > 0:
      createDir(directory)
    writeFile(path & ".saving", source)
    moveFile(path & ".saving", path)
  except Exception:
    fail("Could not save map " & path & ": " & getCurrentExceptionMsg())

proc installMap*(document: MapDocument): MapData =
  ## Publishes validated authored terrain and rebuilds derived path data.
  document.validateDocument()
  layers = document.layers
  authoredBuildings = document.authoredBuildings
  mapBuildings = document.buildings
  finishMap(document.seed)

proc loadMap*(path: string): MapData =
  ## Loads authored terrain for a match and checks its required routes.
  let
    previousLayers = layers
    previousHash = battleMapHash
    previousBuildings = mapBuildings
    previousAuthored = authoredBuildings
  result = installMap(readMap(path))
  let issues = arenaIssues()
  if issues.len > 0:
    layers = previousLayers
    mapBuildings = previousBuildings
    authoredBuildings = previousAuthored
    computeWalkable()
    battleMapHash = previousHash
    fail("Map is not playable: " & issues.join(" "))
