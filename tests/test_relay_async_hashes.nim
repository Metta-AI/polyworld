import std/unittest
import polyworld/[rooms, relays]

proc send(relay: Relay, connection: int, message: RoomMessage) =
  relay.receive(connection, decode(message.encode()), 0)
  relay.outgoing.setLen(0)

proc fixture(): Relay =
  result = Relay()
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: Hello,
      identity: GameIdentity(game: "async-hashes", gameplay: 1, protocol: 1),
      name: "Guest " & $connection))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Async hashes",
    tickRate: 24, number: 2))
  let room = result.rooms[0]
  result.send(2, RoomMessage(kind: JoinRoom, room: room.id))
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: ClaimSeat,
      seat: uint32(connection - 1), name: "Seat"))
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: Ready,
      revision: room.revision, hash: 42))
  result.send(1, RoomMessage(kind: StartMatch))

proc advanceTo(relay: Relay, target: uint32, acknowledgeBoth = true) =
  let room = relay.rooms[0]
  while room.tick < target:
    let expected = room.tick + 1
    relay.advance(float64(expected) * 0.05)
    doAssert room.tick == expected, "Client verification must not gate tick production"
    doAssert room.phase == Playing
    for connection in 1 .. (if acknowledgeBoth: 2 else: 1):
      relay.send(connection, RoomMessage(kind: AppliedTick,
        match: room.match, tick: room.tick))

suite "Asynchronous historical hash verification":
  test "no hashes from either controller never stalls a second boundary":
    let relay = fixture()
    relay.advanceTo(100)
    check relay.rooms[0].history.len == 100

  test "first reporter may change at each checkpoint; late reports compare by tick":
    let relay = fixture()
    let room = relay.rooms[0]
    relay.advanceTo(24)
    relay.send(2, RoomMessage(kind: ReportHash, match: room.match, tick: 24, hash: 100))
    relay.advanceTo(48)
    relay.send(2, RoomMessage(kind: ReportHash, match: room.match, tick: 48, hash: 200))
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 24, hash: 100))
    relay.advanceTo(72)
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 48, hash: 200))
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 72, hash: 300))
    relay.advanceTo(100)
    relay.send(2, RoomMessage(kind: ReportHash, match: room.match, tick: 72, hash: 300))
    check room.phase == Playing

  test "a controller behind by more than six ticks does not stall peers":
    let relay = fixture()
    relay.advanceTo(100, acknowledgeBoth = false)
    check relay.rooms[0].tick == 100

  test "a disconnected controller does not stall peers or reconnect catchup":
    let relay = fixture()
    let room = relay.rooms[0]
    let token = relay.guests[1].token
    relay.advanceTo(2)
    relay.disconnect(2)
    check room.phase == Playing
    relay.advanceTo(48, acknowledgeBoth = false)
    relay.send(2, RoomMessage(kind: Hello, identity: room.identity,
      name: "Guest 2", token: token))
    relay.advanceTo(72, acknowledgeBoth = false)
    relay.send(2, RoomMessage(kind: Catchup, match: room.match, tick: 2))
    relay.advanceTo(100, acknowledgeBoth = false)

  test "slow controller delivery stays bounded while history remains available":
    let relay = fixture()
    let room = relay.rooms[0]
    relay.advanceTo(100, acknowledgeBoth = false)
    relay.outgoing.setLen(0)
    relay.advance(5.05)
    for output in relay.outgoing:
      if output.connection == 2:
        check decode(output.bytes).kind != TickPacket
    relay.outgoing.setLen(0)
    relay.receive(2, RoomMessage(kind: Catchup, match: room.match, tick: 0), 5.05)
    var delivered: seq[uint32]
    for output in relay.outgoing:
      if output.connection == 2:
        let message = decode(output.bytes)
        if message.kind == TickPacket: delivered.add message.tick
    check delivered.len == int(CatchupBatch)
    check delivered[0] == 1
    check delivered[^1] == CatchupBatch

  test "first controller finish ends the match; later finish is checked":
    let relay = fixture()
    let room = relay.rooms[0]
    relay.advanceTo(30)
    relay.send(1, RoomMessage(kind: FinishMatch, match: room.match, tick: 29, hash: 900))
    relay.advance(1.55)
    check room.phase == Ended
    check room.tick == 30
    relay.send(2, RoomMessage(kind: FinishMatch, match: room.match, tick: 29, hash: 900))
    check room.phase == Ended
    relay.send(2, RoomMessage(kind: FinishMatch, match: room.match, tick: 29, hash: 901))
    check room.phase == Desynced

  test "completed history exposes terminal tick without replaying overshoot":
    let relay = fixture()
    let room = relay.rooms[0]
    relay.advanceTo(40)
    relay.send(1, RoomMessage(kind: FinishMatch, match: room.match, tick: 29, hash: 900))
    relay.advance(2.05)
    for output in relay.outgoing:
      let message = decode(output.bytes)
      if message.kind == MatchStatus: check message.tick == 29
    check room.history.len == 40
    relay.outgoing.setLen(0)
    relay.receive(2, RoomMessage(kind: Catchup, match: room.match, tick: 25), 2.05)
    var delivered: seq[uint32]
    for output in relay.outgoing:
      let message = decode(output.bytes)
      if message.kind == TickPacket: delivered.add message.tick
      if message.kind == CaughtUp: check message.number == 29
    check delivered == @[26'u32, 27, 28, 29]

  test "spectator completion does not end a running room":
    let relay = fixture()
    let room = relay.rooms[0]
    relay.send(3, RoomMessage(kind: Hello, identity: room.identity, name: "Spectator"))
    relay.send(3, RoomMessage(kind: JoinRoom, room: room.id))
    relay.advanceTo(30)
    relay.send(3, RoomMessage(kind: FinishMatch, match: room.match, tick: 29, hash: 900))
    relay.advanceTo(40)

  test "completed reconnect accepts exact command retransmissions only":
    let relay = fixture()
    let room = relay.rooms[0]
    let command = RoomMessage(kind: SubmitCommand, match: room.match,
      seat: 0, sequence: 1, payload: "move")
    relay.send(1, command)
    relay.advanceTo(30)
    relay.send(1, RoomMessage(kind: FinishMatch, match: room.match, tick: 29, hash: 900))
    relay.advance(1.55)
    relay.send(1, command)
    var fresh = command
    fresh.sequence = 2
    expect RoomsError:
      relay.send(1, fresh)
    var changed = command
    changed.payload = "changed"
    expect RoomsError:
      relay.send(1, changed)

  test "older retransmitted hashes compare against their own checkpoint":
    let relay = fixture()
    let room = relay.rooms[0]
    relay.advanceTo(72)
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 24, hash: 100))
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 48, hash: 200))
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 24, hash: 100))
    check room.phase == Playing
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 24, hash: 101))
    check room.phase == Desynced

  test "final and periodic hashes share one checkpoint in either arrival order":
    for finishFirst in [false, true]:
      let relay = fixture()
      let room = relay.rooms[0]
      relay.advanceTo(48)
      relay.send(1, RoomMessage(kind: (if finishFirst: FinishMatch else: ReportHash),
        match: room.match, tick: 24, hash: 100))
      relay.send(2, RoomMessage(kind: (if finishFirst: ReportHash else: FinishMatch),
        match: room.match, tick: 24, hash: 101))
      check room.phase == Desynced

  test "late disagreement stops a match at its current tick":
    let relay = fixture()
    let room = relay.rooms[0]
    relay.advanceTo(48)
    relay.send(1, RoomMessage(kind: ReportHash, match: room.match, tick: 24, hash: 100))
    relay.advanceTo(72)
    relay.send(2, RoomMessage(kind: ReportHash, match: room.match, tick: 24, hash: 101))
    check room.phase == Desynced
    relay.advance(4)
    check room.tick == 72
