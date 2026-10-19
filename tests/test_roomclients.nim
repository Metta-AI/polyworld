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
