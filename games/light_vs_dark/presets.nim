## Public, source-free match settings for local and relay games.
import jsony, polyworld/[configs, rooms], maps, diplomacies
export configs, maps, diplomacies

const
  MaxConfigMapCells* = 512'i64 * 512
    ## Bounds shared terrain, pathing, preview and simulation cell arrays.
    ## At this cap: 6 MiB of Tile geometry, 1.5 MiB of map cell arrays,
    ## and 2 MiB of world blocker/occupancy arrays (excluding scratch/copies).
  MaxConfigPlayerCells* = 8'i64 * 1024 * 1024
    ## visibleStamp (uint32) + explored (uint8): at most 40 MiB per world.
    ## The separate map cap leaves browser headroom for rendering and policies;
    ## these are cell-array bounds, not a cap on total process/GPU memory.

type LvdConfig* = object
  seed*: int32 = 2026
  maxTicks*: int32 = DefaultDurationTicks
  playerCount*: int = 2
  players*: seq[PlayerConfig]
  playerSlot*: int32
  mapSettings*: MapSettings
  diplomacySettings*: DiplomacySettings

proc newHook*(settings: var MapSettings) = settings = MapSettings()
proc newHook*(settings: var DiplomacySettings) = settings = DiplomacySettings()
proc newHook*(config: var LvdConfig) = config = LvdConfig()

proc validate*(config: LvdConfig) =
  if config.playerCount notin 1 .. MaxSeats:
    raise newException(LvdError, "Player count exceeds relay seat capacity")
  if config.maxTicks notin 1'i32 .. SharedTickRate * 60 * 60 or
    config.playerSlot < 0 or config.playerSlot > config.playerCount:
      raise newException(LvdError, "Invalid match duration or human slot")
  if config.players.len notin [0, config.playerCount]:
    raise newException(LvdError, "Player names must match the complete roster")
  config.mapSettings.validate(config.playerCount)
  config.diplomacySettings.validate()
  let
    side = int64(generatedMapSide(config.seed, config.playerCount, config.mapSettings))
    cells = side * side
  if cells > MaxConfigMapCells or
    cells * int64(config.playerCount) > MaxConfigPlayerCells:
    raise newException(LvdError,
      "Map and roster exceed browser cell budget; reduce map size, spacing, expansions or players")

proc defaultConfig*(playerCount = 2): LvdConfig =
  result = LvdConfig(playerCount: playerCount)
  result.validate()
  result.players = unnamedPlayers(playerCount)

proc parseConfig*(bytes: string): LvdConfig =
  try:
    result = bytes.fromJson(LvdConfig)
    result.validate()
    if result.players.len == 0:
      result.players = unnamedPlayers(result.playerCount)
  except JsonError:
    raise newException(LvdError, "Invalid LvD config: " & getCurrentExceptionMsg())

proc gameConfig*(config: LvdConfig): GameConfig =
  GameConfig(seed: config.seed, maxTicks: config.maxTicks,
    players: (if config.players.len == 0: unnamedPlayers(config.playerCount)
      else: config.players), playerSlot: config.playerSlot)
