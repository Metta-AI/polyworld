## Native binary-relay lifecycle regression; no fabricated BeginMatch or world edits.
import std/[unittest, macros, strutils, importutils]
import jsony, polyworld/[rooms, relays, roomclients, tapes]
import ../[multiplayer, presets, content, lobbyreadiness, controls, sim, replays]
when defined(liveSameRoomRematch):
  import std/[os, times]
  import windy, vmath, polyworld/connections

# Execute the real Esc return operation without importing the asset-backed UI.
macro loadReturnControl(): untyped =
  for node in parseStmt(staticRead("../ui.nim")):
    if node.kind == nnkProcDef and node[0].repr == "returnToMatchLobby*":
      return node
  error("Missing match return control")
privateAccess(RoomClient)
loadReturnControl()

macro rendererLobbyReturn(): untyped =
  # Execute the production callback's transition, not a parallel test policy.
  proc search(node: NimNode): NimNode =
    if node.kind == nnkIfStmt and node[0][0].repr == "network.reopenedLobby()":
      return node
    for child in node:
      let found = search(child)
      if found != nil: return found
  let found = search(parseStmt(staticRead("../graphics.nim")))
  if found == nil: error("Renderer does not yield on reopened lobby")
  found

type Fixture = ref object
  relay: Relay
  clients: array[2, RoomClient]
  sessions: array[2, NetworkMatch]
  readiness: array[2, ReadyRefresh]
  revisions: array[2, uint32]
  sources: array[2, seq[string]]
  inMatch: array[2, bool]
  now: float64
  when defined(liveSameRoomRematch):
    connections: array[2, Connection]
    window: Window

proc exchange(f: Fixture) =
  when defined(liveSameRoomRematch):
    let deadline = epochTime() + 0.08
    while epochTime() < deadline:
      pollEvents()
      for connection in f.connections:
        if connection != nil: connection.pump()
      sleep(2)
  else:
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

template awaitState(f: Fixture, condition: untyped) =
  for attempt in 0 ..< 60:
    if condition: break
    f.exchange()
  doAssert condition, "Timed out waiting for " & astToStr(condition)

proc frame(f: Fixture, i: int) =
  if f.inMatch[i]:
    # The renderer must yield to the frontend on authoritative Lobby, even
    # when this participant has not clicked the Esc return control.
    let network = f.sessions[i]
    var leaveMatch = false
    proc renderedFrame() =
      rendererLobbyReturn()
    renderedFrame()
    if not leaveMatch: return
    f.inMatch[i] = false
  discard f.readiness[i].refreshRetainedReady(f.clients[i], f.sources[i],
    f.sessions[i], f.revisions[i])

proc lobby(): Fixture =
  result = Fixture(relay: Relay())
  when defined(liveSameRoomRematch):
    result.window = newWindow("LvD rematch native socket test", ivec2(320, 180), visible = false)
  for i, name in ["Rematch host :)", "Guest Ω"]:
    when defined(liveSameRoomRematch):
      result.connections[i] = connect(getEnv("LVD_QA_SERVER", "ws://127.0.0.1:19941/ws"), name, lvdIdentity())
      result.clients[i] = result.connections[i].client
    else:
      result.clients[i] = RoomClient(identity: lvdIdentity(), name: name)
      result.clients[i].opened()
    result.exchange()
  when defined(liveSameRoomRematch):
    let deadline = epochTime() + 5
    while not (result.clients[0].welcomed and result.clients[1].welcomed) and epochTime() < deadline:
      result.exchange()
    doAssert result.clients[0].welcomed and result.clients[1].welcomed
  var config = defaultConfig(4)
  config.maxTicks = 96
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  result.clients[0].send(RoomMessage(kind: CreateRoom, name: "Same private room",
    number: 4, tickRate: uint32(TickRate), flag: false, payload: config.toJson()))
  result.exchange()
  result.awaitState(result.clients[0].snapshot.room.len > 0)
  result.clients[1].send(RoomMessage(kind: JoinRoom, room: result.clients[0].snapshot.room))
  result.exchange()
  result.awaitState(result.clients[1].snapshot.room == result.clients[0].snapshot.room)
  result.clients[0].claimHumanSeat(1)
  result.clients[0].send(RoomMessage(kind: ClaimSeat, seat: 0, name: "Private policy"))
  result.clients[1].claimHumanSeat(3)
  result.sources[0] = @[readFile("games/light_vs_dark/players/base.bas"), "", "", ""]
  result.sources[1] = @["", "", "", ""]
  result.exchange()
  let f = result
  let expected = @[Seat(owner: f.clients[0].participant, name: "Private policy"),
    Seat(owner: f.clients[0].participant, name: "Human"), Seat(),
    Seat(owner: f.clients[1].participant, name: "Human")]
  f.awaitState(f.clients[0].snapshot.seats == expected and f.clients[1].snapshot.seats == expected)

proc cleanup(f: Fixture) =
  for client in f.clients:
    if client.snapshot.phase in {Playing, Waiting}:
      client.send(RoomMessage(kind: AbortMatch, match: client.match, detail: "Private rematch test cleanup"))
  f.exchange()
  for client in f.clients:
    if client.snapshot.room.len > 0: client.send(RoomMessage(kind: LeaveRoom))
  for attempt in 0 ..< 20:
    f.exchange()
    if f.clients[0].snapshot.room.len == 0 and f.clients[1].snapshot.room.len == 0: break
  for client in f.clients: doAssert client.snapshot.room.len == 0
  when defined(liveSameRoomRematch):
    for connection in f.connections: connection.close()
    f.window.close()

proc playRound(f: Fixture): uint64 =
  f.clients[0].send(RoomMessage(kind: StartMatch))
  f.exchange()
  for frame in 0 ..< 5:
    for i in 0 .. 1: f.frame(i)
    f.exchange()
  doAssert f.clients[0].snapshot.phase == Playing,
    "Rematch stuck: guest still owns finished renderer, no new preparation"
  result = f.clients[0].match
  for i, session in f.sessions:
    doAssert f.clients[i].events.len == 1
    doAssert not session.started and not session.finished
    doAssert session.game.world.tick == 0
    doAssert session.playerSeats == @[0, 1, 3]
    doAssert session.humanPlayerFor(f.clients[i].participant) == i + 1
    doAssert not f.readiness[i].cosmeticReady
    doAssert (session.game.brains[0] != nil) == (i == 0)
    session.start(f.clients[i].events[0])
    f.clients[i].events.setLen(0)
    f.inMatch[i] = true
  f.exchange()
  var selected: array[2, int32]
  var initial: array[2, FixedVec2]
  for i, session in f.sessions:
    let world = session.game.world
    let player = int32(i + 1)
    for unit in world.units:
      if unit.owner == player:
        selected[i] = unit.id
        initial[i] = unit.body.pos
        break
    doAssert selected[i] != NoEntity
    let tile = world.units[world.unitIndex(selected[i])].tile
    var target = NoTile
    for dy in -3'i32 .. 3:
      for dx in -3'i32 .. 3:
        if (abs(dx) >= 2 or abs(dy) >= 2) and
            world.terrainOpen(int32(tile.x) + dx, int32(tile.y) + dy):
          target = tile2(int32(tile.x) + dx, int32(tile.y) + dy)
          break
      if target != NoTile: break
    doAssert target != NoTile
    let before = session.game.stateHash()
    queueMove(player, selected[i], int32(target.x), int32(target.y))
    session.flushSubmissions()
    doAssert session.game.stateHash() == before
  f.exchange()
  for frame in 0 ..< 120:
    f.now += 1.0 / float64(TickRate)
    f.relay.advance(f.now)
    f.exchange()
    for session in f.sessions: discard session.pump(8)
    f.exchange()
    let a = f.sessions[0].game.recorder.data.hashes
    let b = f.sessions[1].game.recorder.data.hashes
    for tick in 0 ..< min(a.len, b.len): doAssert a[tick] == b[tick]
    if f.sessions[0].game.world.tick == f.sessions[1].game.world.tick:
      doAssert f.sessions[0].game.networkHash() == f.sessions[1].game.networkHash()
    if f.sessions[0].finished and f.sessions[1].finished: break
  # FinishMatch is consumed by advance, not process.
  f.now += 1.0 / float64(TickRate)
  f.relay.advance(f.now)
  f.exchange()
  for i, session in f.sessions:
    doAssert session.finished and session.game.world.tick == 96
    doAssert f.clients[i].snapshot.phase == Ended
    doAssert f.clients[i].error.len == 0, f.clients[i].error
    let final = session.game.world.units[session.game.world.unitIndex(selected[i])].body.pos
    doAssert final != initial[i], "Human unit never moved in rematch"
    var accepted = 0
    for action in session.game.recorder.data.actions:
      if action.playerId == int32(i + 1) and action.kind == ActionMove: inc accepted
    doAssert accepted == 1
    let data = decodeReplay(encodeReplay(session.game.recorder.data))
    let playback = newGame(session.game.world.map, 96, data.header.setup.diplomacySettings)
    let cursor = initReplayPlayer(data)
    proc replay(world: World) =
      var action: ReplayAction
      while cursor.takeActionAt(uint32(world.tick), action):
        doAssert world.applyReplayAction(action)
    for tick in 0 ..< data.hashes.len:
      playback.world.tickWorld(replay)
      doAssert playback.stateHash() == data.hashes[tick]
    echo "ROUND match=", result, " human=", i, " tick=", session.game.world.tick,
      " moved=", final != initial[i], " replay hashes=", data.hashes.len

suite "LvD reusable same room":
  test "three rounds retain sparse seats private bot names settings and both humans":
    let f = lobby()
    defer: f.cleanup()
    let original = f.clients[0].snapshot
    let sources = f.sources
    var prior: uint64
    for round in 0 ..< 3:
      let current = f.playRound()
      check current != prior
      prior = current
      if round == 2: break
      if round == 1:
        # Guest returns manually before the owner, without leaving the room.
        check returnToMatchLobby(f.sessions[1])
        check f.clients[1].outgoing.len == 0
        f.inMatch[1] = false
      check returnToMatchLobby(f.sessions[0])
      f.inMatch[0] = false
      f.exchange()
      f.awaitState(f.clients[0].snapshot.phase == Lobby and f.clients[1].snapshot.phase == Lobby)
      for client in f.clients:
        check client.snapshot.phase == Lobby
        check client.snapshot.room == original.room
        check client.snapshot.seats == original.seats
        check client.snapshot.payload == original.payload
        check client.snapshot.name == original.name
        check not client.snapshot.flag
        check client.snapshot.participant == original.participant
        check client.snapshot.participants.len == original.participants.len
        for i, participant in client.snapshot.participants:
          check participant.id == original.participants[i].id
          check participant.name == original.participants[i].name
        check client.match == 0
        check client.applied == 0
        check client.sequence == 0
        check client.pending.len == 0
        check client.packets.len == 0
      check f.sources == sources

  test "reopened preparation failure retires old world and retries only next revision":
    let f = lobby()
    defer: f.cleanup()
    discard f.playRound()
    check returnToMatchLobby(f.sessions[0])
    f.exchange()
    f.inMatch = [false, false]
    f.sources[0][0] = "this is not BASIC !!!"
    var failures = 0
    for frame in 0 ..< 5:
      try: f.frame(0)
      except CatchableError: inc failures
    check failures == 1
    check f.sessions[0] == nil
    check f.revisions[0] == 0
    check f.clients[0].outgoing.len == 0
    f.sources[0][0] = readFile("games/light_vs_dark/players/base.bas")
    f.clients[0].send(RoomMessage(kind: ClaimSeat, seat: 0, name: "Repaired private policy"))
    f.exchange()
    f.frame(0)
    require f.sessions[0] != nil
    check not f.sessions[0].started
    check f.sessions[0].game.world.tick == 0
    check f.revisions[0] == f.clients[0].snapshot.revision
    check f.clients[0].outgoing.len == 1
    f.frame(0)
    check f.clients[0].outgoing.len == 1

  test "mismatched preparation desync can reopen without retry loops or seat resets":
    let f = lobby()
    defer: f.cleanup()
    f.frame(0)
    f.exchange()
    let revision = f.clients[0].snapshot.revision
    let wrongHash = f.sessions[0].game.networkHash() xor 1'u64
    f.clients[0].send(RoomMessage(kind: StartMatch))
    f.clients[1].send(RoomMessage(kind: Ready, revision: revision, hash: wrongHash))
    f.exchange()
    for client in f.clients:
      check client.snapshot.phase == Desynced
      check client.events.len == 0
    let originalSeats = f.clients[0].snapshot.seats
    for frame in 0 ..< 5: f.frame(0)
    check f.clients[0].outgoing.len == 0
    # The owner can reopen even if BeginMatch was never emitted.
    check returnToMatchLobby(f.sessions[0])
    f.exchange()
    for client in f.clients:
      client.error = ""
      check client.snapshot.phase == Lobby
      check client.snapshot.seats == originalSeats
    for i in 0 .. 1: f.frame(i)
    f.exchange()
    # Reopening must cancel the previous host intent.
    check f.clients[0].snapshot.phase == Lobby
    check f.clients[0].events.len == 0
    discard f.playRound()

  test "renderer routes reopened room back before flushing old match commands":
    const graphics = staticRead("../graphics.nim")
    let networkFrame = graphics.split("connection.stats.tickRate = int(TickRate)")[1]
    check networkFrame.contains("if network.reopenedLobby():")
    check networkFrame.find("if network.reopenedLobby():") < networkFrame.find("network.flushSubmissions()")
