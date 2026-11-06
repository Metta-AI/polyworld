## Two HUMAN controllers using the ordinary controls queue and binary relay.
## Run headless normally; -d:liveHumanCombat uses LVD_QA_SERVER (9911 default).
import jsony
import polyworld/[rooms, roomclients, tapes]
when defined(liveHumanCombat):
  import std/[os, times]
  import windy, vmath
  import polyworld/connections
else:
  import polyworld/relays
import ../[attackorders, content, controls, multiplayer, presets, replays, sim]

proc twoHumanCombat*() =
  when not defined(liveHumanCombat):
    var relay = Relay()
    var now = 0.0
  when defined(liveHumanCombat):
    let window = newWindow("LvD two human socket regression", ivec2(320, 180), visible = false)
    let server = getEnv("LVD_QA_SERVER", "ws://127.0.0.1:9911/ws")
    let connections = [connect(server, "Combat host", lvdIdentity()),
      connect(server, "Combat guest", lvdIdentity())]
    let clients = [connections[0].client, connections[1].client]
    defer:
      for connection in connections:
        if connection.client.snapshot.room.len > 0 and
            connection.client.snapshot.phase in {Playing, Waiting}:
          connection.client.send(RoomMessage(kind: AbortMatch, match: connection.client.match,
            detail: "Private combat fixture cleanup"))
      let deadline = epochTime() + 2
      var leaving: array[2, bool]
      while epochTime() < deadline:
        pollEvents()
        for i, connection in connections:
          connection.pump()
          if not leaving[i] and connection.client.snapshot.phase notin {Playing, Waiting}:
            connection.client.send(RoomMessage(kind: LeaveRoom))
            leaving[i] = true
        if clients[0].snapshot.room.len == 0 and clients[1].snapshot.room.len == 0: break
        sleep(2)
      for connection in connections:
        echo "CLEANUP room=", connection.client.snapshot.room
        connection.close()
      window.close()
  else:
    let clients = [RoomClient(identity: lvdIdentity(), name: "Combat host"),
      RoomClient(identity: lvdIdentity(), name: "Combat guest")]
  proc exchange() =
    when defined(liveHumanCombat):
      let deadline = epochTime() + 0.1
      while epochTime() < deadline:
        pollEvents()
        for connection in connections: connection.pump()
        for client in clients: doAssert client.error.len == 0, client.error
        sleep(2)
    else:
      for attempt in 0 ..< 30:
        var sent = false
        for i, client in clients:
          var outgoing: seq[string]
          swap(outgoing, client.outgoing)
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
      doAssert false, "Relay exchange did not settle"
  when not defined(liveHumanCombat):
    for client in clients: client.opened()
  exchange()
  var config = defaultConfig(2)
  config.maxTicks = 2400
  var roomName = "Two human combat QA"
  when defined(liveHumanCombat): roomName.add " " & $getCurrentProcessId() & " " & $epochTime()
  clients[0].send(RoomMessage(kind: CreateRoom, name: roomName,
    number: 2, flag: false, tickRate: uint32(TickRate), payload: config.toJson()))
  exchange()
  clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
  exchange()
  for i, client in clients:
    client.claimHumanSeat(i)
    exchange()
  let sessions = [prepareNetworkMatch(clients[0], ["", ""]),
    prepareNetworkMatch(clients[1], ["", ""])]
  for i, session in sessions:
    doAssert clients[i].snapshot.humanSeatFor(clients[i].participant) == i
    for brain in session.game.brains: doAssert brain == nil
    clients[i].send(RoomMessage(kind: Ready, revision: session.revision,
      hash: session.game.networkHash()))
    exchange()
  clients[0].send(RoomMessage(kind: StartMatch))
  exchange()
  when defined(delayedHumanStartup):
    when defined(liveHumanCombat):
      # Model synchronous graphics/art startup after BeginMatch, before pumps.
      sleep(3000)
    else:
      # Advance the relay while neither human applies any history.
      for tick in 1 .. 72:
        now += 1.0 / float64(TickRate)
        relay.advance(now)
      exchange()
  for i, session in sessions:
    doAssert clients[i].events.len == 1
    session.start(clients[i].events[0])
    clients[i].events.setLen(0)
  exchange()
  var selected: array[2, int32]
  let centre = sessions[0].game.world.map.side div 2
  for i, session in sessions:
    for unit in session.game.world.units:
      if unit.owner == int32(i):
        selected[i] = unit.id
        break
    queueMove(int32(i), selected[i], centre + int32(i), centre)
    session.flushSubmissions()
  var attacked = false
  var initialHp: array[2, int32]
  for frame in 1 .. 3000:
    let world = sessions[0].game.world
    if not attacked and world.tick >= 600:
      attacked = true
      for i, session in sessions:
        initialHp[i] = world.units[world.unitIndex(selected[i])].hp
        doAssert world.units[world.unitIndex(selected[i])].tile == tile2(centre + int32(i), centre)
        let before = session.game.stateHash()
        if i == 0:
          doAssert session.game.world.queueSelectedAttack(0, [selected[0]], selected[1])
        else:
          doAssert session.game.world.queueSelectedAttackMove(1, [selected[1]], centre - 3, centre)
        session.flushSubmissions()
        doAssert session.game.stateHash() == before, "Intent mutated local world"
    exchange()
    when not defined(liveHumanCombat):
      now += 1.0 / float64(TickRate)
      relay.advance(now)
    exchange()
    for session in sessions: discard session.pump(8)
    exchange()
    let a = sessions[0].game.recorder.data.hashes
    let b = sessions[1].game.recorder.data.hashes
    if a.len > 0 and a.len == b.len: doAssert a[^1] == b[^1]
    if sessions[0].finished and sessions[1].finished: break
  doAssert attacked
  let world = sessions[0].game.world
  for i in 0 .. 1:
    let index = world.unitIndex(selected[i])
    let hp = if index < 0: 0'i32 else: world.units[index].hp
    echo "COMBAT human=", i, " hp=", initialHp[i], " -> ", hp,
      " relation=", world.diplomacy.relation(0, 1).state
    doAssert hp < initialHp[i], "Default human FFA attacks caused no damage"
  doAssert not world.entityAlive(selected[0]) or not world.entityAlive(selected[1]),
    "Actual combat must kill at least one worker"
  for i in 0 .. 1:
    var accepted = 0
    for action in sessions[0].game.recorder.data.actions:
      if action.playerId == int32(i) and action.kind in {ActionAttack, ActionAttackMove}: inc accepted
    doAssert accepted == 1, "Human combat did not reach accepted replay"
  doAssert sessions[0].finished and sessions[1].finished
  doAssert sessions[0].game.recorder.data.hashes == sessions[1].game.recorder.data.hashes
  doAssert sessions[0].game.recorder.data.actions == sessions[1].game.recorder.data.actions
  let data = decodeReplay(encodeReplay(sessions[0].game.recorder.data))
  let playback = newGame(sessions[0].game.world.map, config.maxTicks,
    data.header.setup.diplomacySettings)
  let cursor = initReplayPlayer(data)
  proc replay(world: World) =
    var action: ReplayAction
    while cursor.takeActionAt(uint32(world.tick), action):
      doAssert world.applyReplayAction(action), "Recorded human action rejected"
  for tick in 0 ..< data.hashes.len:
    playback.world.tickWorld(replay)
    doAssert playback.stateHash() == data.hashes[tick], "Human replay divergence"
  doAssert playback.stateHash() == sessions[0].game.stateHash()
  echo "PASS two humans fought; peer and replay hashes agree for ", sessions[0].game.world.tick, " ticks"

twoHumanCombat()
