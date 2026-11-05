import std/unittest
import polyworld/[rooms, relays]

proc send(relay: Relay, connection: int, message: RoomMessage) =
  ## Exercise the existing wire envelope without loading a game.
  relay.receive(connection, decode(message.encode()), 0)

proc lobby(): Relay =
  result = Relay()
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(
      kind: Hello, name: "Guest " & $connection,
      identity: GameIdentity(game: "resize-test", gameplay: 1, protocol: 1)
    ))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Original", number: 3,
    tickRate: 24, payload: "original payload", flag: false))
  let room = result.rooms[0]
  result.send(2, RoomMessage(kind: JoinRoom, room: room.id))
  result.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Host"))
  result.send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Guest bot"))
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: Ready,
      revision: room.revision, hash: 42))
  result.outgoing = @[]

proc configure(count: uint32): RoomMessage =
  RoomMessage(kind: ConfigureRoom, name: "Resized", number: count,
    tickRate: 30, payload: "\x00\xffopaque resized setup", flag: true)

proc expectUnchanged(relay: Relay, connection: int, message: RoomMessage) =
  ## Rejections must preserve the entire lobby snapshot and its visibility.
  let
    room = relay.rooms[0]
    before = relay.state(room).encode()
    wasPublic = room.public
    outgoingCount = relay.outgoing.len
  expect RoomsError:
    relay.send(connection, message)
  check relay.state(room).encode() == before
  check room.public == wasPublic
  check relay.outgoing.len == outgoingCount

suite "Generic relay lobby seat resize":
  test "owner grows with empty seats preserving assignments and invalidating readiness":
    let
      relay = lobby()
      room = relay.rooms[0]
      before = relay.state(room)
      message = configure(5)
    relay.send(1, message)
    check room.seats.len == 5
    check room.seats[0 ..< 3] == before.seats
    check room.seats[3 ..< 5] == @[Seat(), Seat()]
    check room.revision == before.revision + 1
    check room.payload == message.payload
    check room.name == message.name
    check room.tickRate == message.tickRate
    check room.public
    for id in room.participants:
      check not relay.guest(id).ready
    check relay.outgoing.len == 2
    for output in relay.outgoing:
      let snapshot = decode(output.bytes)
      check snapshot.kind == RoomState
      check snapshot.seats == room.seats
      check snapshot.payload == message.payload
      check snapshot.revision == room.revision
      for participant in snapshot.participants:
        check not participant.ready
    expect RoomsError:
      relay.send(1, RoomMessage(kind: Ready, revision: before.revision, hash: 42))
    relay.send(1, RoomMessage(kind: ClaimSeat, seat: 4, name: "New bot"))
    check room.seats[4] == Seat(owner: room.owner, name: "New bot")

  test "owner shrinks an empty tail preserving another participant's retained seat":
    let
      relay = lobby()
      room = relay.rooms[0]
      before = relay.state(room)
      message = configure(2)
    relay.send(1, message)
    check room.seats == before.seats[0 ..< 2]
    check room.payload == message.payload
    check room.revision == before.revision + 1
    for id in room.participants:
      check not relay.guest(id).ready

  test "shrink cannot remove another participant's seat":
    let relay = lobby()
    relay.expectUnchanged(1, configure(1))

  test "owner can remove host-owned and empty seats down to one":
    let
      relay = lobby()
      room = relay.rooms[0]
    relay.send(2, RoomMessage(kind: ReleaseSeat, seat: 1))
    relay.send(1, RoomMessage(kind: ClaimSeat, seat: 2, name: "Host bot"))
    for connection in 1 .. 2:
      relay.send(connection, RoomMessage(kind: Ready,
        revision: room.revision, hash: 42))
    let before = relay.state(room)
    relay.send(1, configure(1))
    check room.seats == @[before.seats[0]]
    check room.revision == before.revision + 1
    for id in room.participants:
      check not relay.guest(id).ready
    relay.send(1, configure(3))
    check room.seats == @[before.seats[0], Seat(), Seat()]

  test "shrink checks the entire tail before changing any state":
    let
      relay = lobby()
      room = relay.rooms[0]
    relay.send(2, RoomMessage(kind: ReleaseSeat, seat: 1))
    relay.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Host bot"))
    relay.send(2, RoomMessage(kind: ClaimSeat, seat: 2, name: "Guest bot"))
    for connection in 1 .. 2:
      relay.send(connection, RoomMessage(kind: Ready,
        revision: room.revision, hash: 42))
    relay.expectUnchanged(1, configure(1))

  test "disconnected participants retain protection against shrink":
    let relay = lobby()
    relay.disconnect(2)
    relay.expectUnchanged(1, configure(1))

  test "growth accepts MaxSeats without changing old assignments":
    let
      relay = lobby()
      room = relay.rooms[0]
      before = relay.state(room)
    relay.send(1, configure(uint32(MaxSeats)))
    check room.seats.len == MaxSeats
    check room.seats[0 ..< 3] == before.seats
    for index in 3 ..< MaxSeats:
      check room.seats[index] == Seat()

  test "unchanged count still updates opaque settings and invalidates readiness":
    let
      relay = lobby()
      room = relay.rooms[0]
      before = relay.state(room)
      message = configure(3)
    relay.send(1, message)
    check room.seats == before.seats
    check room.payload == message.payload
    check room.revision == before.revision + 1
    for id in room.participants:
      check not relay.guest(id).ready

  test "invalid seat counts leave the complete configuration untouched":
    for count in [0'u32, uint32(MaxSeats + 1), uint32.high]:
      let relay = lobby()
      relay.expectUnchanged(1, configure(count))

  test "invalid settings cannot partially resize or replace the payload":
    for count in [2'u32, 3'u32, 5'u32]:
      for tickRate in [0'u32, 121'u32]:
        let relay = lobby()
        var message = configure(count)
        message.tickRate = tickRate
        relay.expectUnchanged(1, message)
      let relay = lobby()
      var message = configure(count)
      message.name = ""
      relay.expectUnchanged(1, message)

  test "nonowner cannot grow shrink or reconfigure":
    for count in [2'u32, 3'u32, 5'u32]:
      let relay = lobby()
      relay.expectUnchanged(2, configure(count))

  test "owner cannot resize or reconfigure outside Lobby":
    for phase in [Playing, Waiting, Ended, Desynced]:
      for count in [2'u32, 3'u32, 5'u32]:
        let relay = lobby()
        relay.rooms[0].phase = phase
        relay.expectUnchanged(1, configure(count))
