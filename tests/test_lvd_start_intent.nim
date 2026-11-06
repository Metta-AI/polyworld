## LvD protocol 3 host intent is room-scoped, never cosmetic readiness.
import std/unittest
import polyworld/[rooms, relays]

proc send(r: Relay, c: int, m: RoomMessage) =
  r.receive(c, decode(m.encode()), 0)

proc lobby(game = "light_vs_dark", protocol = 3'u32): Relay =
  result = Relay()
  for c in 1 .. 3:
    result.send(c, RoomMessage(kind: Hello, name: "Human " & $c,
      identity: GameIdentity(game: game, gameplay: 1, protocol: protocol)))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Intent", number: 4,
    tickRate: 24, payload: "setup"))
  let room = result.rooms[0]
  for c in 2 .. 3:
    result.send(c, RoomMessage(kind: JoinRoom, room: room.id))
  result.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
  result.send(2, RoomMessage(kind: ClaimSeat, seat: 3, name: "Human"))

proc prepare(r: Relay, c: int, hash = 42'u64) =
  r.send(c, RoomMessage(kind: Prepared, revision: r.rooms[0].revision, hash: hash))

proc begins(r: Relay): int =
  for output in r.outgoing:
    if output.bytes.len > 0 and decode(output.bytes).kind == BeginMatch:
      inc result

suite "LvD queued host start lifetime":
  test "preparation alone never starts and cosmetic status is irrelevant":
    let r = lobby()
    let room = r.rooms[0]
    r.prepare(1)
    r.prepare(2)
    check room.phase == Lobby
    check r.begins() == 0
    r.send(1, RoomMessage(kind: ReadyStatus, flag: true))
    r.send(1, RoomMessage(kind: ReadyStatus, flag: false))
    r.send(1, RoomMessage(kind: StartMatch))
    check room.phase == Playing
    check not r.guest(1).ready and not r.guest(2).ready
    check room.seats[0] == Seat() and room.seats[2] == Seat()

  test "repeated host intent emits exactly one Begin per participant":
    let r = lobby()
    for i in 0 ..< 3: r.send(1, RoomMessage(kind: StartMatch))
    r.prepare(1)
    r.prepare(2)
    check r.rooms[0].match == 1
    check r.begins() == 3
    expect RoomsError: r.prepare(2)
    expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
    check r.rooms[0].match == 1
    check r.begins() == 3

  test "major configuration cancels intent including disguised resize":
    for operation in [ConfigureRoom, ResizeRoom]:
      let r = lobby()
      let room = r.rooms[0]
      r.send(1, RoomMessage(kind: StartMatch))
      r.send(1, RoomMessage(kind: operation, name: room.name, number: 4,
        tickRate: 24, payload: "changed map"))
      r.prepare(1)
      r.prepare(2)
      check room.phase == Lobby
      check r.begins() == 0
      r.send(1, RoomMessage(kind: StartMatch))
      check room.phase == Playing

  test "roster-only resize waits for both current revisions":
    let r = lobby()
    let room = r.rooms[0]
    r.prepare(1)
    r.send(1, RoomMessage(kind: StartMatch))
    let oldRevision = room.revision
    r.send(1, RoomMessage(kind: ResizeRoom, name: room.name, number: 5,
      tickRate: room.tickRate, payload: room.payload))
    expect RoomsError:
      r.send(2, RoomMessage(kind: Prepared, revision: oldRevision, hash: 42))
    r.prepare(2)
    check room.phase == Lobby
    r.prepare(1)
    check room.phase == Playing

  test "spectator join departure and kick do not cancel intent":
    for operation in [JoinRoom, LeaveRoom, KickParticipant]:
      let r = lobby()
      let room = r.rooms[0]
      if operation == JoinRoom: r.send(3, RoomMessage(kind: LeaveRoom))
      r.send(1, RoomMessage(kind: StartMatch))
      let revision = room.revision
      case operation
      of JoinRoom: r.send(3, RoomMessage(kind: JoinRoom, room: room.id))
      of LeaveRoom: r.send(3, RoomMessage(kind: LeaveRoom))
      else: r.send(1, RoomMessage(kind: KickParticipant, participant: 3))
      check room.revision == revision
      r.prepare(1)
      r.prepare(2)
      check room.phase == Playing

  test "controller departure requires refreshed surviving preparation":
    let r = lobby()
    let room = r.rooms[0]
    r.prepare(1)
    r.send(1, RoomMessage(kind: StartMatch))
    r.send(2, RoomMessage(kind: LeaveRoom))
    check room.phase == Lobby
    check r.begins() == 0
    r.prepare(1)
    check room.phase == Playing

  test "leaving owner cannot authorize successor even when seatless":
    for seatless in [false, true]:
      let r = lobby()
      let room = r.rooms[0]
      if seatless: r.send(1, RoomMessage(kind: ReleaseSeat, seat: 1))
      r.send(1, RoomMessage(kind: StartMatch))
      r.send(1, RoomMessage(kind: LeaveRoom))
      r.prepare(2)
      check room.owner == 2
      check room.phase == Lobby
      check r.begins() == 0
      r.send(2, RoomMessage(kind: StartMatch))
      check room.phase == Playing

  test "host disconnect cancels intent and reconnect cannot restore it":
    let r = lobby()
    let room = r.rooms[0]
    r.send(1, RoomMessage(kind: StartMatch))
    let host = r.guest(1)
    r.disconnect(1)
    r.prepare(2)
    check room.phase == Lobby
    r.send(1, RoomMessage(kind: Hello, name: host.name,
      identity: host.identity, token: host.token))
    r.prepare(1)
    check room.phase == Lobby
    r.send(1, RoomMessage(kind: StartMatch))
    check room.phase == Playing

  test "disconnected controller blocks start without failing another peer proof":
    let r = lobby()
    let room = r.rooms[0]
    r.send(1, RoomMessage(kind: StartMatch))
    let peer = r.guest(2)
    r.disconnect(2)
    r.prepare(1)
    check room.phase == Lobby
    expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
    r.send(2, RoomMessage(kind: Hello, name: peer.name,
      identity: peer.identity, token: peer.token))
    r.prepare(2)
    check room.phase == Playing

  test "already prepared reconnect completes pending start without a second proof":
    let r = lobby()
    let room = r.rooms[0]
    r.prepare(2)
    r.send(1, RoomMessage(kind: StartMatch))
    let peer = r.guest(2)
    r.disconnect(2)
    r.prepare(1)
    check room.phase == Lobby
    r.send(2, RoomMessage(kind: Hello, name: peer.name,
      identity: peer.identity, token: peer.token))
    check room.phase == Playing
    check r.begins() == 3

  test "empty roster cancels prior intent rather than starting a later roster":
    let r = lobby()
    let room = r.rooms[0]
    r.send(1, RoomMessage(kind: StartMatch))
    r.send(1, RoomMessage(kind: ReleaseSeat, seat: 1))
    r.send(2, RoomMessage(kind: ReleaseSeat, seat: 3))
    expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
    r.send(2, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
    r.prepare(2)
    check room.phase == Lobby
    check r.begins() == 0

  test "desync and ReturnLobby cannot carry an old intent into another match":
    let r = lobby()
    let room = r.rooms[0]
    r.send(1, RoomMessage(kind: StartMatch))
    r.prepare(1)
    r.prepare(2, 43)
    check room.phase == Desynced
    check r.begins() == 0
    r.send(1, RoomMessage(kind: ReturnLobby))
    r.prepare(1)
    r.prepare(2)
    check room.phase == Lobby
    r.send(1, RoomMessage(kind: StartMatch))
    check room.phase == Playing
    r.send(1, RoomMessage(kind: AbortMatch, match: room.match, detail: "Done"))
    r.send(1, RoomMessage(kind: ReturnLobby))
    r.prepare(1)
    r.prepare(2)
    check room.phase == Lobby
    check room.match == 1

  test "new room cannot reuse another room's numeric preparation revision":
    let r = lobby()
    let room = r.rooms[0]
    r.prepare(1)
    let oldRevision = room.revision
    r.send(1, RoomMessage(kind: LeaveRoom))
    r.send(1, RoomMessage(kind: CreateRoom, name: "Different", number: 4,
      tickRate: 24, payload: "different setup"))
    let other = r.rooms[1]
    r.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
    while other.revision < oldRevision:
      r.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
    r.send(1, RoomMessage(kind: StartMatch))
    check other.phase == Lobby
    check r.begins() == 0
    r.send(1, RoomMessage(kind: Prepared, revision: other.revision, hash: 99))
    check other.phase == Playing

  test "unrelated adapters retain their existing start gates":
    for game in ["other-game", "galcon", "light_vs_dark"]:
      let r = lobby(game, 1)
      expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
      r.prepare(1)
      r.prepare(2)
      check r.rooms[0].phase == Lobby
      expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
      check r.begins() == 0
