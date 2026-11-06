## Two independent native RoomClients over the current binary WebSocket wire.
## REMATCH_ROLE=host/guest REMATCH_RUN=<unique scratch prefix>
## REMATCH_SERVER=ws://127.0.0.1:19921/ws
import std/os
import jsony, windy
import polyworld/[connections, roomclients, rooms, tapes]
import ../[content, controls, game, maps, multiplayer, replays, sim]

let host = getEnv("REMATCH_ROLE", "host") == "host"
let role = if host: "host" else: "guest"
let prefix = getEnv("REMATCH_RUN")
doAssert prefix.len > 0
let window = newWindow("GotA same-room " & role, ivec2(320, 240), visible = false)
let connection = connect(getEnv("REMATCH_SERVER", "ws://127.0.0.1:19921/ws"),
  "Rematch " & role, gotaIdentity())
let client = connection.client
var sources: array[HeroClassCount, string]
if host:
  sources[2] = readFile(currentSourcePath().parentDir.parentDir / "players/base.bas")
var session: NetworkMatch
var requested, claimed, startPending, reopened, leaveSent: bool
var completed, picks: int
var room, payload: string
var seats: seq[Seat]
var previousMatch = 0'u32
let deadline = networkTime() + 60
try:
  while networkTime() < deadline:
    pollEvents()
    connection.pump()
    doAssert client.error.len == 0, client.error
    if client.welcomed and not requested:
      if host:
        client.send(RoomMessage(kind: CreateRoom, name: "Private two-match rematch QA",
          number: 10, tickRate: 24, flag: false,
          payload: parseConfig("{\"maxTicks\":48}").toJson()))
        requested = true
      elif fileExists(prefix & ".room"):
        client.send(RoomMessage(kind: JoinRoom, room: readFile(prefix & ".room")))
        requested = true
    if client.snapshot.room.len > 0 and not claimed:
      if host: writeFile(prefix & ".room", client.snapshot.room)
      client.claimHumanSeat(if host: 0 else: 5)
      if host:
        client.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Private base bot"))
      claimed = true
    if client.snapshot.phase == Lobby and client.snapshot.seats.len == 10:
      if session.returnedToLobby():
        # Guest has deliberately kept its completed result session until here.
        doAssert session.finished and completed == 1
        doAssert client.match == 0 and client.packets.len == 0
        session = nil
        clearPlayerCommands()
        startPending = false
        echo "REOPEN role=", role, " sameRoom=", client.snapshot.room
      if completed == 1:
        doAssert client.snapshot.room == room
        doAssert client.snapshot.seats == seats
        doAssert client.snapshot.payload == payload
        doAssert client.snapshot.participants.len == 2
      let roster = client.snapshot.seats
      if host and roster[0].owner == client.participant and
          roster[2].owner == client.participant and roster[5].owner != 0 and
          session == nil and not startPending:
        if completed == 1:
          # Wait for guest to have observed Lobby before starting the rematch.
          if not fileExists(prefix & ".guest.lobby"): continue
        session = client.requestStart(sources)
        startPending = true
      if not host and completed == 1:
        writeFile(prefix & ".guest.lobby", "same room retained")
    if client.events.len > 0:
      let event = client.events[0]
      client.events.delete(0)
      doAssert event.match > previousMatch
      previousMatch = event.match
      if session == nil or session.started or session.revision != event.revision:
        session = prepareNetworkMatch(client, sources)
      room = client.snapshot.room
      payload = client.snapshot.payload
      seats = client.snapshot.seats
      for participant in client.snapshot.participants:
        doAssert not participant.ready
      session.start(event)
      doAssert session.humanHeroIndex() == (if host: 0 else: 2)
      run = session.game
      picks = 0
      echo "START role=", role, " round=", completed + 1, " match=", event.match
    if session != nil and session.started and not session.finished:
      run = session.game
      options.playerSlot = int32(session.humanHeroIndex() + 1)
      let active = run.world.draftHeroId()
      if picks == 0 and active != 0 and run.world.heroIndex(active) == session.humanHeroIndex():
        inc picks
        queueDraft(active, if host: 0 else: 1)
        session.flushSubmissions()
        doAssert run.world.draftHeroId() == active
      var packet: RoomMessage
      while connection.takeTick(packet, 24):
        session.applyPacket(packet)
        echo "HASH role=", role, " round=", completed + 1,
          " tick=", run.world.tick, " hash=", run.networkHash()
        if session.finished: break
      if session.finished:
        inc completed
        doAssert picks == 1 and run.world.battleTick() == 48
        let data = decodeReplay(encodeReplay(run.recorder.data))
        data.validate()
        var humanPicks = 0
        for action in data.actions:
          if action.kind == ActionDraft and action.heroId in
              [run.world.heroes[0].id, run.world.heroes[2].id]: inc humanPicks
        doAssert humanPicks == 2
        let replay = newGame(generateMap(data.config.seed, data.config.mapPreset),
          data.config.spawnIntervalTicks, 0, true, data)
        replay.historyPlayback = true
        replay.replayPlayer = initReplayPlayer(data)
        for tick in 0 ..< data.hashes.len: replay.tickWorld(nil)
        doAssert replay.hashCheck.mismatches == 0
        doAssert replay.stateHash() == run.stateHash()
        writeFile(prefix & "." & role & "." & $completed & ".replay", encodeReplay(data))
        echo "PASS role=", role, " round=", completed, " picks=", picks,
          " battleTicks=48 replayTicks=", data.hashes.len, " hash=", replay.stateHash()
    if completed == 1 and client.snapshot.phase == rooms.Ended and host and not reopened:
      # Same owner-only request as the frontend post-runGraphics transition.
      client.send(RoomMessage(kind: ReturnLobby))
      reopened = true
    if completed == 2 and client.snapshot.phase == rooms.Ended and not leaveSent:
      client.send(RoomMessage(kind: LeaveRoom))
      leaveSent = true
    if leaveSent and client.snapshot.room.len == 0:
      echo "CLEANUP role=", role, " acknowledgedLeave=true"
      break
    sleep(2)
  doAssert completed == 2 and leaveSent and client.snapshot.room.len == 0,
    "Timed out: " & connection.status()
except:
  stderr.writeLine("PRIMARY FAILURE: " & getCurrentExceptionMsg())
  raise
finally:
  try: connection.close()
  except CatchableError: discard
  window.close()
