import polyworld/[rooms, roomclients]

echo "Testing command and hash retransmission after connection loss"
let client = RoomClient(participant: 7, match: 2, began: true, welcomed: true)
client.snapshot = RoomMessage(
  kind: RoomState, room: "room", phase: Playing,
  seats: @[Seat(owner: 7, name: "Human")]
)
doAssert client.submit(0, "opaque game command")
client.send(RoomMessage(kind: ReportHash, match: 2, tick: 24, hash: 123))
client.send(RoomMessage(kind: FinishMatch, match: 2, tick: 25, hash: 456))
client.lost()
client.opened()
client.accept(RoomMessage(kind: Welcome, participant: 7, token: "secret").encode)
var commands, checkpoints, finals: int
for bytes in client.outgoing:
  let message = decode(bytes)
  case message.kind
  of SubmitCommand:
    inc commands
    doAssert message.sequence == 1 and message.payload == "opaque game command"
  of ReportHash:
    inc checkpoints
    doAssert message.tick == 24 and message.hash == 123
  of FinishMatch:
    inc finals
    doAssert message.tick == 25 and message.hash == 456
  else:
    discard
doAssert commands == 1 and checkpoints == 1 and finals == 1
# Acknowledged commands are not retransmitted; hash confirmations still are.
client.accept(RoomMessage(kind: CommandAck, match: 2, sequence: 1).encode)
client.lost()
client.opened()
client.accept(RoomMessage(kind: Welcome, participant: 7, token: "secret").encode)
for bytes in client.outgoing:
  doAssert decode(bytes).kind != SubmitCommand
client.accept(RoomMessage(kind: TickPacket, match: 2, tick: 1).encode)
client.accept(RoomMessage(kind: TickPacket, match: 2, tick: 1).encode)
doAssert client.packets.len == 1
var failed = false
try:
  client.accept(RoomMessage(kind: TickPacket, match: 2, tick: 1,
    commands: @[Command(payload: "changed")]).encode)
except RoomsError:
  failed = true
doAssert failed
var packet: RoomMessage
doAssert client.takeTick(packet) and packet.tick == 1
client.appliedTick(1)
doAssert not client.takeTick(packet)
echo "Reconnect receipts, mandatory hashes and immutable ticks passed"

client.accept(RoomMessage(
  kind: MatchStatus, match: client.match, phase: Waiting,
  flag: true, tick: client.applied, detail: "Paused"
).encode())
doAssert client.snapshot.flag
client.accept(RoomMessage(
  kind: MatchStatus, match: client.match, phase: Waiting,
  flag: false, tick: client.applied, detail: "Waiting for hashes"
).encode())
doAssert not client.snapshot.flag

block consumedEdgeDiscovery:
  echo "Testing bounded discovery at the consumed history edge"
  proc catchups(client: RoomClient): int =
    for bytes in client.outgoing:
      if decode(bytes).kind == Catchup: inc result

  # Controllers and seatless spectators both fetch history; neither fetching nor
  # polling may advance the simulation/receipt cursor on their behalf.
  for spectator in [false, true]:
    for paused in [false, true]:
      let edge = RoomClient(participant: 7, match: 2, began: true, welcomed: true)
      edge.snapshot = RoomMessage(kind: RoomState, room: "edge",
        phase: (if paused: Waiting else: Playing), flag: paused)
      if not spectator: edge.snapshot.seats = @[Seat(owner: 7, name: "Human")]
      for tick in 1'u32 .. 2'u32:
        edge.accept(RoomMessage(kind: TickPacket, match: 2, tick: tick).encode)
      var packet: RoomMessage
      doAssert edge.applied == 0
      doAssert edge.takeTick(packet) and packet.tick == 1
      edge.appliedTick(packet.tick)
      doAssert edge.catchups == 0, "Do not fetch while a contiguous buffer remains"
      doAssert edge.takeTick(packet) and packet.tick == 2
      edge.appliedTick(packet.tick)
      doAssert edge.serverTick == edge.applied
      doAssert edge.catchups == 1, "Exhausting a stale known edge must discover history"
      doAssert edge.catchupPending
      for frame in 0 ..< 200: doAssert not edge.takeTick(packet)
      doAssert edge.catchups == 1, "A pending request must suppress duplicates"
      edge.accept(RoomMessage(kind: CaughtUp, match: 2, tick: 2, number: 2).encode)
      doAssert not edge.catchupPending
      for frame in 0 ..< 200: doAssert not edge.takeTick(packet)
      doAssert edge.catchups == 1, "An empty CaughtUp reply must not cause polling loops"
      doAssert edge.applied == 2
      edge.accept(RoomMessage(kind: TickPacket, match: 2, tick: 3).encode)
      doAssert edge.applied == 2, "Receiving history must not auto-advance spectators"
      doAssert edge.takeTick(packet) and packet.tick == 3
      edge.appliedTick(packet.tick)
      doAssert edge.catchups == 2, "New applied progress permits one new edge probe"

  # Ended matches still drain known final history but need no speculative probe
  # once the final advertised tick has been applied.
  let ended = RoomClient(match: 2, began: true, welcomed: true)
  ended.snapshot = RoomMessage(kind: RoomState, phase: Ended)
  ended.accept(RoomMessage(kind: MatchStatus, match: 2, phase: Ended, tick: 2).encode)
  ended.accept(RoomMessage(kind: TickPacket, match: 2, tick: 1).encode)
  var packet: RoomMessage
  doAssert ended.takeTick(packet)
  ended.appliedTick(packet.tick)
  doAssert ended.catchups == 1
  ended.accept(RoomMessage(kind: TickPacket, match: 2, tick: 2).encode)
  ended.accept(RoomMessage(kind: CaughtUp, match: 2, tick: 2, number: 2).encode)
  doAssert ended.takeTick(packet)
  ended.appliedTick(packet.tick)
  for frame in 0 ..< 200: doAssert not ended.takeTick(packet)
  doAssert ended.catchups == 1

  for phase in [Lobby, Desynced]:
    let idle = RoomClient(match: 2, began: true, welcomed: true,
      snapshot: RoomMessage(phase: phase))
    idle.appliedTick(1)
    doAssert idle.catchups == 0
  for began in [false, true]:
    let idle = RoomClient(match: (if began: 2'u32 else: 0'u32), began: began,
      welcomed: false, snapshot: RoomMessage(phase: Playing))
    idle.appliedTick(1)
    doAssert idle.catchups == 0
  let noMatch = RoomClient(welcomed: true, snapshot: RoomMessage(phase: Playing))
  noMatch.appliedTick(1)
  doAssert noMatch.catchups == 0
  echo "Consumed-edge discovery is bounded and preserves playback authority"
