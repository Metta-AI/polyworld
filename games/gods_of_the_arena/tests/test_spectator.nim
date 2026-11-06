import std/times
import jsony
import polyworld/[rooms, relays, roomclients, player, tapes, mailboxes, metrics]
import ../[bots, multiplayer, replays, sim, spectator]

var relay = Relay()
var clients: seq[RoomClient]
var now = 0.0
proc exchange() =
  for iteration in 0 ..< 30:
    var sent = false
    for i, client in clients:
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        relay.process(i + 1, bytes, now)
        sent = true
    let outgoing = relay.outgoing
    relay.outgoing = @[]
    for message in outgoing:
      if message.bytes.len > 0:
        clients[message.connection - 1].accept(message.bytes)
        doAssert clients[message.connection - 1].error.len == 0
        sent = true
    if not sent: return
  doAssert false
proc connect(): RoomClient =
  result = RoomClient(identity: gotaIdentity(), name: "Viewer " & $clients.len)
  clients.add result
  result.opened()
  exchange()
let owner = connect()
let viewer = connect()
owner.send(RoomMessage(kind: CreateRoom, name: "Stream", number: 10,
  tickRate: 24, flag: true,
  payload: parseConfig("{\"maxTicks\":1200,\"draftMode\":\"open\"}").toJson()))
exchange()
viewer.send(RoomMessage(kind: JoinRoom, room: owner.snapshot.room))
exchange()
for i in 0 ..< 10:
  owner.send(RoomMessage(kind: ClaimSeat, seat: uint32(i), name: "Bot"))
exchange()
var sources = newSeq[string](10)
for source in sources.mitems:
  source = readFile("games/gods_of_the_arena/players/base.bas")
let controller = prepareNetworkMatch(owner, sources)
let watched = prepareNetworkMatch(viewer, [])
doAssert not controller.isSpectator, "Bot ownership is still control"
doAssert watched.isSpectator
owner.send(RoomMessage(kind: Ready, revision: controller.revision,
  hash: controller.game.networkHash))
exchange()
owner.send(RoomMessage(kind: StartMatch))
exchange()
controller.start(owner.events[0])
watched.start(viewer.events[0])
let stream = newSpectatorStream(watched)
var p = initPlayer(live = true, durationTicks = watched.game.durationTicks())
p.streamed = true
exchange()
for i in 0 ..< 720:
  if i == 100:
    doAssert controller.game.sendChat(0, 1, "Buffered mailbox") == 1
    controller.flushSubmissions()
    exchange()
  now += 1.0 / 24
  relay.advance(now)
  exchange()
  var packet: RoomMessage
  while owner.takeTick(packet): controller.applyPacket(packet)
  stream.receive()
  exchange()
doAssert stream.receivedEnd == 720
doAssert watched.game.world.tick == 0
p.sync(0, stream.receivedEnd, false)
for frame in 0 ..< 24:
  p.startFrame(1.0'f32 / 24, 24)
  while p.shouldTick(epochTime()):
    stream.advance()
    p.sync(watched.game.world.tick, stream.receivedEnd, false)
doAssert watched.game.world.tick == 24, "Burst must play at 24 ticks/sec"
doAssert watched.game.history.frames[^1].tick == 24
# Cross the first-traversal frontier again after a short rewind; later ticks
# must keep counting once, not suppress all commands after any seek.
stream.restoreTo(12)
while watched.game.world.tick < 24: stream.advance()
p.pause()
for i in 0 ..< 24:
  now += 1.0 / 24
  relay.advance(now)
  exchange()
  var packet: RoomMessage
  while owner.takeTick(packet): controller.applyPacket(packet)
  stream.receive()
  exchange()
doAssert stream.receivedEnd == 744
doAssert watched.game.world.tick == 24
p.sync(24, stream.receivedEnd, false)
p.skipToEnd()
doAssert p.targetTick == 744
while watched.game.world.tick < p.targetTick: stream.advance()
let hash = watched.game.stateHash
let actions = watched.game.recorder.data.actions
let hashes = watched.game.recorder.data.hashes
doAssert watched.game.history.frames.len == controller.game.history.frames.len,
  "First spectator traversal must sample every metrics interval"
doAssert watched.game.history.frames[^1].tick == 744
let history = watched.game.history
var rows: seq[MetricRow]
var commands = 0'i64
for slot in 0 ..< 10:
  let row = watched.game.metrics.read(slot, 744)
  let authoritative = controller.game.metrics.read(slot, 744)
  doAssert row.commands == authoritative.commands
  for kind in MetricKind:
    if kind != CpuMetric: # Spectators never run private policy VMs.
      doAssert row.values[kind] == authoritative.values[kind]
  rows.add row
  commands += row.commands
doAssert commands > 0, "Fixture must exercise accepted commands and APM"
stream.restoreTo(500)
while watched.game.world.tick < 744: stream.advance()
doAssert watched.game.stateHash == hash
let applied = viewer.applied
viewer.outgoing.setLen(0)
stream.restoreTo(12)
while watched.game.world.tick < 744: stream.advance()
doAssert watched.game.stateHash == hash
doAssert hash == controller.game.stateHash
doAssert watched.game.recorder.data.actions == actions
doAssert watched.game.recorder.data.hashes == hashes
doAssert watched.game.history == history, "Seeks must not append/rewrite metrics history"
for slot, row in rows:
  doAssert watched.game.metrics.read(slot, 744) == row,
    "Rewinds must not duplicate command totals or rolling APM"
doAssert viewer.applied == applied
doAssert viewer.outgoing.len == 0, "Local replay must not ACK/hash/finish/submit"
doAssert watched.game.inboxes[1].count == 1
let mailbox = watched.game.inboxes[1]
doAssert mailbox.messages[mailbox.first] == "Buffered mailbox"
doAssert watched.game.submissions.len == 0
for vm in watched.game.heroVms: doAssert vm == nil
# Cached packets belong to the completed match, not the mutable room lobby.
stream.restoreTo(0)
owner.send(RoomMessage(kind: FinishMatch, match: owner.match, tick: 744,
  hash: controller.game.networkHash))
exchange()
relay.advance(now)
exchange()
doAssert viewer.snapshot.phase == Ended
owner.send(RoomMessage(kind: ReturnLobby))
exchange()
owner.send(RoomMessage(kind: ReleaseSeat, seat: 0))
exchange()
doAssert viewer.match == 0
doAssert viewer.snapshot.seats[0].owner == 0
viewer.send(RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
exchange()
doAssert watched.isSpectator, "Lobby seat claims must not reclassify the old viewer"
doAssert not controller.isSpectator, "Lobby changes must not reclassify the old controller"
viewer.outgoing.setLen(0)
while watched.game.world.tick < 744: stream.advance()
doAssert watched.game.stateHash == hash
doAssert viewer.outgoing.len == 0
stream.restoreTo(0)
viewer.send(RoomMessage(kind: LeaveRoom))
exchange()
doAssert viewer.snapshot.room.len == 0
doAssert viewer.snapshot.seats.len == 0
viewer.outgoing.setLen(0)
while watched.game.world.tick < 744: stream.advance()
doAssert watched.game.stateHash == hash
doAssert viewer.outgoing.len == 0
doAssert watched.game.history == history
for slot, row in rows:
  doAssert watched.game.metrics.read(slot, 744) == row
echo "Spectator pacing, seek hashes, metrics, lobby/leave survival and no network side effects passed"
