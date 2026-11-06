## In-process binary relay integration, not a browser or fabricated BeginMatch.
import std/unittest
import jsony, polyworld/[rooms, relays, roomclients, tapes]
import ../[multiplayer, presets, content, lobbyreadiness, controls, sim, replays]

type Fixture = ref object
  relay: Relay
  clients: array[2, RoomClient]
  sessions: array[2, NetworkMatch]
  readiness: array[2, ReadyRefresh]
  revisions: array[2, uint32]
  now: float64

proc exchange(f: Fixture) =
  for iteration in 0 ..< 30:
    var sent = false
    for i, client in f.clients:
      if client == nil: continue
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        f.relay.process(i + 1, bytes, f.now)
        sent = true
    let outgoing = f.relay.outgoing
    f.relay.outgoing = @[]
    for output in outgoing:
      if output.bytes.len > 0:
        f.clients[output.connection - 1].accept(output.bytes)
        sent = true
    if not sent: return
  doAssert false, "Relay exchange did not settle"

proc lobby(): Fixture =
  result = Fixture(relay: Relay())
  for i, name in ["Host", "Guest"]:
    result.clients[i] = RoomClient(identity: lvdIdentity(), name: name)
    result.clients[i].opened()
    result.exchange()
  var config = defaultConfig(4)
  config.maxTicks = 12
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  result.clients[0].send(RoomMessage(kind: CreateRoom, name: "Automatic start",
    number: 4, tickRate: uint32(TickRate), flag: false, payload: config.toJson()))
  result.exchange()
  result.clients[1].send(RoomMessage(kind: JoinRoom, room: result.clients[0].snapshot.room))
  result.exchange()
  result.clients[0].claimHumanSeat(1)
  result.clients[1].claimHumanSeat(3)
  result.exchange()

proc prepare(f: Fixture, index: int): bool =
  f.readiness[index].refreshRetainedReady(f.clients[index], [],
    f.sessions[index], f.revisions[index])

suite "LvD automatic two-human start":
  test "host starts before either preparation with unused seats and neither Ready":
    let f = lobby()
    let host = f.clients[0]
    let guest = f.clients[1]
    host.send(RoomMessage(kind: StartMatch))
    f.exchange()
    check host.snapshot.phase == Lobby
    check host.error == ""
    check f.prepare(0)
    f.exchange()
    check host.snapshot.phase == Lobby
    check host.events.len == 0
    check f.prepare(1)
    f.exchange()
    require host.snapshot.phase == Playing
    require guest.snapshot.phase == Playing
    for i, session in f.sessions:
      check not f.readiness[i].cosmeticReady
      check f.clients[i].error == ""
      check session.game.world.players.len == 2
      check session.humanPlayerFor(f.clients[i].participant) == i
      require f.clients[i].events.len == 1
      session.start(f.clients[i].events[0])
    f.exchange()
    # Outer commands must retain stable sparse seat IDs, not packed player IDs.
    host.send(RoomMessage(kind: SubmitCommand, match: host.match,
      seat: 3, sequence: 1, payload: "forged guest command"))
    guest.send(RoomMessage(kind: SubmitCommand, match: guest.match,
      seat: 1, sequence: 1, payload: "forged host command"))
    f.exchange()
    check host.error == "Command seat is not owned by this participant"
    check guest.error == "Command seat is not owned by this participant"
    check f.relay.rooms[0].pending.len == 0
    host.error = ""
    guest.error = ""
    for i, session in f.sessions:
      for unit in session.game.world.units:
        if unit.owner == int32(i):
          queueMove(int32(i), unit.id, int32(unit.tile.x), int32(unit.tile.y))
          break
      session.flushSubmissions()
    f.exchange()
    require f.relay.rooms[0].pending.len == 2
    for i, command in f.relay.rooms[0].pending:
      check command.participant == f.clients[i].participant
      check command.seat == uint32([1, 3][i])
      check command.sequence == 1
    for iteration in 0 ..< 60:
      f.now += 1.0 / float64(TickRate)
      f.relay.advance(f.now)
      f.exchange()
      for session in f.sessions: discard session.pump(16)
      f.exchange()
      check f.sessions[0].game.networkHash() == f.sessions[1].game.networkHash()
      if f.sessions[0].finished and f.sessions[1].finished: break
    for session in f.sessions:
      check session.finished
      check session.game.world.tick == 12
      let data = decodeReplay(encodeReplay(session.game.recorder.data))
      check data.actions.len == 2
      check data.header.setup.players.len == 2
      let playback = newGame(session.game.world.map, 12, data.header.setup.diplomacySettings)
      let cursor = initReplayPlayer(data)
      proc replay(w: World) =
        var action: ReplayAction
        while cursor.takeActionAt(uint32(w.tick), action):
          doAssert w.applyReplayAction(action)
      for tick in 1 .. data.hashes.len:
        playback.world.tickWorld(replay)
        check playback.stateHash() == data.hashes[tick - 1]

  test "guest cannot queue a start even when all automatic preparations complete":
    let f = lobby()
    f.clients[1].send(RoomMessage(kind: StartMatch))
    f.exchange()
    check f.clients[1].error.len > 0
    check f.prepare(0)
    check f.prepare(1)
    f.exchange()
    check f.clients[0].snapshot.phase == Lobby
    check f.clients[0].events.len == 0

  test "queued Start waits for refreshed roster revision and rejects stale Ready":
    let f = lobby()
    check f.prepare(0)
    f.exchange()
    let staleRevision = f.revisions[0]
    let staleHash = f.sessions[0].game.networkHash()
    f.clients[0].send(RoomMessage(kind: StartMatch))
    f.exchange()
    f.clients[1].send(RoomMessage(kind: ReleaseSeat, seat: 3))
    f.clients[1].claimHumanSeat(2)
    f.exchange()
    f.clients[1].send(RoomMessage(kind: Ready, revision: staleRevision, hash: staleHash))
    f.exchange()
    check f.clients[1].error.len > 0
    check f.clients[0].snapshot.phase == Lobby
    check f.clients[0].events.len == 0
    f.clients[1].error = ""
    check f.prepare(1)
    f.exchange()
    check f.clients[0].snapshot.phase == Lobby
    check f.prepare(0)
    f.exchange()
    check f.clients[0].snapshot.phase == Playing
    check f.revisions[0] == f.clients[0].snapshot.revision
    check f.sessions[0].game.networkHash() == f.sessions[1].game.networkHash()

  test "hash disagreement never emits BeginMatch":
    let f = lobby()
    f.clients[0].send(RoomMessage(kind: StartMatch))
    f.exchange()
    check f.prepare(0)
    f.exchange()
    let wrongHash = f.sessions[0].game.networkHash() xor 1'u64
    f.clients[1].send(RoomMessage(kind: Ready,
      revision: f.clients[1].snapshot.revision, hash: wrongHash))
    f.exchange()
    check f.clients[0].snapshot.phase == Desynced
    for client in f.clients:
      check client.events.len == 0
      check not client.began

  test "old protocol cannot join the new packed-seat room":
    let f = lobby()
    let host = f.clients[0]
    f.clients[1].send(RoomMessage(kind: LeaveRoom))
    f.exchange()
    f.relay.disconnect(2)
    f.clients[1] = RoomClient(identity: lvdIdentity(), name: "Old version")
    dec f.clients[1].identity.protocol
    f.clients[1].opened()
    f.exchange()
    f.clients[1].send(RoomMessage(kind: JoinRoom, room: host.snapshot.room))
    f.exchange()
    check f.clients[1].error.len > 0
    check f.clients[1].snapshot.room.len == 0
    check host.snapshot.phase == Lobby
