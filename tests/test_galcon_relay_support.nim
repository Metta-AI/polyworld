import std/unittest
import polyworld/[rooms, relays]

proc send(relay: Relay, connection: int, message: RoomMessage) =
  relay.receive(connection, decode(message.encode()), 0)

proc fixture(public: bool): Relay =
  result = Relay()
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: Hello,
      identity: GameIdentity(game: "galcon", gameplay: 7, protocol: 1),
      name: "Guest " & $connection))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Galcon support",
    number: 4, tickRate: 32, flag: public,
    payload: "{\"players\":4,\"seed\":7,\"map\":\"same\"}"))
  let room = result.rooms[0]
  result.send(2, RoomMessage(kind: JoinRoom, room: room.id))
  result.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
  result.send(2, RoomMessage(kind: ClaimSeat, seat: 3, name: "Human"))
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: Ready,
      revision: room.revision, hash: 42))

proc resize(room: RelayRoom, payload: string): RoomMessage =
  RoomMessage(kind: ResizeRoom, name: room.name, number: 5,
    tickRate: room.tickRate, payload: payload, flag: room.public)

suite "Galcon relay dependency boundaries":
  test "roster-only JSON resize preserves intent but requires fresh revision proofs":
    for public in [false, true]:
      let relay = fixture(public)
      let room = relay.rooms[0]
      let oldRevision = room.revision
      check relay.state(room).flag == public
      relay.send(1, room.resize("{\"players\":5,\"seed\":7,\"map\":\"same\"}"))
      check room.seats.len == 5
      check room.seats[1].owner == 1 and room.seats[3].owner == 2
      check room.revision == oldRevision + 1
      check relay.guest(1).ready and relay.guest(2).ready
      check relay.state(room).flag == public
      expect RoomsError:
        relay.send(1, RoomMessage(kind: StartMatch))
      for connection in 1 .. 2:
        relay.send(connection, RoomMessage(kind: Ready,
          revision: room.revision, hash: 43))
      relay.send(1, RoomMessage(kind: StartMatch))
      check room.phase == Playing
      check not relay.state(room).flag # Match flag means pause, not visibility.

  test "map changes and mismatched player counts cannot masquerade as roster-only":
    for payload in [
        "{\"players\":5,\"seed\":8,\"map\":\"same\"}",
        "{\"players\":6,\"seed\":7,\"map\":\"same\"}",
        "not JSON"]:
      let relay = fixture(false)
      let room = relay.rooms[0]
      relay.send(1, room.resize(payload))
      check not relay.guest(1).ready and not relay.guest(2).ready
      expect RoomsError:
        relay.send(1, RoomMessage(kind: StartMatch))

  test "rename preserves visibility and intent with unchanged payload":
    for public in [false, true]:
      let relay = fixture(public)
      let room = relay.rooms[0]
      var message = room.resize(room.payload)
      message.number = uint32(room.seats.len)
      message.name = "mason :)'s game"
      relay.send(1, message)
      check room.name == message.name
      check room.public == public and relay.state(room).flag == public
      check relay.guest(1).ready and relay.guest(2).ready
      expect RoomsError:
        relay.send(1, RoomMessage(kind: StartMatch))

  test "kick is host-only and removes only the selected participant":
    let relay = fixture(false)
    let room = relay.rooms[0]
    let before = relay.state(room)
    expect RoomsError:
      relay.send(2, RoomMessage(kind: KickParticipant, participant: 1))
    expect RoomsError:
      relay.send(1, RoomMessage(kind: KickParticipant, participant: 1))
    check relay.state(room) == before
    relay.send(1, RoomMessage(kind: KickParticipant, participant: 2))
    check room.participants == @[1'u32]
    check room.seats[1].owner == 1 and room.seats[3] == Seat()
    check relay.guest(2).room == ""
    check relay.guest(1).ready
    expect RoomsError:
      relay.send(1, RoomMessage(kind: StartMatch))
