import jsony, polyworld/[rooms, roomclients, tapes],
  ../[multiplayer, presets, sim, replays, content, controls]

proc clientFor(id: uint32): RoomClient =
  var config = defaultConfig(2)
  config.maxTicks = TickRate * 15
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  result = RoomClient(identity: lvdIdentity(), participant: id, match: 1,
    began: true, welcomed: true)
  result.snapshot = RoomMessage(kind: RoomState, revision: 2, phase: Playing,
    tickRate: uint32(TickRate), payload: config.toJson(), seats: @[
      Seat(owner: 1, name: "Human"), Seat(owner: 2, name: "Human")], participants: @[
      Participant(id: 1, name: "Alice"), Participant(id: 2, name: "Bob")])

let a = prepareNetworkMatch(clientFor(1), ["", ""])
let b = prepareNetworkMatch(clientFor(2), ["", ""])
let event = RoomMessage(kind: BeginMatch, revision: 2, match: 1,
  hash: a.game.networkHash())
a.start(event)
b.start(event)
let unit = a.game.world.units[0]
let baseline = a.game.stateHash()
let x = int32(unit.tile.x)
let y = int32(unit.tile.y)
queueMove(0, unit.id, x, y)
queueAttackMove(0, unit.id, x, y, append = true)
a.flushSubmissions()
doAssert a.game.stateHash() == baseline
var commands: seq[Command]
for bytes in a.client.outgoing:
  let message = decode(bytes)
  if message.kind == SubmitCommand:
    commands.add Command(participant: 1, seat: message.seat,
      sequence: message.sequence, payload: message.payload)
doAssert commands.len == 2
doAssert decodeSubmission(commands[1].payload).append, "Wire must preserve append"
doAssert not decodeSubmission(commands[0].payload).append
for tick in 1'u32 .. uint32(TickRate * 15):
  let packet = RoomMessage(kind: TickPacket, match: 1, tick: tick,
    commands: (if tick == 1: commands else: @[]))
  a.applyPacket(packet)
  b.applyPacket(packet)
  doAssert a.game.stateHash() == b.game.stateHash()
  if tick == uint32(DecisionTicks):
    doAssert a.game.world.units[0].orderQueue.len == 1
let data = decodeReplay(encodeReplay(a.game.recorder.data))
doAssert data.actions.len == 2 and data.actions[1].append
let playback = newGame(a.game.world.map, TickRate * 15,
  data.header.setup.diplomacySettings)
let cursor = initReplayPlayer(data)
proc replay(w: World) =
  var action: ReplayAction
  while cursor.takeActionAt(uint32(w.tick), action): doAssert w.applyReplayAction(action)
for tick in 0 ..< data.hashes.len:
  playback.world.tickWorld(replay)
  doAssert playback.stateHash() == data.hashes[tick]

block invalidAppendKindsAndVersionsAreRejected:
  let setup = a.game.recorder.data.header.setup
  var bad = ReplayAction(kind: ActionCancel, playerId: 0, entityId: unit.id,
    tick: uint32(DecisionTicks), append: true)
  var refused = false
  try: bad.validateAction(setup)
  except ReplayError: refused = true
  doAssert refused, "Append is not meaningful for cancel/build/train/rally/diplomacy"
  var wire = commands[1].payload
  wire[wire.len - 4] = char(2)
  refused = false
  try: discard decodeSubmission(wire)
  except RoomsError: refused = true
  doAssert refused
  refused = false
  try: discard decodeSubmission(commands[1].payload[0 ..< 32])
  except RoomsError: refused = true
  doAssert refused, "Old wire length must be refused, not treated as replacement"
  var old = data
  old.header.gameVersion = ReplayGameVersion - 1
  refused = false
  try: old.validate()
  except ReplayError: refused = true
  doAssert refused, "Old gameplay requires its archived client"
  doAssert LvdNetworkProtocol == 2

echo "LvD network order queue replay passed"
