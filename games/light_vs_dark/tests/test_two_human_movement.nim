## Two HUMAN controllers using the ordinary controls queue and binary relay.
## Run headless normally; -d:liveHumanMovement uses LVD_QA_SERVER (9911 default).
import jsony
import polyworld/[rooms, roomclients, tapes]
when defined(liveHumanMovement):
  import std/[os, times]
  import windy, vmath
  import polyworld/connections
else:
  import polyworld/relays
import ../[content, controls, multiplayer, presets, replays, sim]

proc twoHumanMovement*() =
  when not defined(liveHumanMovement):
    var relay = Relay()
    var now = 0.0
  when defined(liveHumanMovement):
    let window = newWindow("LvD two human socket regression", ivec2(320, 180), visible = false)
    let server = getEnv("LVD_QA_SERVER", "ws://127.0.0.1:9911/ws")
    let connections = [connect(server, "Movement host", lvdIdentity()),
      connect(server, "Movement guest", lvdIdentity())]
    let clients = [connections[0].client, connections[1].client]
    defer:
      for connection in connections:
        if connection.client.snapshot.room.len > 0 and
            connection.client.snapshot.phase in {Playing, Waiting}:
          connection.client.send(RoomMessage(kind: AbortMatch, match: connection.client.match,
            detail: "Private movement fixture cleanup"))
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
    let clients = [RoomClient(identity: lvdIdentity(), name: "Movement host"),
      RoomClient(identity: lvdIdentity(), name: "Movement guest")]
  proc exchange() =
    when defined(liveHumanMovement):
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
  when not defined(liveHumanMovement):
    for client in clients: client.opened()
  exchange()
  var config = defaultConfig(2)
  config.maxTicks = 96
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  var roomName = "Two human movement QA"
  when defined(liveHumanMovement): roomName.add " " & $getCurrentProcessId() & " " & $epochTime()
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
    when defined(liveHumanMovement):
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
  var initial: array[2, FixedVec2]
  var ordered = false
  # Idle first: human clicks happen after startup/empty decision flushes.
  for frame in 1 .. 100:
    if not ordered and sessions[0].game.world.tick >= 8:
      ordered = true
      for i, session in sessions:
        let world = session.game.world
        for unit in world.units:
          if unit.owner == int32(i) and unit.state != UnitDying:
            selected[i] = unit.id
            initial[i] = unit.body.pos
            break
        doAssert selected[i] != NoEntity
        let index = world.unitIndex(selected[i])
        let tile = world.units[index].tile
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
        when declared(frontendIssueMove):
          frontendIssueMove(session, selected[i], target)
        else:
          queueMove(int32(i), selected[i], int32(target.x), int32(target.y))
        session.flushSubmissions()
        doAssert session.game.stateHash() == before, "Intent mutated local world"
        echo "QUEUED human=", i, " unit=", selected[i], " target=", target
    exchange()
    when not defined(liveHumanMovement):
      now += 1.0 / float64(TickRate)
      relay.advance(now)
    exchange()
    for session in sessions: discard session.pump(8)
    exchange()
    let a = sessions[0].game.recorder.data.hashes
    let b = sessions[1].game.recorder.data.hashes
    for tick in 0 ..< min(a.len, b.len):
      doAssert a[tick] == b[tick], "Peer divergence at tick " & $(tick + 1)
    if sessions[0].finished and sessions[1].finished: break
  for i in 0 .. 1:
    let world = sessions[0].game.world
    let final = world.units[world.unitIndex(selected[i])].body.pos
    echo "STATE human=", i, " worldTick=", world.tick,
      " applied=", clients[i].applied, " serverTick=", clients[i].serverTick,
      " catchupPending=", clients[i].catchupPending,
      " actions=", sessions[i].game.recorder.data.actions.len
    echo "DISPLACEMENT human=", i, " initial=", initial[i], " final=", final
    doAssert final != initial[i], "Human " & $i & " selected unit never moved"
    var accepted = 0
    for action in sessions[0].game.recorder.data.actions:
      if action.playerId == int32(i) and action.kind == ActionMove: inc accepted
    doAssert accepted == 1, "Human movement did not reach accepted replay"
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
  echo "PASS two humans moved; peer and replay hashes agree for ", sessions[0].game.world.tick, " ticks"

twoHumanMovement()
