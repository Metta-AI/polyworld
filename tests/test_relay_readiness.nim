import std/unittest
import polyworld/[rooms, relays]

proc send(relay: Relay, connection: int, message: RoomMessage) =
  ## Exercise the actual wire envelope, without depending on a game backend.
  relay.receive(connection, decode(message.encode()), 0)

proc lobby(): Relay =
  result = Relay()
  for connection in 1 .. 3:
    result.send(connection, RoomMessage(kind: Hello,
      name: "Guest " & $connection,
      identity: GameIdentity(game: "readiness-test", gameplay: 1, protocol: 1)))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Readiness", number: 1,
    tickRate: 24, payload: "opaque setup"))
  result.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
  result.send(1, RoomMessage(kind: Ready,
    revision: result.rooms[0].revision, hash: 42))
  result.outgoing = @[]

suite "Generic relay membership readiness":
  test "joining spectator preserves ready owner and setup revision":
    let
      relay = lobby()
      room = relay.rooms[0]
      revision = room.revision
    relay.send(2, RoomMessage(kind: JoinRoom, room: room.id))
    check room.revision == revision
    check relay.guest(1).ready
    check not relay.guest(2).ready
    check room.participants == @[1'u32, 2'u32]
    check relay.outgoing.len == 2
    for output in relay.outgoing:
      let snapshot = decode(output.bytes)
      check snapshot.kind == RoomState
      check snapshot.revision == revision
      check snapshot.participants[0].ready
      check not snapshot.participants[1].ready
    # An unready spectator must not prevent the already prepared host starting.
    relay.send(1, RoomMessage(kind: StartMatch))
    check room.phase == Playing
    let begin = decode(relay.outgoing[^3].bytes)
    check begin.kind == BeginMatch
    check begin.revision == revision
    check begin.hash == 42

  test "spectator departure preserves readiness including owner succession":
    for departing in [1, 2]:
      let
        relay = lobby()
        room = relay.rooms[0]
      relay.send(2, RoomMessage(kind: JoinRoom, room: room.id))
      if departing == 1:
        relay.send(1, RoomMessage(kind: ReleaseSeat, seat: 0))
        relay.send(2, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
      let
        remaining = if departing == 1: 2'u32 else: 1'u32
      relay.send(int(remaining), RoomMessage(kind: Ready,
        revision: room.revision, hash: 42))
      check not relay.guest(uint32(departing)).ready
      let revision = room.revision
      relay.outgoing = @[]
      relay.send(departing, RoomMessage(kind: LeaveRoom))
      check room.revision == revision
      check room.owner == remaining
      check room.participants == @[remaining]
      check relay.guest(remaining).ready
      check relay.guest(uint32(departing)).room == ""
      check relay.outgoing.len == 2
      check decode(relay.outgoing[0].bytes).room == ""
      let snapshot = decode(relay.outgoing[1].bytes)
      check snapshot.revision == revision
      check snapshot.participant == remaining
      check snapshot.participants[0].ready
      relay.send(int(remaining), RoomMessage(kind: StartMatch))
      check room.phase == Playing

  test "kicking a spectator preserves ready owner and revision":
    let
      relay = lobby()
      room = relay.rooms[0]
      revision = room.revision
    relay.send(2, RoomMessage(kind: JoinRoom, room: room.id))
    relay.outgoing = @[]
    relay.send(1, RoomMessage(kind: KickParticipant, participant: 2))
    check room.revision == revision
    check relay.guest(1).ready
    check relay.guest(2).room == ""
    check room.participants == @[1'u32]
    check relay.outgoing.len == 2
    check decode(relay.outgoing[0].bytes).room == ""
    let snapshot = decode(relay.outgoing[1].bytes)
    check snapshot.revision == revision
    check snapshot.participants[0].ready
    relay.send(1, RoomMessage(kind: StartMatch))
    check room.phase == Playing

  test "controller departure retains intent but refill requires fresh matching hashes":
    for kick in [false, true]:
      let
        relay = lobby()
        room = relay.rooms[0]
      relay.send(1, RoomMessage(kind: ConfigureRoom, name: room.name,
        number: 2, tickRate: room.tickRate, payload: room.payload))
      relay.send(2, RoomMessage(kind: JoinRoom, room: room.id))
      relay.send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
      for connection in 1 .. 2:
        relay.send(connection, RoomMessage(kind: Ready,
          revision: room.revision, hash: 42))
      let oldRevision = room.revision
      if kick:
        relay.send(1, RoomMessage(kind: KickParticipant, participant: 2))
      else:
        relay.send(2, RoomMessage(kind: LeaveRoom))
      check relay.guest(1).ready
      check room.revision == oldRevision + 1
      check room.seats[1] == Seat()
      expect RoomsError:
        relay.send(1, RoomMessage(kind: StartMatch))
      expect RoomsError:
        relay.send(1, RoomMessage(kind: Ready, revision: oldRevision, hash: 42))
      relay.send(3, RoomMessage(kind: JoinRoom, room: room.id))
      check not relay.guest(3).ready
      relay.send(3, RoomMessage(kind: ClaimSeat, seat: 1, name: "Replacement"))
      check relay.guest(1).ready
      check not relay.guest(3).ready
      # A replacement reporting the SAME old hash must not bless the host's
      # old preparation: revision freshness is independent of hash equality.
      relay.send(3, RoomMessage(kind: Ready, revision: room.revision, hash: 42))
      expect RoomsError:
        relay.send(1, RoomMessage(kind: StartMatch))
      check room.phase == Lobby
      for connection in [1, 3]:
        relay.send(connection, RoomMessage(kind: Ready,
          revision: room.revision, hash: 99))
      relay.send(1, RoomMessage(kind: StartMatch))
      check room.phase == Playing

  test "current revision still requires agreeing controller hashes":
    let
      relay = lobby()
      room = relay.rooms[0]
    relay.send(1, RoomMessage(kind: ConfigureRoom, name: room.name,
      number: 2, tickRate: room.tickRate, payload: room.payload))
    relay.send(2, RoomMessage(kind: JoinRoom, room: room.id))
    relay.send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
    relay.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 42))
    relay.send(2, RoomMessage(kind: Ready, revision: room.revision, hash: 99))
    relay.send(1, RoomMessage(kind: StartMatch))
    check room.phase == Desynced

  test "settings changes invalidate readiness and reject stale setup confirmations":
    let
      relay = lobby()
      room = relay.rooms[0]
      revision = room.revision
    relay.send(1, RoomMessage(kind: ConfigureRoom, name: room.name,
      number: 1, tickRate: room.tickRate, payload: "changed setup"))
    check room.revision == revision + 1
    check not relay.guest(1).ready
    expect RoomsError:
      relay.send(1, RoomMessage(kind: Ready, revision: revision, hash: 42))
    expect RoomsError:
      relay.send(1, RoomMessage(kind: StartMatch))
    relay.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 99))
    relay.send(1, RoomMessage(kind: StartMatch))
    check room.phase == Playing
