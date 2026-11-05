import jsony, polyworld/rooms, ../[presets, lobbies]

let config = parseConfig("""{"playerCount":13,"mapSettings":{"layout":"RandomLayout","size":160},"diplomacySettings":{"warGraceSeconds":7}}""")
doAssert config.playerCount == 13
doAssert config.players.len == 13
doAssert config.mapSettings.expansions == 2
doAssert config.diplomacySettings.offerSeconds == 60
doAssert parseConfig(config.toJson()) == config
doAssert defaultConfig().playerCount == 2
for players in 1 .. MaxSeats:
  var modest = LvdConfig(playerCount: players,
    mapSettings: MapSettings(layout: RandomLayout, size: 48,
      expansions: 0, minDistance: 1))
  modest.validate()
for players in [2, 8, 16]:
  discard defaultConfig(players)
for bytes in ["{\"playerCount\":0}", "{\"playerCount\":65}",
    "{\"maxTicks\":0}", "{\"playerCount\":3,\"players\":[{\"name\":\"a\"}]}",
    "{\"diplomacySettings\":{\"warGraceSeconds\":0}}"]:
  var rejected = false
  try: discard parseConfig(bytes)
  except LvdError: rejected = true
  doAssert rejected, bytes
block rejectsOversizedRemoteMapBeforeGeneration:
  var rejected = false
  try:
    discard parseConfig("""{"playerCount":64,"mapSettings":{"layout":"RandomLayout","size":724,"expansions":0,"minDistance":1}}""")
  except LvdError:
    rejected = true
  doAssert rejected, "4096-square terrain with 64 players must fail before allocation"

block budgetBoundaries:
  # 32 * 512^2 is exactly the combined player-cell allowance.
  var boundary = LvdConfig(playerCount: 32,
    mapSettings: MapSettings(layout: RandomLayout, size: 128,
      expansions: 0, minDistance: 1))
  boundary.mapSettings.size = 127
  doAssert generatedMapSide(boundary.seed, 32, boundary.mapSettings) == 508
  boundary.validate()
  boundary.mapSettings.size = 128
  doAssert generatedMapSide(boundary.seed, 32, boundary.mapSettings) == 512
  doAssert 32'i64 * 512 * 512 == MaxConfigPlayerCells
  boundary.validate()
  # Same actual side, one extra player: below the map cap, above player cells.
  boundary.playerCount = 33
  boundary.mapSettings.size = 126
  doAssert generatedMapSide(boundary.seed, 33, boundary.mapSettings) == 512
  var rejected = false
  try: boundary.validate()
  except LvdError: rejected = true
  doAssert rejected

  boundary.playerCount = 1
  boundary.mapSettings.size = 510
  boundary.validate()
  boundary.mapSettings.size = 512
  doAssert 512'i64 * 512 == MaxConfigMapCells
  boundary.validate()
  boundary.mapSettings.size = 513
  rejected = false
  try: boundary.validate()
  except LvdError: rejected = true
  doAssert rejected

for layout in MapLayout:
  let settings = MapSettings(layout: layout, size: 32, expansions: 2,
    minDistance: 180)
  # Both spoke geometry and random placement retries grow well past size=32.
  doAssert generatedMapSide(2026, 5, settings) > 180
  doAssert generatedMapSide(2026, 5, settings) == generateMap(2026, 5, settings).side
  LvdConfig(playerCount: 5, mapSettings: settings).validate()

block automaticGrowthCannotBypassBudget:
  for layout in MapLayout:
    let grown = LvdConfig(playerCount: 5,
      mapSettings: MapSettings(layout: layout, size: 32,
        expansions: 2, minDistance: 300))
    doAssert generatedMapSide(grown.seed, grown.playerCount, grown.mapSettings) > 512
    var rejected = false
    try: discard parseConfig(grown.toJson())
    except LvdError: rejected = true
    doAssert rejected, "Budget must use the grown map, not baseline size"

block previewValidatesBeforeTerrainAllocation:
  let oversized = LvdConfig(playerCount: 64,
    mapSettings: MapSettings(layout: RandomLayout, size: 724,
      expansions: 0, minDistance: 1))
  var rejected = false
  try: discard previewMap(oversized)
  except LvdError as error:
    rejected = error.msg == "Map and roster exceed browser cell budget; reduce map size, spacing, expansions or players"
  doAssert rejected, "Preview must share the config budget before generation"

echo "LvD config passed"
