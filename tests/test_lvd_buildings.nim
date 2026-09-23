import
  std/os,
  jsony, vmath,
  polyworld/[groves, quadterrain],
  ../examples/light_vs_dark/[assets, buildings, content, factions, sim]

type
  Model = object
    name: string
    dimensions: array[3, float32]
  Manifest = object
    models: seq[Model]

let
  manifest = readFile(BuildingModelRoot.parentDir / "manifest.json")
    .fromJson(Manifest)
  art = loadBuildingArt(
    Grove(), textured = false, factions = [Emerald, WetAsphalt]
  )

echo "Checking authored building dimensions and occupied footprints"
for kind in BuildingKind:
  let
    name = BuildingProps[kind]
    size = art.pack.propSize(name)
    footprint = BuildingTable[kind].footprint
  var found = false
  for model in manifest.models:
    if model.name == name:
      found = true
      for axis in 0 ..< 3:
        doAssert abs(size[axis] - model.dimensions[axis]) < 0.001'f,
          name & " lost its authored scale"
  doAssert found, name & " is missing from the source manifest"
  # Allow a centimetre of export rounding at whole-tile edges.
  doAssert size.x * BuildingScale <= footprint.width.float32 + 0.01'f,
    name & " extends outside its occupied width"
  doAssert size.z * BuildingScale <= footprint.depth.float32 + 0.01'f,
    name & " extends outside its occupied depth"
  if kind != GoldMineBuilding:
    for part in art.buildingParts(kind, vec3(0)):
      doAssert part.scale == BuildingScale
  echo name, ": ", size.x * BuildingScale, " x ", size.z * BuildingScale,
    " in ", footprint.width, " x ", footprint.depth, " tiles"

echo "LvD building sizes passed"

echo "Checking construction models, alignment, and progress transitions"
let construction = readFile(ConstructionManifestPath).fromJson(Manifest)
for kind in TownHallBuilding .. BuildableHigh:
  let
    total = BuildingTable[kind].buildTicks
    centre = vec3(20, 3, 30)
    footprint = BuildingTable[kind].footprint
  var structure = Building(
    kind: kind,
    state: BuildingUnderConstruction,
    buildTicks: total,
    buildTotal: total
  )
  for remaining in [total, total div 2 + 1, total div 2, 1'i32]:
    structure.buildTicks = remaining
    let
      stage =
        if remaining > total div 2: FoundationStage
        else: WallsStage
      parts = art.buildingParts(structure, centre)
      name = constructionProp(kind, stage)
    doAssert parts.len == 1 and parts[0].name == name
    let
      part = parts[0]
      size = part.pack.propSize(name)
      offset = part.position - centre
    var found = false
    for model in construction.models:
      if model.name == name:
        found = true
        for axis in 0 ..< 3:
          doAssert abs(size[axis] - model.dimensions[axis]) < 0.001'f
    doAssert found, "Missing construction stage: " & name
    doAssert part.scale == BuildingScale
    doAssert abs(offset.x) + size.x * BuildingScale * 0.5'f <=
      footprint.width.float32 * 0.5'f + 0.01'f
    doAssert abs(offset.z) + size.z * BuildingScale * 0.5'f <=
      footprint.depth.float32 * 0.5'f + 0.01'f
  structure.state = BuildingComplete
  structure.buildTicks = 0
  let completed = art.buildingParts(structure, centre)
  doAssert completed.len == 1
  doAssert completed[0].name == BuildingProps[kind]
  doAssert completed[0].position == centre

# The asymmetric stables need opposite offsets for their two stages.
doAssert art.offsets[StablesBuilding][FoundationStage].x < -0.2'f
doAssert art.offsets[StablesBuilding][WallsStage].x > 0.1'f
echo "LvD construction stages passed"

echo "Checking owner trims across completed and construction models"
for owner in 0'i32 ..< PlayerCount:
  for state in [BuildingComplete, BuildingUnderConstruction]:
    let
      structure = Building(
        kind: TownHallBuilding, owner: owner, state: state
      )
      parts = art.buildingParts(structure, vec3(0))
    doAssert parts[0].pack == art.factionPacks[art.factions[owner]]
    doAssert parts[0].pack != art.pack
doAssert art.buildingPack(-1) == art.pack
doAssert art.buildingPack(0) != art.buildingPack(1)

echo "Checking distinct and repeatable faction assignments"
var seen: set[Faction]
for seed in 1'i64 .. 100:
  let order = factionOrder(seed)
  doAssert order == factionOrder(seed)
  var assigned: set[Faction]
  for faction in order:
    doAssert faction notin assigned
    assigned.incl faction
  doAssert assigned == {Faction.low .. Faction.high}
  seen.incl order[PeterRiver]
doAssert seen == {Faction.low .. Faction.high}
