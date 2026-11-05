## Real, bounded native relay host for browser midmatch spectator QA.
## Run from the repository root; all ten seats execute the real base policy.
import
  std/[json, os],
  jsony, vmath, windy,
  polyworld/[connections, roomclients, rooms, tapes],
  ../[multiplayer, presets, replays, sim]

const
  RoomFile = "/Users/me/.hermes/cache/scratch/gota-watch-room.txt"
  StatusFile = "/Users/me/.hermes/cache/scratch/gota-watch-status.json"
  Server = "ws://127.0.0.1:9911/ws"

proc require(ok: bool, detail: string) =
  if not ok:
    raise newException(ValueError, detail)

proc main() =
  let
    window = newWindow("GotA Watch QA host", ivec2(320, 180))
    deadline = networkTime() + 300
    base = readFile("games/gods_of_the_arena/players/base.bas")
  var
    connection: Connection
    session: NetworkMatch
    sources: array[10, string]
    requested, claimed, startRequested: bool
    revision = 0'u32
    lastReport = -24'i32
  for source in sources.mitems:
    source = base
  try:
    connection = connect(Server, "Watch QA host", gotaIdentity())
    let client = connection.client
    while networkTime() < deadline:
      pollEvents()
      connection.pump()
      require(client.error.len == 0, client.error)
      require(not window.closeRequested, "QA host window closed")
      if client.welcomed and not requested:
        var config = parseConfig("{\"draftMode\":\"open\"}")
        config.maxTicks = 7200
        client.send(RoomMessage(kind: CreateRoom, name: "Watch QA", number: 10,
          tickRate: 24, flag: false, payload: config.toJson()))
        requested = true
      if client.snapshot.room.len > 0:
        if not claimed:
          require(client.snapshot.seats.len == 10, "Expected ten seats")
          writeFile(RoomFile, client.snapshot.room)
          echo "ROOM=", client.snapshot.room, " private=true maxTicks=7200 draft=open"
          for i in 0 ..< 10:
            client.send(RoomMessage(kind: ClaimSeat, seat: uint32(i), name: "Base"))
          claimed = true
        var allOwned = true
        for seat in client.snapshot.seats:
          allOwned = allOwned and seat.owner == client.participant
        if allOwned and client.snapshot.phase == Lobby and
            revision != client.snapshot.revision:
          session = prepareNetworkMatch(client, sources)
          for vm in session.game.heroVms:
            require(vm != nil, "Every locally owned seat must have a real policy VM")
          revision = client.snapshot.revision
          client.send(RoomMessage(kind: Ready, revision: revision,
            hash: session.game.networkHash()))
          startRequested = false
          echo "READY revision=", revision, " ownedSeats=10 realBotVMs=10 hash=",
            session.game.networkHash()
        if session != nil and client.snapshot.phase == Lobby and not startRequested:
          var hostReady = false
          for participant in client.snapshot.participants:
            if participant.id == client.participant:
              hostReady = participant.ready
          if hostReady:
            client.send(RoomMessage(kind: StartMatch))
            startRequested = true
      for event in client.events:
        require(session != nil, "BeginMatch arrived before preparation")
        session.start(event)
        echo "STARTED match=", client.match, " room=", client.snapshot.room
      client.events.setLen(0)
      if session != nil and session.started and not session.finished:
        var packet: RoomMessage
        while connection.takeTick(packet, 24):
          session.applyPacket(packet)
          if session.finished:
            break
      if session != nil and session.started and
          (session.game.world.tick >= lastReport + 24 or session.finished):
        lastReport = session.game.world.tick
        let status = %* {"room": client.snapshot.room, "match": client.match,
          "tick": lastReport, "hash": session.game.networkHash(),
          "finished": session.finished, "phase": $client.snapshot.phase,
          "participants": client.snapshot.participants.len,
          "actions": session.game.recorder.data.actions.len,
          "pid": getCurrentProcessId()}
        writeFile(StatusFile, $status)
        echo "STATUS ", $status
      if session != nil and session.finished:
        echo "FINISHED room=", client.snapshot.room, " tick=", session.game.world.tick
        return
      sleep(2)
    echo "TIMEOUT bounded=300s status=", connection.status()
  finally:
    # Do not send LeaveRoom, AbortMatch, or pause while the parent verifies.
    if connection != nil:
      connection.close()
    window.close()

when isMainModule:
  try:
    main()
  except CatchableError as error:
    stderr.writeLine("WATCH QA FAILED: " & error.msg)
    quit(1)
