import
  jsony,
  polyworld/configs,
  generation/configs

export configs

type
  GotaConfigError* = object of CatchableError
  GotaConfig* = MatchConfig[MapConfig]

proc newHook*(config: var GotaConfig) =
  ## Initializes omitted JSON fields with the same settings as a local match.
  config = GotaConfig(seed: 54, mapPreset: defaultConfig())

proc parseConfig*(bytes: string): GotaConfig =
  ## Reads match settings and map controls, keeping omitted map defaults.
  try:
    result = bytes.fromJson(GotaConfig)
    result.mapPreset.validate()
    if result.maxTicks <= 0 or result.spawnIntervalTicks <= 0 or
      result.playerSlot notin 0 .. 10 or result.dayCount < 0:
        raise newException(GotaConfigError,
          "GotA config has invalid duration, spawn interval, or player slot")
    if result.players.len notin [0, 10]:
      raise newException(GotaConfigError,
        "GotA config must provide all ten player names or omit players")
  except JsonError, MapgenError:
    raise newException(GotaConfigError,
      "Invalid GotA config: " & getCurrentExceptionMsg())

proc loadConfig*(path: string): GotaConfig =
  ## Loads one JSON match configuration with its complete map preset.
  try:
    result = parseConfig(readFile(path))
  except IOError, OSError:
    raise newException(GotaConfigError,
      "Cannot read GotA config: " & getCurrentExceptionMsg())
