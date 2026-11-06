## Room lifetime follows connected people, never seat or bot occupancy.
import std/unittest
import polyworld/[rooms, relays]

proc send(r: Relay, c: int, m: RoomMessage, now = 0.0) =
  r.receive(c, decode(m.encode()), now)

proc connect(r: Relay, c: int, token = ""): Guest =
  r.send(c, RoomMessage(kind: Hello, name: "Person " & $c, token: token,
    identity: GameIdentity(game: "cleanup-test", gameplay: 1, protocol: 1)))
  for g in r.guests:
    if g.connection == c: return g

proc create(r: Relay): RelayRoom =
  r.send(1, RoomMessage(kind: CreateRoom, name: "Cleanup", number: 2,
    tickRate: 24, flag: true, payload: "setup"))
  r.rooms[0]

suite "Rooms require a connected person":
  test "last disconnect immediately deletes room and clears reconnect membership":
    let r = Relay()
    let host = r.connect(1)
    let room = r.create()
    let invite = room.id
    check r.room(invite) == room # Seatless creator is already a watcher.
    r.disconnect(1)
    check r.room(invite) == nil
    check r.rooms.len == 0
    check host.room == ""
    discard r.connect(2, host.token)
    check host.room == ""
    expect RoomsError: r.send(2, RoomMessage(kind: JoinRoom, room: invite))
    r.send(2, RoomMessage(kind: ListRooms))
    check decode(r.outgoing[^1].bytes).rooms.len == 0
    r.send(2, RoomMessage(kind: CreateRoom, name: "New room", number: 1,
      tickRate: 24))
    check r.rooms.len == 1

  test "last seatless watcher leaving deletes disconnected bot owner's room":
    let r = Relay()
    let host = r.connect(1)
    let room = r.create()
    let invite = room.id
    r.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Private bot"))
    let watcher = r.connect(2)
    r.send(2, RoomMessage(kind: JoinRoom, room: invite))
    r.disconnect(1)
    check r.room(invite) == room
    check watcher.room == invite
    r.send(2, RoomMessage(kind: LeaveRoom))
    check r.room(invite) == nil
    check host.room == ""
    check watcher.room == ""
    check decode(r.outgoing[^1].bytes).kind == RoomState
    check decode(r.outgoing[^1].bytes).room == ""

  test "all phases retire retained state after last person disconnects or times out":
    for phase in RoomPhase:
      for timeout in [false, true]:
        let r = Relay()
        let host = r.connect(1)
        let room = r.create()
        let invite = room.id
        r.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Private bot"))
        room.phase = phase
        room.paused = phase == Waiting
        room.pending = @[Command(participant: host.id, payload: "queued")]
        room.history = @["retained"]
        room.deadline = 100
        host.ready = true
        host.recovering = true
        if timeout: r.advance(16)
        else: r.disconnect(1)
        check r.room(invite) == nil
        check host.room == ""
        check not host.ready and not host.recovering
        check room.participants.len == 0
        check room.seats.len == 0
        check room.pending.len == 0
        check room.history.len == 0
        check room.deadline == 0
        check not room.paused
        r.advance(17)
        check r.rooms.len == 0

  test "seatless spectator preserves every phase until explicit Leave":
    for phase in RoomPhase:
      let r = Relay()
      let host = r.connect(1)
      let room = r.create()
      let invite = room.id
      r.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Private bot"))
      let watcher = r.connect(2)
      r.send(2, RoomMessage(kind: JoinRoom, room: invite))
      room.phase = phase
      room.paused = phase == Waiting
      r.disconnect(1)
      check r.room(invite) == room
      check watcher.room == invite and host.room == invite
      r.send(2, RoomMessage(kind: LeaveRoom))
      check r.room(invite) == nil
      check host.room == "" and watcher.room == ""

  test "explicit final Leave retires the departing controller's preparation":
    let r = Relay()
    let host = r.connect(1)
    let room = r.create()
    r.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
    r.send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 42))
    check host.ready
    r.send(1, RoomMessage(kind: LeaveRoom))
    check not host.ready
    check host.room == ""
    check r.rooms.len == 0

  test "connected bot-only owner remains a person without a human seat":
    let r = Relay()
    discard r.connect(1)
    let room = r.create()
    r.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Private bot"))
    r.advance(1)
    check r.room(room.id) == room
    r.send(1, RoomMessage(kind: ReleaseSeat, seat: 0))
    r.advance(2)
    check r.room(room.id) == room

  test "authenticated socket replacement never transiently empties a room":
    let r = Relay()
    let host = r.connect(1)
    let room = r.create()
    let invite = room.id
    discard r.connect(2, host.token)
    check r.room(invite) == room
    check host.connection == 2 and host.room == invite
    r.disconnect(1) # Delayed close from replaced socket.
    check r.room(invite) == room

  test "transport backpressure cannot leave an unwatched ghost room":
    let r = Relay()
    let host = r.connect(1)
    let room = r.create()
    let invite = room.id
    for i in 0 .. 10000:
      if host.connection == 0: break
      r.send(1, RoomMessage(kind: Keepalive), float64(i))
    check host.connection == 0
    r.advance(10001)
    check r.room(invite) == nil
    check host.room == ""
