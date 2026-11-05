## Two-process native live-relay check. Run from the repository root.
## Both processes need the same fresh LVD_QA_DIR; set LVD_QA_SEAT=0/1.
## Optional: LVD_QA_TICKS (default 96), LVD_QA_RECONNECT_TICK on one process.
## Uses a private room, separate local base policies, and bounded cleanup.
import
  std/[os, strutils],
  jsony, vmath, windy,
  polyworld/[connections, roomclients, rooms, tapes],
  ../[multiplayer, presets, replays, sim, content]

type Result = object
  name: string
  participant: uint32
  seat, tick, actions, replayTicks: int
  hash, networkHash: uint64
  reconnected: bool

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc main() =
  let
    directory = getEnv("LVD_QA_DIR")
    seat = parseInt(getEnv("LVD_QA_SEAT", "0"))
    ticks = parseInt(getEnv("LVD_QA_TICKS", "96"))
    disconnectTick = parseInt(getEnv("LVD_QA_RECONNECT_TICK", "0"))
  require(directory.len > 0, "Set LVD_QA_DIR to a fresh scratch directory")
  require(seat in 0 .. 1, "LVD_QA_SEAT must be 0 or 1")
  require(ticks in 48 .. 240, "Use 48..240 ticks for this bounded check")
  require(disconnectTick == 0 or disconnectTick in 1 ..< ticks,
    "Reconnect tick must precede completion")
  createDir(directory)
  let
    name = "LvD-QA-" & directory.extractFilename() & "-" & $seat
    roomFile = directory / "room.txt"
    resultFile = directory / ($seat & ".json")
    peerFile = directory / ($(1 - seat) & ".json")
    deadline = networkTime() + 90
    window = newWindow(name, ivec2(320, 180))
  var connection: Connection
  try:
    connection = connect(getEnv("LVD_QA_SERVER", "ws://127.0.0.1:9911/ws"),
      name, lvdIdentity())
    let client = connection.client
    var
      requested, claimed, startRequested, interrupted, reconnected: bool
      recorded, compared, leaving: bool
      revision = 0'u32
      originalParticipant = 0'u32
      session: NetworkMatch
      report: Result
      sources = newSeq[string](2)
    sources[seat] = readFile("games/light_vs_dark/players/base.bas")
    while networkTime() < deadline:
      pollEvents()
      connection.pump()
      require(client.error.len == 0, client.error)
      require(not window.closeRequested, "QA window was closed")
      if client.welcomed and originalParticipant == 0:
        originalParticipant = client.participant
        echo "WELCOME name=", name, " participant=", originalParticipant
      if interrupted and client.welcomed and not reconnected:
        require(client.participant == originalParticipant, "Reconnect changed identity")
        reconnected = true
        echo "RECONNECTED participant=", client.participant
      if client.welcomed and not requested:
        if seat == 0:
          require(not fileExists(roomFile), "Use a fresh QA directory")
          var config = defaultConfig(2)
          config.maxTicks = int32(ticks)
          config.mapSettings = MapSettings(layout: RandomLayout, expansions: 0)
          client.send(RoomMessage(kind: CreateRoom, name: name, number: 2,
            tickRate: uint32(TickRate), flag: false, payload: config.toJson()))
          requested = true
        elif fileExists(roomFile):
          client.send(RoomMessage(kind: JoinRoom, room: readFile(roomFile).strip()))
          requested = true
      if client.snapshot.room.len > 0 and not leaving:
        if not claimed:
          claimed = true
          require(client.snapshot.seats.len == 2, "Expected exactly two seats")
          if seat == 0:
            writeFile(roomFile, client.snapshot.room)
            echo "CREATED private=true room=", client.snapshot.room
          else:
            echo "JOINED room=", client.snapshot.room
          client.send(RoomMessage(kind: ClaimSeat, seat: uint32(seat), name: "base"))
        let full = client.snapshot.seats[0].owner != 0 and
          client.snapshot.seats[1].owner != 0
        if full and client.snapshot.phase == Lobby and revision != client.snapshot.revision:
          require(client.snapshot.seats[seat].owner == client.participant,
            "Local seat belongs to another participant")
          require(client.snapshot.seats[1 - seat].owner != client.participant,
            "The two policies must have separate owners")
          session = prepareNetworkMatch(client, sources)
          require(session.game.brains[seat] != nil and
            session.game.brains[1 - seat] == nil, "Only the owned private policy may run")
          revision = client.snapshot.revision
          client.send(RoomMessage(kind: Ready, revision: revision,
            hash: session.game.networkHash()))
          startRequested = false
          echo "READY revision=", revision, " localBrain=", seat,
            " remoteBrain=nil hash=", session.game.networkHash()
        if seat == 0 and session != nil and client.snapshot.phase == Lobby and
            not startRequested:
          var everyoneReady = true
          for currentSeat in client.snapshot.seats:
            var ownerReady = false
            for participant in client.snapshot.participants:
              if participant.id == currentSeat.owner: ownerReady = participant.ready
            everyoneReady = everyoneReady and ownerReady
          if everyoneReady:
            client.send(RoomMessage(kind: StartMatch))
            startRequested = true
            echo "START requested"
      for event in client.events:
        require(session != nil, "BeginMatch arrived before local preparation")
        session.start(event)
        echo "STARTED match=", client.match
      client.events.setLen(0)
      if session != nil and session.started and not session.finished and client.welcomed:
        discard session.pump(8)
        if disconnectTick > 0 and not interrupted and
            session.game.world.tick >= disconnectTick:
          interrupted = true
          echo "DISCONNECT tick=", session.game.world.tick
          connection.reconnectAfter(0.5)
      if session != nil and session.finished and client.snapshot.phase == Ended and not recorded:
        require(session.game.world.tick == ticks, "Match did not stop at the exact requested tick")
        require(disconnectTick == 0 or reconnected, "Reconnect was not verified")
        require(not session.game.brains[seat].failed, "Owned base policy failed")
        let replayFile = directory / ($seat & ".replay")
        saveReplay(replayFile, session.game.recorder.data)
        let data = loadReplay(replayFile)
        require(data.hashes.len == ticks, "Recording does not cover every tick")
        var playerActions: array[2, int]
        for action in data.actions: inc playerActions[action.playerId]
        require(playerActions[0] > 0 and playerActions[1] > 0,
          "Both separately owned bots must contribute accepted actions")
        let
          playback = newGame(session.game.world.map, int32(ticks),
            data.header.setup.diplomacySettings)
          cursor = initReplayPlayer(data)
        proc replay(world: World) =
          var action: ReplayAction
          while cursor.takeActionAt(uint32(world.tick), action):
            require(world.applyReplayAction(action), "Replay action was rejected")
        for tick in 1 .. data.hashes.len:
          playback.world.tickWorld(replay)
          require(playback.stateHash() == data.hashes[tick - 1],
            "Replay hash mismatch at tick " & $tick)
        require(playback.stateHash() == session.game.stateHash(), "Replay final hash differs")
        report = Result(name: name, participant: client.participant, seat: seat,
          tick: int(session.game.world.tick), actions: data.actions.len,
          replayTicks: data.hashes.len, hash: session.game.stateHash(),
          networkHash: session.game.networkHash(), reconnected: reconnected)
        writeFile(resultFile, report.toJson())
        recorded = true
        echo "FINISHED ", report.toJson(), " phase=Ended actionsBySeat=", playerActions
      if recorded and not compared and fileExists(peerFile):
        let peer = readFile(peerFile).fromJson(Result)
        require(peer.participant != report.participant and peer.seat != report.seat,
          "Peer is not an independent owner")
        require(peer.tick == report.tick and peer.hash == report.hash and
          peer.networkHash == report.networkHash, "Final client tick/hash mismatch")
        compared = true
        echo "PEER_EQUAL tick=", report.tick, " hash=", report.hash,
          " networkHash=", report.networkHash
        client.send(RoomMessage(kind: LeaveRoom))
        leaving = true
      if leaving and client.snapshot.room.len == 0:
        echo "LEFT acknowledged participant=", originalParticipant
        return
      sleep(2)
    raise newException(ValueError, "Live relay QA exceeded 90 seconds: " & connection.status())
  finally:
    if connection != nil:
      # Abort only this QA match on failure, then attempt a bounded acknowledged leave.
      let client = connection.client
      if client.connected and client.snapshot.room.len > 0:
        if client.snapshot.phase in {Playing, Waiting}:
          client.send(RoomMessage(kind: AbortMatch, match: client.match,
            detail: "QA harness cleanup"))
        connection.pump()
        let cleanupDeadline = networkTime() + 2
        var sentLeave = false
        while client.connected and client.snapshot.room.len > 0 and
            networkTime() < cleanupDeadline:
          pollEvents()
          connection.pump()
          if client.snapshot.phase notin {Playing, Waiting} and not sentLeave:
            client.send(RoomMessage(kind: LeaveRoom))
            sentLeave = true
          sleep(2)
      connection.close()
      echo "CLOSED connected=", connection.client.connected
    window.close()

when isMainModule:
  try:
    main()
  except CatchableError as error:
    stderr.writeLine("QA FAILED: " & error.msg)
    quit(1)
