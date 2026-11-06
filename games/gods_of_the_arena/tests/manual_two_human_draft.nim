## Bounded real-socket controller. Run host and guest as independent processes.
## Uses the production drawDraft portrait and confirm hit-testing, not applyDraft.
import std/[os, strutils, importutils, times]
import jsony, windy, windy/internal, vmath, silky
import polyworld/[connections, roomclients, rooms, tapes]
import ../[drafts, game, graphics, layouts, maps, multiplayer, replays, sim]
privateAccess(Window)

proc handleButtonPress(window: Window, button: Button) =
  handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) =
  handleButtonReleaseTemplate()

let role = getEnv("DRAFT_ROLE", "host")
let host = role == "host"
let seat = parseInt(getEnv("DRAFT_SEAT", if host: "0" else: "5"))
let prefix = getEnv("DRAFT_RUN", "/Users/me/.hermes/cache/scratch/two-human")
options.windowWidth = 1280
options.windowHeight = 800
options.speed = 1
initializeGraphics()
window.visible = false
let connection = connect("ws://127.0.0.1:19911/ws", role, gotaIdentity())
let client = connection.client
var session: NetworkMatch
var requested, claimed, started, guestClaimSent: bool
var revision = 0'u32
var picks = 0
let deadline = networkTime() + 45
try:
  while networkTime() < deadline:
    pollEvents()
    connection.pump()
    doAssert client.error.len == 0, client.error
    if client.welcomed and not requested:
      if host:
        client.send(RoomMessage(kind: CreateRoom, name: "Two human draft QA", number: 10,
          tickRate: 24, flag: false,
          payload: parseConfig("{\"maxTicks\":48}").toJson()))
        requested = true
      elif fileExists(prefix & ".room"):
        client.send(RoomMessage(kind: JoinRoom, room: readFile(prefix & ".room")))
        requested = true
    if client.snapshot.room.len > 0 and not claimed:
      if host: writeFile(prefix & ".room", client.snapshot.room)
      if host: client.claimHumanSeat(seat)
      claimed = true
    if client.snapshot.phase == Lobby and client.snapshot.seats.len == 10:
      var occupied = 0
      for current in client.snapshot.seats:
        if current.owner != 0: inc occupied
      # Host first readies its single seat; guest waits for that consent.
      if not host and client.snapshot.seats[seat].owner == 0:
        var hostReady = false
        for participant in client.snapshot.participants:
          if participant.id == client.snapshot.participant: hostReady = participant.ready
        if hostReady and not guestClaimSent:
          client.claimHumanSeat(seat)
          guestClaimSent = true
      if (occupied == 2 or (host and occupied == 1)) and revision != client.snapshot.revision:
        session = prepareNetworkMatch(client, [])
        revision = session.revision
        client.send(RoomMessage(kind: Ready, revision: revision, hash: session.game.networkHash()))
      if host and occupied == 2 and session != nil and controllersReady(client.snapshot) and not started:
        client.send(RoomMessage(kind: StartMatch))
        started = true
    for event in client.events:
      doAssert session != nil
      session.start(event)
      run = session.game
      options.playerSlot = int32(session.humanHeroIndex() + 1)
      echo "START role=", role, " seat=", seat, " playerSlot=", options.playerSlot,
        " heroId=", run.world.heroes[options.playerSlot - 1].id,
        " initialDraftHero=", run.world.draftHeroId(), " identity=", gotaIdentity()
    client.events.setLen(0)
    if session != nil and session.started and not session.finished:
      # Match the rendered controller frame: flush UI intents, then take ticks.
      session.flushSubmissions()
      var packet: RoomMessage
      while connection.takeTick(packet, 24):
        session.applyPacket(packet)
        echo "TICK role=", role, " tick=", run.world.tick, " turn=", run.world.draftTurn,
          " phase=", run.world.phase, " active=", run.world.draftHeroId(), " hash=", run.stateHash()
        if session.finished: break
      if run.world.phase == Drafting and
          run.world.heroIndex(run.world.draftHeroId()) == options.playerSlot.int - 1:
        doAssert picks == 0, "UI prompted the same human again after one pick"
        inc picks
        let scale = draftScale(vec2(1280, 800))
        let layout = draftPanels(vec2(1280, 800) / scale)
        # Draw the actual portrait press, release, then LOCK IN HERO press.
        for point in [layout.heroes[if host: 0 else: 1].origin + vec2(20),
            layout.confirm.origin + vec2(20)]:
          window.state.perFrame = PerFrame()
          window.state.mousePos = ivec2(int32(point.x * scale), int32(point.y * scale))
          sk.mousePos = window.mousePos.vec2
          window.handleButtonPress(MouseLeft)
          sk.beginUi(window, window.size)
          sk.drawDraft(window, vec2(1280, 800), true)
          sk.endUi()
          window.state.perFrame = PerFrame()
          window.handleButtonRelease(MouseLeft)
        echo "PICK role=", role, " once=", picks, " activeHero=", run.world.draftHeroId()
        session.flushSubmissions()
        # Wait for the authoritative packet before trying any next UI input.
        while client.packets.len == 0 and networkTime() < deadline:
          pollEvents()
          connection.pump()
          doAssert client.error.len == 0, client.error
          sleep(2)
    if session != nil and session.finished:
      doAssert picks == 1
      doAssert run.world.battleTick() == 48
      let data = decodeReplay(encodeReplay(run.recorder.data))
      data.validate()
      doAssert data.actions.len == 2
      let replay = newGame(generateMap(data.config.seed, data.config.mapPreset),
        data.config.spawnIntervalTicks, 0, true, data)
      replay.historyPlayback = true
      replay.replayPlayer = initReplayPlayer(data)
      for tick in 0 ..< data.hashes.len: replay.tickWorld(nil)
      doAssert replay.hashCheck.mismatches == 0
      doAssert replay.stateHash() == run.stateHash()
      writeFile(prefix & "." & role & ".result", $run.stateHash() & "\n" & encodeReplay(data))
      echo "PASS role=", role, " picks=1 battleTicks=48 replayTicks=", data.hashes.len,
        " hash=", replay.stateHash()
      # Give both controllers time to publish final hash confirmation.
      let settle = networkTime() + 0.3
      while networkTime() < settle:
        pollEvents()
        connection.pump()
        sleep(2)
      quit(0)
    sleep(2)
  doAssert false, "Timed out: " & connection.status()
except:
  stderr.writeLine("PRIMARY FAILURE: " & getCurrentExceptionMsg())
  raise
finally:
  try: connection.close()
  except CatchableError: discard
  window.close()
