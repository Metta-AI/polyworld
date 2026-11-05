import jsony, polyworld/[rooms, roomclients, tapes],
  ../[multiplayer, presets, sim, replays, content, controls]

proc clientFor(id: uint32): RoomClient =
  var config = defaultConfig(3)
  config.maxTicks = 12
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  result = RoomClient(identity: lvdIdentity(), participant: id, match: 1,
    began: true, welcomed: true)
  result.snapshot = RoomMessage(kind: RoomState, revision: 2, phase: Playing,
    tickRate: uint32(TickRate), payload: config.toJson(), seats: @[
      Seat(owner: 1, name: "Human"), Seat(owner: 2, name: "Bot"),
      Seat(owner: 1, name: "Bot")], participants: @[
      Participant(id: 1, name: "Alice"), Participant(id: 2, name: "Bob")])

block oversizedRoomAndLocalConfigRejectedBeforeAllocation:
  let oversized = LvdConfig(playerCount: 64,
    mapSettings: MapSettings(layout: RandomLayout, size: 724,
      expansions: 0, minDistance: 1))
  let remote = clientFor(1)
  remote.snapshot.payload = oversized.toJson()
  remote.snapshot.seats = newSeq[Seat](64)
  for seat in remote.snapshot.seats.mitems:
    seat = Seat(owner: 1, name: "Bot")
  let sources = newSeq[string](64)
  var rejected = false
  try: discard prepareNetworkMatch(remote, sources)
  except LvdError as error:
    rejected = error.msg == "Map and roster exceed browser cell budget; reduce map size, spacing, expansions or players"
  doAssert rejected, "Remote config must be validated before terrain/world allocation"
  rejected = false
  try: discard newLocalMatch(oversized, sources)
  except LvdError as error:
    rejected = error.msg == "Map and roster exceed browser cell budget; reduce map size, spacing, expansions or players"
  doAssert rejected, "Local config must share the same pre-allocation budget"

let
  a = prepareNetworkMatch(clientFor(1), ["", "invalid private remote source", ""])
  b = prepareNetworkMatch(clientFor(2), ["invalid private remote source", "", ""])
doAssert a.game.world.players.len == 3
doAssert a.game.networkHash() == b.game.networkHash()
doAssert a.game.config.players[0].name == "Alice"
let startEvent = RoomMessage(kind: BeginMatch, revision: 2, match: 1,
  hash: a.game.networkHash())
a.start(startEvent)
b.start(startEvent)
let own = a.game.world.units[0]
let before = a.game.stateHash()
queueMove(0, own.id, int32(own.tile.x), int32(own.tile.y))
a.flushSubmissions()
doAssert a.game.stateHash() == before, "Submitting must not mutate the world"
var commands: seq[Command]
for bytes in a.client.outgoing:
  let message = decode(bytes)
  if message.kind == SubmitCommand:
    commands.add Command(participant: 1, seat: message.seat,
      sequence: message.sequence, payload: message.payload)
doAssert commands.len == 1
for tick in 1'u32 .. 12'u32:
  let packet = RoomMessage(kind: TickPacket, match: 1, tick: tick,
    commands: (if tick == 1: commands else: @[]))
  a.applyPacket(packet)
  b.applyPacket(packet)
  doAssert a.game.stateHash() == b.game.stateHash()

block invalidLocalIntentsAreRefused:
  let session = prepareNetworkMatch(clientFor(1), ["", "", ""])
  let unit = session.game.world.units[0]
  doAssert not session.game.applyMove(0, unit.id, -1, -1)
  doAssert not session.game.applyBuild(0, unit.id, 999, 0, 0)
  doAssert not session.game.applyDiplomacy(0, 0, DeclareWar)
  doAssert session.game.submissions.len == 0

doAssert a.finished and b.finished
let data = decodeReplay(encodeReplay(a.game.recorder.data))
doAssert data.actions.len == 1
let playback = newGame(a.game.world.map, 12, data.header.setup.diplomacySettings)
let cursor = initReplayPlayer(data)
proc replay(w: World) =
  var action: ReplayAction
  while cursor.takeActionAt(uint32(w.tick), action):
    doAssert w.applyReplayAction(action)
for tick in 1 .. data.hashes.len:
  playback.world.tickWorld(replay)
  doAssert playback.stateHash() == data.hashes[tick - 1]
echo "LvD multiplayer deterministic replay passed"

block rejectsMalformedAtomically:
  let session = prepareNetworkMatch(clientFor(1), ["", "", ""])
  session.start(startEvent)
  let baseline = session.game.stateHash()
  for bad in [
    Command(participant: 2, seat: 0, payload: commands[0].payload),
    Command(participant: 1, seat: 2, payload: commands[0].payload),
    Command(participant: 1, seat: 0, payload: ReplayAction(kind: ActionDiplomacy,
      playerId: 0, first: 1, second: 999).encodeSubmission()),
    Command(participant: 1, seat: 0, payload: commands[0].payload & "x")]:
    var rejected = false
    try:
      session.applyPacket(RoomMessage(kind: TickPacket, match: 1, tick: 1,
        commands: @[commands[0], bad]))
    except RoomsError: rejected = true
    doAssert rejected, "Malformed packet must be rejected before mutation"
    doAssert session.game.stateHash() == baseline
    doAssert session.game.world.tick == 0
    doAssert session.game.networkActions.len == 0

block privateBotsAndChat:
  let bot = "a = declareWar(0)\na = sendChat(-2, \"hello\")"
  let host = prepareNetworkMatch(clientFor(2), ["", bot, ""])
  let observer = prepareNetworkMatch(clientFor(1), ["", "", ""])
  host.start(startEvent)
  observer.start(startEvent)
  doAssert host.game.brains[1].decisions == 1
  doAssert observer.game.brains[1] == nil
  doAssert host.game.stateHash() == observer.game.stateHash()
  doAssert host.game.inboxes[0].count == 0,
    "Private bot chat must await the relay, not mutate only its owner's inbox"
  var submitted: seq[Command]
  for bytes in host.client.outgoing:
    let message = decode(bytes)
    if message.kind == SubmitCommand:
      submitted.add Command(participant: 2, seat: message.seat,
        sequence: message.sequence, payload: message.payload)
  doAssert submitted.len == 2
  let packet = RoomMessage(kind: TickPacket, match: 1, tick: 1, commands: submitted)
  host.applyPacket(packet)
  observer.applyPacket(packet)
  doAssert host.game.stateHash() == observer.game.stateHash()
  doAssert observer.game.inboxes[0].count == 1
  doAssert host.game.recorder.data.actions.len == 1
  doAssert host.game.recorder.data.actions[0].kind == ActionDiplomacy

block controlsDoNotLeakBetweenMatches:
  queueCancel(0, own.id)
  let fresh = prepareNetworkMatch(clientFor(1), ["", "", ""])
  fresh.start(startEvent)
  for bytes in fresh.client.outgoing:
    doAssert decode(bytes).kind != SubmitCommand,
      "A new match must discard previous human intents"
