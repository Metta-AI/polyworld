## Gods of the Arena action-only replay format and playback cursor.

import
  std/os,
  polyworld/[tapes, metrics],
  content, presets

export presets

const
  ReplayGame* = "gods_of_the_arena"
  ReplayFormatVersion* = 5'u16
  LegacyGameVersion* = 16'u16
  ActionGameVersion* = 17'u16
  MetricsGameVersion* = 18'u16
  TelemetryGameVersion* = 19'u16
  CombatGameVersion* = 20'u16
  ArenaGameVersion* = 22'u16
  PreviousMapGameVersion* = 23'u16
  InitialArenaGameVersion* = 24'u16
  CryptArenaGameVersion* = 25'u16
  PresetGameVersion* = 26'u16
  ReplayGameVersion* = 29'u16
  ActionWalkTo* = 1'u8
  ActionAttackTarget* = 2'u8
  ActionBuyItem* = 3'u8
  ActionUseItem* = 4'u8
  ActionAttackMove* = 5'u8
  ActionCastTarget* = 6'u8
  ActionCastPoint* = 10'u8
  ActionManualSpells* = 14'u8
  MaxReplayBytes* = 64 * 1024 * 1024
  MaxReplayActions* = 10_000_000
  MaxReplayHashes* = 100_000_000
  MaxReplayHeroes* = 256

type
  StoredMapConfig = object
    seed: int
    lakeCrossings: int
    jungleRoads: int
    highSize: float32
    castleSize: float32
    roadWidth: float32
    roadWobble: float32
    lakeWidth: float32
    lakeWobble: float32
    campRadius: float32
    campScatter: float32
    stemLength: float32
    campsTouchRoads: bool
  ReplayHero* = object
    id*: int32
    team*: uint8
    slot*: uint8
    lane*: uint8
    class*: uint8

  Setup* = object
    mapSeed*: int32
    mapHash*: uint64
    tickRate*: uint16
    gridTiles*: uint16
    spawnIntervalTicks*: uint32
    maximumTicks*: uint32
    heroes*: seq[ReplayHero]

  ReplayAction* = object
    tick*: uint32
    heroId*: int32
    kind*: uint8
    first*: int32
    second*: int32

  ReplayHeader* = TapeHeader[Setup]
  LegacyReplayData = ActionTape[Setup, ReplayAction]
  PreviousReplayData = ActionTape[Setup, ReplayAction, LegacyReplayMetrics]
  HistoricalReplayData = ActionTape[Setup, ReplayAction, ReplayMetrics]
  StoredReplayData = ActionTape[
    Setup, ReplayAction, ReplayMetrics, MatchConfig[StoredMapConfig]
  ]
  ReplayData* = ActionTape[Setup, ReplayAction, ReplayMetrics, GotaConfig]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction, ReplayMetrics, GotaConfig]
  ReplayPlayer* = TapePlayer[Setup, ReplayAction, ReplayMetrics, GotaConfig]

proc storedPreset(preset: MapConfig): StoredMapConfig {.raises: [].} =
  ## Preserves the version 26 binary layout when an older replay is saved.
  StoredMapConfig(
    seed: preset.seed,
    lakeCrossings: preset.lakeCrossings,
    jungleRoads: preset.jungleRoads,
    highSize: preset.highSize,
    castleSize: preset.castleSize,
    roadWidth: preset.roadWidth,
    roadWobble: preset.roadWobble,
    lakeWidth: preset.lakeWidth,
    lakeWobble: preset.lakeWobble,
    campRadius: preset.campRadius,
    campScatter: preset.campScatter,
    stemLength: preset.stemLength,
    campsTouchRoads: preset.campsTouchRoads
  )

proc restorePreset(preset: StoredMapConfig): MapConfig {.raises: [].} =
  ## Restores the implicit 128 tile size of version 26 map presets.
  MapConfig(
    mapSize: 128,
    seed: preset.seed,
    lakeCrossings: preset.lakeCrossings,
    jungleRoads: preset.jungleRoads,
    highSize: preset.highSize,
    castleSize: preset.castleSize,
    roadWidth: preset.roadWidth,
    roadWobble: preset.roadWobble,
    lakeWidth: preset.lakeWidth,
    lakeWobble: preset.lakeWobble,
    campRadius: preset.campRadius,
    campScatter: preset.campScatter,
    stemLength: preset.stemLength,
    campsTouchRoads: preset.campsTouchRoads
  )

proc historicalConfig(): MapConfig {.raises: [].} =
  ## Restores omitted map controls for recordings before configurable maps.
  result = defaultConfig()
  result.mapSize = 128
  result.roadWidth = 62

proc fail(message: string) {.noreturn.} =
  ## Raises one Gods of the Arena replay error.
  raise newException(ReplayError, message)

proc initReplayData*(
    setup: Setup, preset = defaultConfig()
): ReplayData =
  ## Creates a replay containing the match setup, config, and action tape.
  result.header = initActionTape[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  ).header
  result.config = GotaConfig(
    seed: setup.mapSeed,
    maxTicks: int32(setup.maximumTicks),
    players: unnamedPlayers(HeroClassCount),
    spawnIntervalTicks: int32(setup.spawnIntervalTicks),
    mapPreset: preset
  )
  result.config.mapPreset.mapSize = setup.gridTiles.int

proc initReplayRecorder*(
    setup: Setup, preset = defaultConfig()
): ReplayRecorder =
  ## Creates an in-memory recorder owning the complete replay data.
  ReplayRecorder(data: initReplayData(setup, preset))

proc record*(recorder: ReplayRecorder, action: ReplayAction) =
  ## Appends one bot action in deterministic tick order.
  if recorder == nil:
    return
  if action.kind != ActionWalkTo and
      action.kind != ActionAttackTarget and
      action.kind != ActionBuyItem and
      action.kind != ActionUseItem and
      action.kind != ActionAttackMove and
      action.kind notin ActionCastTarget .. ActionManualSpells:
    fail("replay action kind is invalid")
  recorder.data.actions.appendAction(action, MaxReplayActions)

proc recordCast*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId, slot, first, second: int32,
    ground: bool
) =
  ## Records a spell slot and object or ground aim in the existing payload.
  if slot < 0 or slot > HeroAbilitySlot.high.ord:
    fail("spell slot is invalid")
  recorder.record ReplayAction(
    tick: tick, heroId: heroId,
    kind: (if ground: ActionCastPoint else: ActionCastTarget) + uint8(slot),
    first: first, second: second
  )

proc recordWalkTo*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    x,
    y: int32
) =
  ## Records one walkTo action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionWalkTo,
    first: x,
    second: y
  )

proc recordAttackMove*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    x,
    y: int32
) =
  ## Records one attack-move action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionAttackMove,
    first: x,
    second: y
  )

proc recordAttackTarget*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    targetId: int32
) =
  ## Records one attackTarget action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionAttackTarget,
    first: targetId
  )

proc recordBuyItem*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    itemId: int32
) =
  ## Records one buyItem action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionBuyItem,
    first: itemId
  )

proc recordUseItem*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    slot: int32
) =
  ## Records one useItem action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionUseItem,
    first: slot
  )

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  ## Appends the canonical simulation hash for one completed tick.
  recordHash(recorder, hash, MaxReplayHashes)

proc validate*(data: ReplayData) =
  ## Validates versions, setup bounds, actor IDs, and action ordering.
  data.config.validateConfig(HeroClassCount)
  if data.header.gameVersion >= PresetGameVersion:
    try:
      data.config.mapPreset.validate()
    except MapgenError as error:
      fail(error.msg)
  if data.config.seed != data.header.setup.mapSeed or
    data.config.maxTicks != int32(data.header.setup.maximumTicks):
      fail("replay configuration does not match its simulation setup")
  if data.config.spawnIntervalTicks !=
    int32(data.header.setup.spawnIntervalTicks):
      fail("replay configuration has a different spawn interval")
  data.header.requireTapeVersion(
    ReplayFormatVersion,
    data.header.gameVersion
  )
  if data.header.gameVersion notin {
    LegacyGameVersion, ActionGameVersion, MetricsGameVersion,
    TelemetryGameVersion, CombatGameVersion, ArenaGameVersion,
    PreviousMapGameVersion, InitialArenaGameVersion, CryptArenaGameVersion,
    PresetGameVersion, ReplayGameVersion
  }:
    fail("unsupported replay game version")
  let setup = data.header.setup
  if setup.tickRate != uint16(TickRate):
    fail("replay setup has an unsupported tick rate")
  let mapSize =
    if data.header.gameVersion >= PresetGameVersion:
      data.config.mapPreset.mapSize
    else:
      128
  if setup.gridTiles.int != mapSize:
    fail("replay setup has an unsupported map size")
  if setup.mapHash == 0:
    fail("replay setup has no deterministic map fingerprint")
  if setup.spawnIntervalTicks == 0 or setup.maximumTicks == 0:
    fail("replay setup has an invalid duration")
  if setup.spawnIntervalTicks > uint32(int32.high):
    fail("replay setup spawn interval is too large")
  if setup.maximumTicks > uint32(MaxReplayHashes):
    fail("replay setup duration exceeds the hash limit")
  if setup.heroes.len == 0 or setup.heroes.len > MaxReplayHeroes:
    fail("replay setup has an invalid hero count")
  if data.actions.len > MaxReplayActions:
    fail("replay action limit exceeded")
  if data.hashes.len > MaxReplayHashes:
    fail("replay hash limit exceeded")
  if data.hashes.len > int(setup.maximumTicks):
    fail("replay hashes exceed the configured duration")
  for i, hero in setup.heroes:
    if hero.team > 1 or hero.lane > 2 or
        hero.class > uint8(HeroClass.high.ord):
      fail("replay setup has invalid hero metadata")
    for j in 0 ..< i:
      if setup.heroes[j].id == hero.id:
        fail("replay setup contains a duplicate hero ID")
  var lastTick = 0'u32
  for i, action in data.actions:
    if action.tick > uint32(data.hashes.len):
      fail("replay action exceeds the recorded duration")
    if i > 0 and action.tick < lastTick:
      fail("replay actions move backward in time")
    if setup.maximumTicks > 0 and action.tick > setup.maximumTicks:
      fail("replay action exceeds the configured duration")
    if action.kind != ActionWalkTo and
        action.kind != ActionAttackTarget and
        action.kind != ActionBuyItem and
        action.kind != ActionUseItem and
        action.kind != ActionAttackMove and
        action.kind notin ActionCastTarget .. ActionManualSpells:
      fail("replay action kind is invalid")
    if data.header.gameVersion <= CombatGameVersion and
      action.kind >= ActionCastTarget:
        fail("historical replay contains a new spell action")
    var knownHero = false
    for hero in setup.heroes:
      if hero.id == action.heroId:
        knownHero = true
        break
    if not knownHero:
      fail("replay action references an unknown hero")
    lastTick = action.tick
  try:
    data.metrics.validate(
      data.config.players.len,
      int32(data.header.setup.tickRate),
      data.hashes.len
    )
  except MetricsError as error:
    fail(error.msg)

proc encodeReplay*(data: ReplayData): string =
  ## Encodes the action tape and its CPU telemetry in one payload.
  data.validate()
  if data.header.gameVersion in {LegacyGameVersion, ActionGameVersion}:
    if data.metrics != ReplayMetrics():
      fail("old replay versions cannot store CPU telemetry")
    let legacy = LegacyReplayData(
      header: data.header,
      config: data.config.gameConfig(),
      actions: data.actions,
      hashes: data.hashes
    )
    return encodeReplayFile(
      ReplayGame,
      data.header.gameVersion,
      legacy,
      MaxReplayBytes
    )
  if data.header.gameVersion == PresetGameVersion:
    if data.config.mapPreset.mapSize != 128:
      fail("version 26 replays require a 128 tile map")
    let stored = StoredReplayData(
      header: data.header,
      config: data.config.gameConfig().withMapPreset(
        storedPreset(data.config.mapPreset)
      ),
      actions: data.actions,
      hashes: data.hashes,
      metrics: data.metrics
    )
    return encodeReplayFile(
      ReplayGame, PresetGameVersion, stored, MaxReplayBytes
    )
  if data.header.gameVersion == ReplayGameVersion:
    return encodeReplayFile(
      ReplayGame, ReplayGameVersion, data, MaxReplayBytes
    )
  var current = HistoricalReplayData(
    header: data.header,
    config: data.config.gameConfig(),
    actions: data.actions,
    hashes: data.hashes,
    metrics: data.metrics
  )
  if current.header.gameVersion == MetricsGameVersion:
    current.header.gameVersion = TelemetryGameVersion
  encodeReplayFile(
    ReplayGame,
    current.header.gameVersion,
    current,
    MaxReplayBytes
  )

proc decodeReplay*(bytes: string): ReplayData =
  ## Returns the complete replay, including its original CPU telemetry.
  if bytes.len > MaxReplayBytes:
    fail("replay exceeds the file size limit")
  let version = bytes.replayFileHeader().gameVersion
  if version notin {
    LegacyGameVersion, ActionGameVersion, MetricsGameVersion,
    TelemetryGameVersion, CombatGameVersion, ArenaGameVersion,
    PreviousMapGameVersion, InitialArenaGameVersion, CryptArenaGameVersion,
    PresetGameVersion, ReplayGameVersion
  }:
    fail("unsupported replay game version")
  if version == ReplayGameVersion:
    result = decodeReplayFile(
      ReplayGame, version, bytes, ReplayData, MaxReplayBytes
    )
  elif version == PresetGameVersion:
    let stored = decodeReplayFile(
      ReplayGame, version, bytes, StoredReplayData, MaxReplayBytes
    )
    if stored.header.setup.gridTiles != 128:
      fail("version 26 replays require a 128 tile map")
    result = ReplayData(
      header: stored.header,
      config: stored.config.gameConfig().withMapPreset(
        restorePreset(stored.config.mapPreset)
      ),
      actions: stored.actions,
      hashes: stored.hashes,
      metrics: stored.metrics
    )
  elif version in {
    TelemetryGameVersion, CombatGameVersion, ArenaGameVersion,
    PreviousMapGameVersion, InitialArenaGameVersion, CryptArenaGameVersion
  }:
    let historical = decodeReplayFile(
      ReplayGame,
      version,
      bytes,
      HistoricalReplayData,
      MaxReplayBytes
    )
    result = ReplayData(
      header: historical.header,
      config: historical.config.withMapPreset(historicalConfig()),
      actions: historical.actions,
      hashes: historical.hashes,
      metrics: historical.metrics
    )
  elif version == MetricsGameVersion:
    let previous = decodeReplayFile(
      ReplayGame,
      version,
      bytes,
      PreviousReplayData,
      MaxReplayBytes
    )
    result = ReplayData(
      header: previous.header,
      config: previous.config.withMapPreset(historicalConfig()),
      actions: previous.actions,
      hashes: previous.hashes,
      metrics: previous.metrics.cpuMetrics()
    )
  else:
    let legacy = decodeReplayFile(
      ReplayGame,
      version,
      bytes,
      LegacyReplayData,
      MaxReplayBytes
    )
    result = ReplayData(
      header: legacy.header,
      config: legacy.config.withMapPreset(historicalConfig()),
      actions: legacy.actions,
      hashes: legacy.hashes
    )
  if result.header.gameVersion != version:
    fail("replay header versions disagree")
  result.validate()

proc saveReplay*(path: string, data: ReplayData) =
  ## Creates the parent directory and saves the complete recording.
  if path.len == 0:
    fail("replay output path is empty")
  let bytes = encodeReplay(data)
  try:
    let directory = path.parentDir
    if directory.len > 0:
      createDir(directory)
    writeFile(path, bytes)
  except IOError, OSError:
    fail("cannot save replay: " & getCurrentExceptionMsg())

proc loadReplay*(path: string): ReplayData =
  ## Loads one recording with its complete match configuration and metrics.
  try:
    result = decodeReplay(readFile(path))
  except IOError, OSError:
    fail("cannot load replay: " & getCurrentExceptionMsg())

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Creates a playback cursor over validated action data.
  data.validate()
  initTapePlayer(data)
