## Two real human controllers: binary RoomClient -> Relay -> controls -> sim.
import jsony
import polyworld/[rooms, roomclients, relays, tapes]
import ../[controls, game, maps, multiplayer, replays, sim]

proc scenario(hostSeat, guestSeat: int) =
  var relay = Relay()
  var now = 0.0
  let clients = [RoomClient(identity: gotaIdentity(), name: "Host"),
    RoomClient(identity: gotaIdentity(), name: "Guest")]
  proc exchange() =
    for attempt in 0 ..< 20:
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
      for client in clients:
        doAssert client.error.len == 0, client.error
      if not sent: return
    doAssert false, "exchange did not settle"
  for client in clients: client.opened()
  exchange()
  clients[0].send(RoomMessage(kind: CreateRoom, name: "Two humans", number: 10,
    tickRate: 24, payload: parseConfig("{\"maxTicks\":48}").toJson()))
  exchange()
  clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
  exchange()
  clients[0].claimHumanSeat(hostSeat)
  exchange()
  clients[1].claimHumanSeat(guestSeat)
  exchange()
  let host = clients[0].requestStart([])
  for client in clients:
    for participant in client.snapshot.participants:
      doAssert not participant.ready, "No human Ready clicks before startup"
  exchange()
  # The guest has not prepared anything before BeginMatch, just like frontend.
  let sessions = [host, prepareNetworkMatch(clients[1], [])]
  for i, session in sessions:
    doAssert session.humanHeroIndex() == i
    doAssert session.game.world.heroes.len == 2
    doAssert clients[i].events.len == 1
    session.start(clients[i].events[0])
    clients[i].events.setLen(0)
  exchange()
  var picks: array[2, int]
  var ticks = 0
  while not sessions[0].finished or not sessions[1].finished:
    # Mirror frontend's packed playerSlot and drawDraft's eligibility/hero ID.
    for i, session in sessions:
      run = session.game
      options.playerSlot = int32(session.humanHeroIndex() + 1)
      let playerIndex = options.playerSlot.int - 1
      let activeId = run.world.draftHeroId()
      if activeId != 0 and playerIndex == run.world.heroIndex(activeId):
        doAssert picks[i] == 0, "Human prompted to pick twice"
        inc picks[i]
        queueDraft(activeId, int32(i))
        session.flushSubmissions()
        doAssert run.world.draftHeroId() == activeId, "Submission must not mutate local world"
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
    doAssert sessions[0].game.stateHash() == sessions[1].game.stateHash()
    doAssert ticks < 100, "Draft timer froze"
  doAssert picks == [1, 1]
  doAssert sessions[0].game.world.battleTick() == 48
  let data = decodeReplay(encodeReplay(sessions[0].game.recorder.data))
  data.validate()
  doAssert data.actions.len == 2
  doAssert sessions[1].game.recorder.data.actions == data.actions
  doAssert sessions[1].game.recorder.data.hashes == data.hashes
  let replay = newGame(generateMap(data.config.seed, data.config.mapPreset),
    data.config.spawnIntervalTicks, 0, true, data)
  replay.historyPlayback = true
  replay.replayPlayer = initReplayPlayer(data)
  for tick in 0 ..< data.hashes.len: replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0
  doAssert replay.stateHash() == sessions[0].game.stateHash()
  echo "PASS seats=", hostSeat, "/", guestSeat, " picks=", picks,
    " battleTicks=48 hash=", replay.stateHash(), " replayTicks=", data.hashes.len

clearPlayerCommands()
scenario(0, 5)
scenario(1, 8)
