## Call to Adventure action-only replay format and playback cursor.

import
  std/os,
  polyworld/pathing,
  polyworld/[tapes, metrics],
  content

const
  ReplayGame* = "call_to_adventure"
  ReplayFormatVersion* = 3'u16
  LegacyGameVersion* = 18'u16
  ActionGameVersion* = 19'u16
  MetricsGameVersion* = 20'u16
  ReplayGameVersion* = 21'u16
  ActionWalkTo* = 1'u8
  ActionAttackTarget* = 2'u8
  ActionPickupTarget* = 3'u8
  ActionHealTarget* = 4'u8
  ActionUseItem* = 5'u8
  ActionDropItem* = 6'u8
  ActionKindHigh* = ActionDropItem
  MaxReplayBytes* = 64 * 1024 * 1024
  MaxReplayActions* = 4_000_000
  MaxReplayHashes* = 10_000_000

type
  ReplayAction* = object
    tick*: uint32
    heroId*: int32
    kind*: uint8
    first*, second*, third*: int32
      ## Walk uses level, x, z. Target actions use `first` as the target ID.
      ## Use and drop use `first` as the inventory slot.

  ReplayHeader* = TapeHeader[Setup]
  LegacyReplayData = ActionTape[Setup, ReplayAction]
  PreviousReplayData = ActionTape[Setup, ReplayAction, LegacyReplayMetrics]
  ReplayData* = ActionTape[Setup, ReplayAction, ReplayMetrics]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction, ReplayMetrics]
  ReplayPlayer* = TapePlayer[Setup, ReplayAction, ReplayMetrics]

proc fail(message: string) {.noreturn.} =
  ## Raises one Call to Adventure replay error.
  raise newException(ReplayError, message)

proc initReplayData*(setup: Setup): ReplayData =
  ## Creates a replay containing the match setup, config, and action tape.
  result.header = initActionTape[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  ).header
  result.config = GameConfig(
    seed: setup.seed,
    maxTicks: int32(setup.maximumTicks),
    players: unnamedPlayers(PartySize)
  )

proc initReplayRecorder*(setup: Setup): ReplayRecorder =
  ## Creates an in-memory recorder owning the complete replay data.
  ReplayRecorder(data: initReplayData(setup))

proc recordAction*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId: int32,
    kind: uint8,
    first = 0'i32,
    second = 0'i32,
    third = 0'i32
) =
  ## Records one attempted hero command without storing its BASIC source.
  if recorder == nil:
    return
  if kind == 0 or kind > ActionKindHigh:
    fail("replay action kind is invalid")
  recorder.data.actions.appendAction(
    ReplayAction(
      tick: tick,
      heroId: heroId,
      kind: kind,
      first: first,
      second: second,
      third: third
    ),
    MaxReplayActions
  )

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  ## Appends the canonical hash for one completed simulation tick.
  recordHash(recorder, hash, MaxReplayHashes)

proc validateSetup(setup: Setup) =
  ## Validates the immutable expedition description.
  if setup.tickRate != uint16(TickRate):
    fail("replay setup has an unsupported tick rate")
  if setup.gridTiles != uint16(GridTiles):
    fail("replay setup has an unsupported map size")
  if setup.levels != uint8(LevelCount):
    fail("replay setup has an unsupported level count")
  if setup.decisionTicks != uint16(DecisionTicks):
    fail("replay setup has an unsupported decision interval")
  if setup.maximumTicks == 0 or setup.maximumTicks > uint32(MaxReplayHashes):
    fail("replay setup has an invalid duration")
  if setup.mapHash == 0:
    fail("replay setup has no deterministic map fingerprint")
  for slot, member in setup.party:
    if member.id != int32(100 + slot) or member.class != HeroClass(slot):
      fail("replay setup party is not in canonical order")

proc validateAction(action: ReplayAction, setup: Setup) =
  ## Validates one recorded hero command and its payload.
  if action.tick == 0 or action.tick > setup.maximumTicks or
      action.tick mod uint32(setup.decisionTicks) != 0:
    fail("replay action did not land on a decision tick")
  if action.heroId < 100 or action.heroId >= 100 + PartySize:
    fail("replay action names an unknown hero")
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if action.kind == ActionWalkTo:
    if action.first < 0 or action.first >= LevelCount or
        action.second < 0 or action.second >= GridTiles or
        action.third < 0 or action.third >= GridTiles:
      fail("replay walk names a tile outside the dungeon")
  elif action.kind == ActionUseItem or action.kind == ActionDropItem:
    if action.first < 0 or action.first >= InventorySlots:
      fail("replay item action names a slot outside the bag")
  elif action.first <= 0:
    fail("replay target action has an invalid target ID")

proc validate*(data: ReplayData) =
  ## Validates versions, setup, commands, and per-tick hash coverage.
  data.config.validateConfig(PartySize)
  if data.config.seed != data.header.setup.seed or
    data.config.maxTicks != int32(data.header.setup.maximumTicks):
      fail("replay configuration does not match its simulation setup")
  data.header.requireTapeVersion(
    ReplayFormatVersion,
    data.header.gameVersion
  )
  if data.header.gameVersion notin {
    LegacyGameVersion, ActionGameVersion, MetricsGameVersion, ReplayGameVersion
  }:
    fail("unsupported replay game version")
  data.header.setup.validateSetup()
  if data.actions.len > MaxReplayActions:
    fail("replay action limit exceeded")
  if data.hashes.len > int(data.header.setup.maximumTicks):
    fail("replay hashes exceed the configured duration")
  var lastTick = 0'u32
  for index, action in data.actions:
    if action.tick > uint32(data.hashes.len):
      fail("replay action exceeds the recorded duration")
    if index > 0 and action.tick < lastTick:
      fail("replay actions move backward in time")
    action.validateAction(data.header.setup)
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
      config: data.config,
      actions: data.actions,
      hashes: data.hashes
    )
    return encodeReplayFile(
      ReplayGame,
      data.header.gameVersion,
      legacy,
      MaxReplayBytes
    )
  var current = data
  current.header.gameVersion = ReplayGameVersion
  encodeReplayFile(ReplayGame, ReplayGameVersion, current, MaxReplayBytes)

proc decodeReplay*(bytes: string): ReplayData =
  ## Returns the complete replay, including its original CPU telemetry.
  if bytes.len > MaxReplayBytes:
    fail("replay exceeds the file size limit")
  let version = bytes.replayFileHeader().gameVersion
  if version notin {
    LegacyGameVersion, ActionGameVersion, MetricsGameVersion, ReplayGameVersion
  }:
    fail("unsupported replay game version")
  if version == ReplayGameVersion:
    result = decodeReplayFile(
      ReplayGame,
      version,
      bytes,
      ReplayData,
      MaxReplayBytes
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
      config: previous.config,
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
      config: legacy.config,
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
  ## Creates a playback cursor over validated commands.
  data.validate()
  initTapePlayer(data)

proc takeActionAt*(
    player: ReplayPlayer,
    tick: uint32,
    heroId: int32,
    action: var ReplayAction
): bool =
  ## Consumes the next command when it belongs to this decision slot.
  if player == nil or player.finished:
    return false
  let next = player.data.actions[player.actionIndex]
  if next.tick < tick:
    fail("replay playback skipped an action tick")
  if next.tick != tick or next.heroId != heroId:
    return false
  action = next
  inc player.actionIndex
  true
