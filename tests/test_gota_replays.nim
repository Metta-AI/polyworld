## Gods of the Arena action replay codec, playback cursor, and validation.

import
  std/[os, strutils],
  polyworld/tapes,
  ../examples/gods_of_the_arena/content,
  ../examples/gods_of_the_arena/replays

let setup = Setup(
  mapSeed: 2026,
  mapHash: 0x123456789ABCDEF0'u64,
  tickRate: uint16(TickRate),
  gridTiles: 116,
  spawnIntervalTicks: uint32(TickRate) * 10,
  maximumTicks: 20,
  heroes: @[
    ReplayHero(
      id: 100,
      team: 0,
      slot: 0,
      lane: 0,
      class: uint8(DeathKnight.ord)
    ),
    ReplayHero(
      id: 105,
      team: 1,
      slot: 0,
      lane: 0,
      class: uint8(VanguardKnight.ord)
    )
  ]
)

echo "Testing Flatty action replay round trip"
let recorder = initReplayRecorder(setup)
recorder.recordWalkTo(12, 100, 64, 42, fixedVec2(0.25'fx, -0.5'fx))
recorder.recordAttackTarget(12, 105, 100)
recorder.recordAttackMove(15, 100, 70, 80)
recorder.recordAttackTarget(19, 100, 105)
for tick in 1'u64 .. 20'u64:
  recorder.recordHash(tick xor 0x9E3779B97F4A7C15'u64)
let
  encoded = recorder.data.encodeReplay()
  decoded = decodeReplay(encoded)
  fileHeader = replayFileHeader(encoded)
doAssert encoded.startsWith(ReplayMagic)
doAssert fileHeader.formatVersion == ReplayFileVersion
doAssert fileHeader.game == ReplayGame
doAssert fileHeader.gameVersion == ReplayGameVersion
doAssert decoded.header.formatVersion == ReplayFormatVersion
doAssert decoded.header.gameVersion == ReplayGameVersion
doAssert decoded.header.setup.mapSeed == 2026
doAssert decoded.header.setup.heroes.len == 2
doAssert decoded.header.setup.heroes[0].class == uint8(DeathKnight.ord)
doAssert decoded.header.setup.heroes[1].class == uint8(VanguardKnight.ord)
doAssert decoded.actions.len == 4
doAssert decoded.actions[0].kind == ActionWalkTo
doAssert decoded.actions[0].first == 64
doAssert decoded.actions[0].offset == fixedVec2(0.25'fx, -0.5'fx)
doAssert decoded.actions[1].kind == ActionAttackTarget
doAssert decoded.actions[2].kind == ActionAttackMove
doAssert decoded.actions[2].first == 70
doAssert decoded.hashes == recorder.data.hashes
doAssert decoded.hashes.len == int(decoded.header.setup.maximumTicks)

echo "Testing every explicit spell slot round trip"
block:
  let spells = initReplayRecorder(setup)
  for slot in 0'i32 .. 3'i32:
    spells.recordCast(2, 100, slot, 105, 0, false)
    spells.recordCast(2, 100, slot, 64, 42, true)
  for slot in [-7'i32, 0, 1, 2, 3, int32.high]:
    spells.recordLevelAbility(2, 100, slot)
  spells.recordCast(2, 100, -7, 105, 0, false)
  spells.recordCast(2, 100, int32.high, -20, 42, true)
  spells.recordHash(123)
  spells.recordHash(456)
  let restored = decodeReplay(spells.data.encodeReplay())
  doAssert restored.actions == spells.data.actions

echo "Testing exact-tick action playback"
let player = initReplayPlayer(decoded)
doAssert player.actionsAt(0).len == 0
let first = player.actionsAt(12)
doAssert first.len == 2
doAssert first[0].heroId == 100
doAssert first[1].heroId == 105
let moved = player.actionsAt(15)
doAssert moved.len == 1
doAssert moved[0].kind == ActionAttackMove
doAssert player.actionsAt(18).len == 0
doAssert player.actionsAt(19).len == 1
doAssert player.finished

echo "Testing draft ticks have their own bounded replay allowance"
block:
  var draftSetup = setup
  draftSetup.drafting = true
  let
    draft = initReplayRecorder(draftSetup)
    maximum = setup.maximumTicks.int + setup.heroes.len * DraftPickTicks
  draft.recordWalkTo(maximum.uint32, 100, 64, 42)
  for tick in 1 .. maximum:
    draft.recordHash(tick.uint64)
  let restored = decodeReplay(draft.data.encodeReplay())
  doAssert restored.config.maxTicks == setup.maximumTicks.int32
  doAssert restored.hashes.len == maximum
  doAssert restored.actions[^1].tick == maximum.uint32
  try:
    draft.recordHash(0)
    doAssert false, "hashes beyond the draft and battle budgets must fail"
  except ReplayError:
    discard
  draft.data.hashes.add(0)
  try:
    discard draft.data.encodeReplay()
    doAssert false, "encoded tapes must respect both duration budgets"
  except ReplayError:
    discard

echo "Testing allocation-free action playback"
let directPlayer = initReplayPlayer(decoded)
var action: ReplayAction
doAssert not directPlayer.takeActionAt(0, action)
doAssert directPlayer.takeActionAt(12, action)
doAssert action.heroId == 100
doAssert directPlayer.takeActionAt(12, action)
doAssert action.heroId == 105
doAssert not directPlayer.takeActionAt(12, action)
doAssert directPlayer.takeActionAt(15, action)
doAssert action.kind == ActionAttackMove
doAssert not directPlayer.takeActionAt(15, action)
doAssert directPlayer.takeActionAt(19, action)
doAssert directPlayer.finished

echo "Testing replay file I/O and privacy shape"
createDir("tmp")
let path = "tmp" / ("polyworld-gota-" & $getCurrentProcessId() & ".replay")
saveReplay(path, recorder.data)
let loaded = loadReplay(path)
doAssert loaded.actions == decoded.actions
let replayBytes = readFile(path)
doAssert replayBytes.find("Gods of the Arena base hero controller") < 0
doAssert replayBytes.find("bestDistance = 2147483647") < 0
removeFile(path)

echo "Testing replay validation"
for version in 0'u16 ..< ReplayGameVersion:
  var unsupported = encoded
  unsupported[ReplayMagic.len + 2] = char(version and 0xff)
  unsupported[ReplayMagic.len + 3] = char(version shr 8)
  try:
    discard decodeReplay(unsupported)
    doAssert false, "an unsupported simulation must require its old viewer"
  except ReplayError as error:
    doAssert error.msg.contains("expected " & $ReplayGameVersion)

try:
  discard decodeReplayFile(
    "light_vs_dark",
    1,
    encoded,
    ReplayData
  )
  doAssert false, "a replay from another game should fail"
except ReplayError as error:
  doAssert error.msg.contains("gods_of_the_arena")
  doAssert error.msg.contains("light_vs_dark")

try:
  discard decodeReplayFile(
    ReplayGame,
    ReplayGameVersion + 1,
    encoded,
    ReplayData
  )
  doAssert false, "a replay from another game version should fail"
except ReplayError as error:
  doAssert error.msg.contains("game version")

var invalid = decoded
invalid.header.gameVersion = high(uint16)
try:
  discard invalid.encodeReplay()
  doAssert false, "invalid version should fail"
except ReplayError:
  discard

invalid = decoded
invalid.hashes.setLen(18)
try:
  discard invalid.encodeReplay()
  doAssert false, "an action after the last recorded tick should fail"
except ReplayError:
  discard

invalid = decoded
invalid.header.setup.heroes[0].class = high(uint8)
try:
  discard invalid.encodeReplay()
  doAssert false, "an unknown hero class should fail"
except ReplayError:
  discard

try:
  discard decodeReplay("NOT-A-GOTA-REPLAY")
  doAssert false, "invalid magic should fail"
except ReplayError:
  discard

echo "test_gota_replays: all checks passed"


echo "Testing replay points stay inside their canonical destination tile"
block:
  var invalidPoint = decoded
  invalidPoint.actions[0].offset.x = 0.5'fx
  try:
    discard invalidPoint.encodeReplay()
    doAssert false, "an offset in the next tile must be rejected"
  except ReplayError:
    discard
