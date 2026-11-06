## Two naturally completed matches through the real SERVER state machine and
## binary RoomClients, including the production frontend's post-graphics route.
import std/[macros, os, strutils]
import jsony
import polyworld/[rooms, roomclients, relays, tapes, menus]
import ../[content, controls, game, maps, multiplayer, replays, sim]

# Exercise the real frontend transition without importing art/creating a window.
# Its enclosing variables are the same ones used by runFrontend.
macro afterGraphics(): untyped =
  let tree = parseStmt(readFile(currentSourcePath().parentDir.parentDir / "frontend.nim"))
  proc find(node: NimNode): NimNode =
    if node.kind == nnkStmtList:
      for i, child in node:
        if child.kind == nnkLetSection and child.len == 1 and
            child[0][0].eqIdent("quitToMenu"):
          result = newStmtList()
          for j in i + 1 ..< node.len:
            if node[j].kind == nnkContinueStmt: break
            result.add node[j]
          return
    for child in node:
      result = find(child)
      if result != nil: return
  result = find(tree)
  doAssert result != nil

type TestConnection = ref object
  client: RoomClient
proc close(connection: TestConnection) = discard
proc pump(connection: TestConnection) = discard

macro resultViewLoop(): untyped =
  let tree = parseStmt(readFile(currentSourcePath().parentDir.parentDir / "graphics.nim"))
  proc find(node: NimNode): NimNode =
    if node.kind == nnkWhileStmt and "leaveMatch" in node[0].repr:
      return node
    for child in node:
      result = find(child)
      if result != nil: return
  result = find(tree)
  doAssert result != nil

proc assertResultViewExits(network: NetworkMatch) =
  let connection = TestConnection(client: network.client)
  let window = (closeRequested: false,)
  var leaveMatch = false
  proc pollEvents() = doAssert false, "Must exit old graphics before another result frame"
  proc updateWindowSettings(window: tuple[closeRequested: bool]) = discard
  proc waitForDisplay() = discard
  resultViewLoop()
proc readPreferences(name: string): string = "preserved preferences"
const AppName = "test"

proc sameRoomRematch() =
  var relay = Relay()
  var now = 0.0
  let clients = [RoomClient(identity: gotaIdentity(), name: "Host"),
    RoomClient(identity: gotaIdentity(), name: "Guest")]
  proc exchange() =
    for attempt in 0 ..< 30:
      var sent = false
      for i, client in clients:
        let outgoing = client.outgoing
        client.outgoing = @[]
        for bytes in outgoing:
          relay.process(i + 1, bytes, now)
          sent = true
      var outgoing: seq[Outgoing]
      swap(outgoing, relay.outgoing)
      for output in outgoing:
        if output.bytes.len > 0:
          clients[output.connection - 1].accept(output.bytes)
          sent = true
      for client in clients: doAssert client.error.len == 0, client.error
      if not sent: return
    doAssert false, "exchange did not settle"
  for client in clients: client.opened()
  exchange()
  clients[0].send(RoomMessage(kind: CreateRoom, name: "Same room rematch", number: 10,
    tickRate: 24, flag: false, payload: parseConfig("{\"maxTicks\":48}").toJson()))
  exchange()
  clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
  exchange()
  clients[0].claimHumanSeat(0)
  clients[1].claimHumanSeat(5)
  clients[0].send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Private base bot"))
  exchange()
  var sources: array[HeroClassCount, string]
  sources[2] = readFile(currentSourcePath().parentDir.parentDir / "players/base.bas")
  let room = clients[0].snapshot.room
  let seats = clients[0].snapshot.seats
  let payload = clients[0].snapshot.payload
  let members = clients[0].snapshot.participants
  var previousMatch = 0'u32
  for round in 1 .. 2:
    doAssert clients[0].snapshot.phase == Lobby, "Return to lobby must reopen the same room"
    let sessions = [clients[0].requestStart(sources), prepareNetworkMatch(clients[1], [])]
    exchange()
    for i, session in sessions:
      doAssert not session.started and not session.finished
      doAssert session.game.world.tick == 0
      doAssert session.humanHeroIndex() == (if i == 0: 0 else: 2)
      doAssert clients[i].events.len == 1
      doAssert clients[i].events[0].match > previousMatch
      session.start(clients[i].events[0])
      clients[i].events.setLen(0)
    previousMatch = clients[0].match
    exchange()
    doAssert not sessions[0].returnedToLobby()
    doAssert not sessions[1].returnedToLobby()
    var picks: array[2, int]
    var ticks = 0
    while not sessions[0].finished or not sessions[1].finished:
      for i, session in sessions:
        run = session.game
        options.playerSlot = int32(session.humanHeroIndex() + 1)
        let active = run.world.draftHeroId()
        if active != 0 and run.world.heroIndex(active) == session.humanHeroIndex():
          doAssert picks[i] == 0
          inc picks[i]
          queueDraft(active, int32(i))
          session.flushSubmissions()
          doAssert run.world.draftHeroId() == active
      exchange()
      now += 1.0 / 24
      relay.advance(now)
      exchange()
      for i, session in sessions:
        while clients[i].packets.len > 0 and not session.finished:
          let packet = clients[i].packets[0]
          clients[i].packets.delete(0)
          session.applyPacket(packet)
      exchange()
      inc ticks
      doAssert ticks < 100
      doAssert sessions[0].game.networkHash() == sessions[1].game.networkHash()
    doAssert picks == [1, 1]
    for i, session in sessions:
      doAssert session.game.world.battleTick() == 48
      let data = decodeReplay(encodeReplay(session.game.recorder.data))
      data.validate()
      var humanPicks = 0
      for action in data.actions:
        if action.kind == ActionDraft and action.heroId in
            [session.game.world.heroes[0].id, session.game.world.heroes[2].id]:
          inc humanPicks
      doAssert humanPicks == 2
      doAssert data.hashes == sessions[1 - i].game.recorder.data.hashes
      let replay = newGame(generateMap(data.config.seed, data.config.mapPreset),
        data.config.spawnIntervalTicks, 0, true, data)
      replay.historyPlayback = true
      replay.replayPlayer = initReplayPlayer(data)
      for tick in 0 ..< data.hashes.len: replay.tickWorld(nil)
      doAssert replay.hashCheck.mismatches == 0
      doAssert replay.stateHash() == session.game.stateHash()
    echo "PASS round=", round, " match=", previousMatch, " picks=", picks,
      " battleTicks=48 hashes=", ticks, " serializedReplays=2"
    if round == 1:
      now += 1.0 / 24
      relay.advance(now)
      exchange()
      doAssert clients[0].snapshot.phase == rooms.Ended
      # Host presses Return to lobby, guest is still displaying its results.
      for participant in [1, 0]:
        var connection = TestConnection(client: clients[participant])
        var prepared = sessions[participant]
        var preparedRevision = prepared.revision
        var preferences, error: string
        var page, viewedRevision: int
        var multiplayerHuman = (if participant == 0: 0 else: 5)
        var networkPolicies: array[HeroClassCount, LocalPolicy]
        networkPolicies[2] = LocalPolicy(name: "Private base bot", bytes: sources[2])
        const HomeMenu = 0
        let quitToMenu = false
        afterGraphics()
        doAssert prepared == nil and preparedRevision == 0
        doAssert connection != nil
        doAssert multiplayerHuman == (if participant == 0: 0 else: 5)
        doAssert networkPolicies[2].bytes == sources[2]
        if participant == 1:
          doAssert clients[1].outgoing.len == 0, "Guest must not send ReturnLobby or LeaveRoom"
      exchange()
      doAssert sessions[1].returnedToLobby(), "Guest result view must retire on authoritative Lobby"
      assertResultViewExits(sessions[1])
      for client in clients:
        doAssert client.snapshot.phase == Lobby, "Return to lobby must reopen the same room"
        doAssert client.snapshot.room == room
        doAssert client.snapshot.seats == seats
        doAssert client.snapshot.payload == payload
        doAssert client.snapshot.participants.len == members.len
        for i, participant in client.snapshot.participants:
          doAssert participant.id == members[i].id and participant.connected
          doAssert not participant.ready
        doAssert client.match == 0 and client.serverTick == 0
        doAssert client.packets.len == 0
  now += 1.0 / 24
  relay.advance(now)
  exchange()
  clients[1].send(RoomMessage(kind: LeaveRoom))
  clients[0].send(RoomMessage(kind: LeaveRoom))
  exchange()
  for client in clients: doAssert client.snapshot.room.len == 0
  clearPlayerCommands()
  run = nil

sameRoomRematch()
