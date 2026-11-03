import std/[math, strutils]

const
  DefaultMapSize* = 116
  MinimumMapSize* = 64
  MaximumMapSize* = 256

type
  MapgenError* = object of CatchableError
  MapConfig* = object
    mapSize*: int = DefaultMapSize
    seed*: int = 54
    lakeCrossings*: int = 4
    jungleRoads*: int = 32
    highSize*: float32 = 511
    castleSize*: float32 = 295
    roadWidth*: float32 = 52.7'f
    roadWobble*: float32 = 73
    lakeWidth*: float32 = 80
    lakeWobble*: float32 = 30
    campRadius*: float32 = 36
    campScatter*: float32 = 35
    stemLength*: float32 = 50
    campsTouchRoads*: bool = true

proc defaultConfig*(): MapConfig {.raises: [].} =
  ## Returns the saved seed and controls for the reference map.
  MapConfig()

proc newHook*(config: var MapConfig) =
  ## Keeps saved controls when a JSON preset overrides only selected fields.
  config = defaultConfig()

proc renameHook*(value: var MapConfig, fieldName: var string) =
  ## Accepts snake case map controls in hosted game configurations.
  var
    name: string
    upper = false
  for character in fieldName:
    if character == '_':
      upper = true
    else:
      name.add(if upper: character.toUpperAscii else: character)
      upper = false
  fieldName = name

proc validate*(config: MapConfig) =
  ## Rejects unsupported controls before generating terrain or reading replays.
  if config.mapSize < MinimumMapSize or config.mapSize > MaximumMapSize or
    config.mapSize mod 2 != 0:
      raise newException(MapgenError,
        "Map size must be an even number of tiles between " &
        $MinimumMapSize & " and " & $MaximumMapSize)
  for control in [
    ("highSize", config.highSize, 450'f, 570'f),
    ("castleSize", config.castleSize, 210'f, 500'f),
    ("roadWidth", config.roadWidth, 26'f, 62'f),
    ("roadWobble", config.roadWobble, 0'f, 80'f),
    ("lakeWidth", config.lakeWidth, 42'f, 120'f),
    ("lakeWobble", config.lakeWobble, 0'f, 80'f),
    ("campRadius", config.campRadius, 20'f, 40'f),
    ("campScatter", config.campScatter, 0'f, 60'f),
    ("stemLength", config.stemLength, 30'f, 80'f)
  ]:
    if control[1].classify in {fcNan, fcInf, fcNegInf} or
      control[1] < control[2] or control[1] > control[3]:
        raise newException(MapgenError, "Map preset " & control[0] &
          " must be between " & $control[2] & " and " & $control[3])
  if config.seed < int32.low.int or config.seed > int32.high.int:
    raise newException(MapgenError, "Map preset seed must fit int32")
  if config.jungleRoads notin 18 .. 50 or config.jungleRoads mod 2 != 0:
    raise newException(MapgenError,
      "Map preset jungleRoads must be an even number from 18 to 50")
  if config.lakeCrossings notin 0 .. 6 or config.lakeCrossings mod 2 != 0:
    raise newException(MapgenError,
      "Map preset lakeCrossings must be an even number from 0 to 6")
