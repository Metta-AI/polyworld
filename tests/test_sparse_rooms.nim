import polyworld/[rooms, relays]

proc expectError(relay: Relay, connection: int, message: RoomMessage) =
  var rejected = false
  try:
    relay.receive(connection, message, 0)
  except RoomsError:
    rejected = true
  doAssert rejected

proc flush(relay: Relay) =
  let outgoing = relay.outgoing
  relay.outgoing = @[]
  for output in outgoing:
    if output.bytes.len > 0 and not output.close:
      let message = decode(output.bytes)
      if message.delivery > 0:
        relay.receive(output.connection, RoomMessage(kind: Received,
          sequence: message.delivery), 0)

proc connect(relay: Relay, connection: int, game: string): uint32 =
  relay.receive(connection, RoomMessage(kind: Hello,
    identity: GameIdentity(game: game, gameplay: 7, protocol: 1),
    name: "Guest " & $connection), 0)
  result = decode(relay.outgoing[^1].bytes).participant
  relay.flush()

proc send(relay: Relay, connection: int, message: RoomMessage) =
  relay.receive(connection, decode(message.encode()), 0)
  relay.flush()

echo "Testing roster readiness intent and current-revision setup proofs"
var relay = Relay()
let host = relay.connect(1, "galcon")
let peer = relay.connect(2, "galcon")
discard relay.connect(3, "galcon")
relay.send(1, RoomMessage(kind: CreateRoom, name: "Sparse", number: 10, tickRate: 24))
let sparse = relay.rooms[0]
relay.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
relay.send(1, RoomMessage(kind: Ready, revision: sparse.revision, hash: 1))
relay.send(2, RoomMessage(kind: JoinRoom, room: sparse.id))
doAssert relay.guest(host).ready, "Joining must preserve visible readiness"
relay.send(2, RoomMessage(kind: ClaimSeat, seat: 5, name: "Human"))
doAssert relay.guest(host).ready
relay.expectError(1, RoomMessage(kind: StartMatch))
relay.send(2, RoomMessage(kind: Ready, revision: sparse.revision, hash: 2))
relay.expectError(1, RoomMessage(kind: StartMatch)) # host proof is stale
relay.send(1, RoomMessage(kind: Ready, revision: sparse.revision, hash: 2))
let beforeResize = sparse.revision
relay.send(1, RoomMessage(kind: ResizeRoom, name: sparse.name, number: 11,
  tickRate: sparse.tickRate, payload: sparse.payload))
doAssert sparse.revision == beforeResize + 1
doAssert relay.guest(host).ready and relay.guest(peer).ready
relay.expectError(1, RoomMessage(kind: StartMatch))
relay.send(1, RoomMessage(kind: Ready, revision: sparse.revision, hash: 2))
relay.send(2, RoomMessage(kind: Ready, revision: sparse.revision, hash: 2))
relay.send(3, RoomMessage(kind: JoinRoom, room: sparse.id))
relay.expectError(3, RoomMessage(kind: Ready, revision: sparse.revision, hash: 2))
doAssert not relay.guest(3).ready
relay.send(3, RoomMessage(kind: LeaveRoom))
doAssert relay.guest(host).ready and relay.guest(peer).ready
relay.send(1, RoomMessage(kind: ClaimSeat, seat: 9, name: "Bot"))
doAssert relay.guest(host).ready and relay.guest(peer).ready
relay.send(1, RoomMessage(kind: ReleaseSeat, seat: 9))
doAssert relay.guest(host).ready and relay.guest(peer).ready
relay.send(2, RoomMessage(kind: LeaveRoom))
doAssert relay.guest(host).ready
relay.expectError(1, RoomMessage(kind: StartMatch))
relay.send(1, RoomMessage(kind: Ready, revision: sparse.revision, hash: 3))
relay.send(1, RoomMessage(kind: StartMatch))
doAssert sparse.phase == Playing, "Empty slots must not block sparse start"
relay.send(1, RoomMessage(kind: AbortMatch, match: sparse.match, detail: "done"))
relay.send(1, RoomMessage(kind: ReturnLobby))
relay.send(1, RoomMessage(kind: Ready, revision: sparse.revision, hash: 3))
relay.send(1, RoomMessage(kind: ConfigureRoom, name: "mason :)'s game", number: 10, tickRate: 24, payload: "changed"))
doAssert sparse.name == "mason :)'s game"
doAssert relay.state(sparse).name == sparse.name
doAssert sparse.payload == "changed"
doAssert not relay.guest(host).ready
relay.send(1, RoomMessage(kind: ReleaseSeat, seat: 0))
doAssert not relay.guest(host).ready, "Releasing the last seat clears controller consent"
relay.expectError(1, RoomMessage(kind: Ready, revision: sparse.revision, hash: 3))
relay.expectError(1, RoomMessage(kind: StartMatch))

echo "Testing authoritative sparse Galcon startup and unchanged consent gates"
block:
  let galconRelay = Relay()
  let host = galconRelay.connect(1, "galcon")
  let peer = galconRelay.connect(2, "galcon")
  galconRelay.send(1, RoomMessage(kind: CreateRoom, name: "Sparse Galcon",
    number: 4, tickRate: 32))
  let room = galconRelay.rooms[0]
  galconRelay.send(2, RoomMessage(kind: JoinRoom, room: room.id))
  galconRelay.expectError(1, RoomMessage(kind: StartMatch)) # no controllers
  galconRelay.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
  galconRelay.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 7))
  galconRelay.send(2, RoomMessage(kind: ClaimSeat, seat: 3, name: "Human"))
  galconRelay.expectError(1, RoomMessage(kind: StartMatch)) # stale host proof
  galconRelay.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 7))
  galconRelay.expectError(1, RoomMessage(kind: StartMatch)) # unready peer
  galconRelay.send(2, RoomMessage(kind: Ready, revision: room.revision, hash: 7))
  galconRelay.expectError(2, RoomMessage(kind: StartMatch)) # host authorization
  galconRelay.expectError(1, RoomMessage(kind: ReleaseSeat, seat: 3))
  galconRelay.send(1, RoomMessage(kind: StartMatch))
  doAssert room.phase == Playing
  doAssert room.seats[0] == Seat() and room.seats[2] == Seat(),
    "Sparse startup must not implicitly fill bots"
  doAssert room.seats[1].owner == host and room.seats[3].owner == peer
  galconRelay.send(1, RoomMessage(kind: AbortMatch, match: room.match, detail: "done"))
  galconRelay.send(1, RoomMessage(kind: ReturnLobby))
  galconRelay.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 7))
  galconRelay.send(2, RoomMessage(kind: Ready, revision: room.revision, hash: 8))
  galconRelay.send(1, RoomMessage(kind: StartMatch))
  doAssert room.phase == Desynced, "Sparse controllers still require hash consensus"

# Other adapters retain their existing dense-roster requirement.
for game in ["light_vs_dark", "gods_of_the_arena", "unknown-adapter"]:
  let denseRelay = Relay()
  discard denseRelay.connect(1, game)
  denseRelay.send(1, RoomMessage(kind: CreateRoom, name: "Dense adapter",
    number: 2, tickRate: 24))
  let room = denseRelay.rooms[0]
  denseRelay.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
  denseRelay.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 7))
  denseRelay.expectError(1, RoomMessage(kind: StartMatch))
  doAssert room.phase == Lobby
  denseRelay.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Bot"))
  denseRelay.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 7))
  denseRelay.send(1, RoomMessage(kind: StartMatch))
  doAssert room.phase == Playing

echo "Testing host removal of one foreign bot slot without kicking its owner"
for game in ["galcon"]:
  let botRelay = Relay()
  let owner = botRelay.connect(1, game)
  let botOwner = botRelay.connect(2, game)
  discard botRelay.connect(3, game)
  botRelay.send(1, RoomMessage(kind: CreateRoom, name: "Bot removal",
    number: 5, tickRate: 24))
  let room = botRelay.rooms[0]
  botRelay.send(2, RoomMessage(kind: JoinRoom, room: room.id))
  botRelay.send(3, RoomMessage(kind: JoinRoom, room: room.id))
  botRelay.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
  botRelay.send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
  botRelay.send(2, RoomMessage(kind: ClaimSeat, seat: 2, name: "Selected bot"))
  botRelay.send(2, RoomMessage(kind: ClaimSeat, seat: 3, name: "Other bot"))
  botRelay.send(3, RoomMessage(kind: ClaimSeat, seat: 4, name: "Human"))
  for connection in 1 .. 3:
    botRelay.send(connection, RoomMessage(kind: Ready,
      revision: room.revision, hash: 42))
  let before = botRelay.state(room)
  botRelay.expectError(3, RoomMessage(kind: ReleaseSeat, seat: 2))
  botRelay.expectError(1, RoomMessage(kind: ReleaseSeat, seat: 1))
  botRelay.expectError(3, RoomMessage(kind: ReleaseSeat, seat: 1))
  doAssert botRelay.state(room) == before
  botRelay.send(1, RoomMessage(kind: ReleaseSeat, seat: 2))
  doAssert room.seats[2] == Seat()
  for seat in [0, 1, 3, 4]:
    doAssert room.seats[seat] == before.seats[seat]
  doAssert room.participants == @[owner, botOwner, 3'u32]
  doAssert botRelay.guest(botOwner).room == room.id
  doAssert botRelay.guest(botOwner).connection == 2
  doAssert room.revision == before.revision + 1
  for participant in room.participants:
    doAssert botRelay.guest(participant).ready
  botRelay.expectError(1, RoomMessage(kind: StartMatch))

echo "Sparse room readiness, bot removal and dense-adapter compatibility passed"
