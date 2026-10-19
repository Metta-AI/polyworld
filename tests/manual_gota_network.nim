import
  std/[os, strutils],
  jsony, vmath, windy,
  polyworld/[connections, roomclients, rooms, tapes, viewers],
  ../examples/gods_of_the_arena/[multiplayer, replays, sim]

var
  connection = connect(
    getEnv("GOTA_SERVER", "ws://127.0.0.1:8090/ws"),
    getEnv("GOTA_NAME", "Network check"), gotaIdentity()
  )
  window = newWindow("GotA network check", ivec2(320, 180))
  roomId = getEnv("GOTA_ROOM")
  seatStart = parseInt(getEnv("GOTA_SEAT_START", "0"))
  seatCount = parseInt(getEnv("GOTA_SEAT_COUNT", "5"))
  requested, claimed, ready, startRequested: bool
  session: NetworkMatch
  revision = 0'u32
  lastReport = 0'i32
  disconnectTick = parseInt(getEnv("GOTA_DISCONNECT_TICK", "0"))
  disconnectSeconds = parseFloat(getEnv("GOTA_DISCONNECT_SECONDS", "3"))
  interrupted = false
  sources: array[10, string]
  base = readFile("examples/gods_of_the_arena/players/base.bas")
for i in seatStart ..< seatStart + seatCount:
  sources[i] = base
while true:
  pollEvents()
  connection.pump()
  let client = connection.client
  if client.error.len > 0:
    quit(client.error, 1)
  if client.welcomed and not requested:
    requested = true
    if roomId.len == 0:
      var config = parseConfig("{\"draftMode\":\"open\"}")
      config.maxTicks = int32(parseInt(getEnv("GOTA_TICKS", "480")))
      client.send(RoomMessage(
        kind: CreateRoom, name: "Native and browser check", number: 10,
        tickRate: 24, flag: true, payload: config.toJson()
      ))
    else:
      client.send(RoomMessage(kind: JoinRoom, room: roomId))
  if client.snapshot.room.len > 0:
    if roomId.len == 0:
      roomId = client.snapshot.room
      echo "ROOM=", roomId
      writeFile("tmp/network-room.txt", roomId)
    if not claimed:
      claimed = true
      for i in seatStart ..< seatStart + seatCount:
        client.send(RoomMessage(kind: ClaimSeat, seat: uint32(i), name: "Base"))
    var full = true
    for seat in client.snapshot.seats:
      if seat.owner == 0:
        full = false
    if full and client.snapshot.phase == Lobby and
      revision != client.snapshot.revision:
        revision = client.snapshot.revision
        session = prepareNetworkMatch(client, sources)
        client.send(RoomMessage(
          kind: Ready, revision: revision, hash: session.game.networkHash()
        ))
        ready = true
        startRequested = false
    if ready and client.snapshot.participant == client.participant and
      not startRequested:
        var everyoneReady = true
        for seat in client.snapshot.seats:
          for participant in client.snapshot.participants:
            if seat.owner == participant.id and not participant.ready:
              everyoneReady = false
        if everyoneReady:
          client.send(RoomMessage(kind: StartMatch))
          startRequested = true
  if client.events.len > 0:
    if session == nil:
      session = prepareNetworkMatch(client, sources)
    session.start(client.events[0])
    client.events.setLen(0)
  if session != nil and session.started and not session.finished:
    var packet: RoomMessage
    while client.takeTick(packet):
      session.applyPacket(packet)
      if session.finished:
        break
    if session.game.world.tick >= lastReport + 24:
      lastReport = session.game.world.tick
      echo "HASH ", lastReport, " ", session.game.stateHash()
    if disconnectTick > 0 and not interrupted and
      session.game.world.tick >= disconnectTick:
        interrupted = true
        echo "DISCONNECT ", session.game.world.tick
        connection.reconnectAfter(disconnectSeconds)
  if client.snapshot.phase == rooms.Ended and
    session != nil and session.finished:
      let path = "tmp/network-" & $seatStart & ".replay"
      writeFile(path, session.game.recorder.data.encodeReplay())
      echo "FINISHED ", session.game.world.tick, " ", session.game.stateHash()
      connection.close()
      quit(0)
  if window.closeRequested:
    connection.close()
    quit(1)
  waitForDisplay()
  when not defined(emscripten):
    sleep(2)
