import
  std/[os, strutils, uri],
  chroma, jsony, silky, vmath, windy,
  polyworld/[chrome, connections, menus, roomclients, rooms, policies, viewers],
  content, controls, game, graphics, multiplayer, presets, replays

const AppName = "Polyworld GotA"

proc bundledBot(): LocalPolicy =
  ## Loads the base bot from the native checkout or the web data bundle.
  let path =
    when defined(emscripten):
      "/policies/gota/base.bas"
    else:
      currentSourcePath().parentDir / "players/base.bas"
  LocalPolicy(name: "Base bot", bytes: readPolicyBytes(path))

proc runFrontend*() =
  ## Owns menu, lobby, match and return transitions on the same window.
  initializeGraphics()
  var
    preferences = Preferences()
    page = HomeMenu
    error: string
    roomName = "GotA room"
    invite = inviteParameter("room")
    joinRequested = invite.len > 0
    connection: Connection
    prepared: NetworkMatch
    preparedRevision = 0'u32
    viewedRevision = 0'u32
    config = matchConfig
    configText: string
    publicRoom = true
    roomPage, participantPage: int
    humanSeat = 0
    multiplayerHuman = -1
    localPolicies: array[HeroClassCount, LocalPolicy]
    networkPolicies: array[HeroClassCount, LocalPolicy]
    chosenPolicy: LocalPolicy
    launchLocal, launchNetwork: bool
  try:
    preferences = readPreferences(AppName)
  except MenusError, IOError, OSError:
    error = getCurrentExceptionMsg()
  preferences.applyPreferences(window)
  let base = bundledBot()
  for policy in localPolicies.mitems:
    policy = base
  chosenPolicy = base
  config.seed = options.seed
  config.maxTicks = options.maximumTicks
  config.spawnIntervalTicks = options.spawnIntervalTicks
  configText = config.toJson()
  let inviteServer = inviteParameter("server")
  if inviteServer.len > 0:
    preferences.server = inviteServer
  if invite.len > 0:
    page = MultiplayerMenu

  while not window.closeRequested:
    launchLocal = false
    launchNetwork = false
    if connection != nil:
      connection.pump()
      let client = connection.client
      if client.welcomed and joinRequested and invite.len > 0 and
        client.snapshot.room.len == 0:
        client.send(RoomMessage(kind: JoinRoom, room: invite))
        joinRequested = false
      if client.snapshot.room.len == 0 and page == LobbyMenu:
        page = MultiplayerMenu
        prepared = nil
        preparedRevision = 0
        viewedRevision = 0
        multiplayerHuman = -1
        networkPolicies = default(array[HeroClassCount, LocalPolicy])
      if client.snapshot.room.len > 0:
        page = LobbyMenu
        if viewedRevision != client.snapshot.revision:
          configText = client.snapshot.payload
          viewedRevision = client.snapshot.revision
      if client.events.len > 0:
        let event = client.events[0]
        client.events.delete(0)
        try:
          if prepared == nil or preparedRevision != event.revision:
            var sources: array[HeroClassCount, string]
            for i, policy in networkPolicies:
              sources[i] = policy.bytes
            prepared = prepareNetworkMatch(client, sources)
            preparedRevision = event.revision
          prepared.start(event)
          launchNetwork = true
        except CatchableError as problem:
          error = problem.msg
          client.send(RoomMessage(
            kind: AbortMatch, match: event.match, detail: error
          ))
      if client.error.len > 0:
        error = client.error
    if launchNetwork:
      run = prepared.game
      options.playerSlot = int32(multiplayerHuman + 1)
      options.replayPath = ""
      options.recordPath = ""
      options.pauseOnStart = false
      options.speed = 1
      let quitToMenu = runGraphics(prepared, connection)
      preferences = readPreferences(AppName)
      if quitToMenu:
        connection.close()
        connection = nil
        page = HomeMenu
        error = ""
        viewedRevision = 0
        multiplayerHuman = -1
        networkPolicies = default(array[HeroClassCount, LocalPolicy])
      prepared = nil
      preparedRevision = 0
      clearPlayerCommands()
      run = nil
      continue

    window.onButtonPress = nil
    window.onFrame = proc() =
      ## Draws this lifecycle state without constructing a hidden match.
      let origin = sk.beginMenu(window, "Gods of the Arena", "Polyworld")
      try:
        case page
        of HomeMenu:
          if sk.menuButton(window, "Single player", origin):
            page = SingleMenu
          if sk.menuButton(window, "Multiplayer", origin + vec2(0, 50)):
            page = MultiplayerMenu
          if sk.menuButton(window, "Settings", origin + vec2(0, 100)):
            page = SettingsMenu
          when not defined(emscripten):
            if sk.menuButton(window, "Exit to OS", origin + vec2(0, 150)):
              window.closeRequested = true
          sk.menuLabel("Play with friends, or bring your own bots.",
            origin + vec2(340, 6), color = MenuMuted)
        of SingleMenu:
          sk.menuLabel("Single player", origin, font = "Bold")
          sk.menuLabel("Red team", origin + vec2(0, 38), color = MenuMuted)
          sk.menuLabel("Blue team", origin + vec2(260, 38), color = MenuMuted)
          for i in 0 ..< HeroClassCount:
            let
              point = origin + vec2(float32(i div 5) * 260, 75 + float32(i mod 5) * 86)
              label = if i == humanSeat: "You" else: localPolicies[i].name
            sk.menuLabel("Seat " & $(i + 1) & " / " & label, point, 250)
            if sk.menuButton(window, "Play", point + vec2(0, 29), 70):
              humanSeat = i
            if sk.menuButton(window, "Base", point + vec2(78, 29), 70):
              localPolicies[i] = base
              if humanSeat == i:
                humanSeat = -1
            if sk.menuButton(window, "File...", point + vec2(156, 29), 88):
              let selected = selectPolicy()
              if selected.bytes.len > 0:
                localPolicies[i] = selected
                if humanSeat == i:
                  humanSeat = -1
          if sk.menuButton(window, "Spectate bots only", origin + vec2(0, 520), 244):
            humanSeat = -1
          if sk.menuButton(window, "Start game", origin + vec2(260, 520), 244):
            config = parseConfig(configText)
            launchLocal = true
          sk.menuLabel("Match settings", origin + vec2(550, 0), font = "Bold")
          sk.menuLabel("Seed, draft, duration, waves and map preset", origin + vec2(550, 32),
            470, MenuMuted, "Small")
          sk.menuInput(window, "localConfig", configText, origin + vec2(550, 66),
            470, 490, multiline = true)
          if sk.menuButton(window, "Back", origin + vec2(0, 580), 130):
            page = HomeMenu
        of MultiplayerMenu:
          sk.menuLabel("Multiplayer", origin, font = "Bold")
          sk.menuInput(window, "server", preferences.server, origin + vec2(0, 40), 650)
          if sk.menuButton(window, "Connect", origin + vec2(670, 40), 160):
            if connection != nil:
              connection.close()
            connection = connect(preferences.server, preferences.name, gotaIdentity())
            preferences.savePreferences(AppName)
            prepared = nil
            preparedRevision = 0
            viewedRevision = 0
            multiplayerHuman = -1
            networkPolicies = default(array[HeroClassCount, LocalPolicy])
            error = ""
          if connection != nil:
            let client = connection.client
            sk.menuLabel(client.status, origin + vec2(0, 88), 1000, MenuMuted)
            if client.welcomed:
              sk.menuInput(window, "roomName", roomName, origin + vec2(0, 132), 360)
              if sk.menuButton(window,
                if publicRoom: "Public room" else: "Unlisted room",
                origin + vec2(380, 132), 180):
                  publicRoom = not publicRoom
              if sk.menuButton(window, "Create room", origin + vec2(580, 132), 180):
                config = parseConfig(configText)
                client.send(RoomMessage(
                  kind: CreateRoom, name: roomName, number: HeroClassCount,
                  tickRate: uint32(TickRate), flag: publicRoom,
                  payload: config.toJson()
                ))
              sk.menuInput(window, "inviteRoom", invite, origin + vec2(0, 184), 560)
              if sk.menuButton(window, "Join invite", origin + vec2(580, 184), 180):
                if invite.contains("?"):
                  let parsed = parseUri(invite)
                  for key, value in decodeQuery(parsed.query):
                    if key == "room":
                      invite = value
                joinRequested = true
              sk.menuLabel("Public rooms for this exact game version", origin + vec2(0, 242),
                color = MenuMuted)
              if sk.menuButton(window, "Refresh", origin + vec2(670, 236), 160):
                client.send(RoomMessage(kind: ListRooms))
              roomPage = min(roomPage, max(0, (client.listings.len - 1) div 7))
              for i in roomPage * 7 ..< min(client.listings.len, (roomPage + 1) * 7):
                let room = client.listings[i]
                if sk.menuButton(window,
                  room.name & "  " & $room.occupied & "/" & $room.seats & "  " & $room.phase,
                  origin + vec2(0, 286 + float32(i mod 7) * 43), 830):
                    client.send(RoomMessage(kind: JoinRoom, room: room.id))
              if sk.menuButton(window, "Previous", origin + vec2(450, 620), 180,
                roomPage > 0):
                  dec roomPage
              if sk.menuButton(window, "Next", origin + vec2(650, 620), 180,
                (roomPage + 1) * 7 < client.listings.len):
                  inc roomPage
          if sk.menuButton(window, "Back", origin + vec2(0, 620), 130):
            connection.close()
            connection = nil
            error = ""
            page = HomeMenu
        of LobbyMenu:
          let
            client = connection.client
            snapshot = client.snapshot
            editable = snapshot.phase == rooms.Lobby
            owner = snapshot.participant == client.participant
          sk.menuLabel(snapshot.name, origin, font = "Bold")
          sk.menuLabel("Red team", origin + vec2(0, 38), color = MenuMuted)
          sk.menuLabel("Blue team", origin + vec2(260, 38), color = MenuMuted)
          for i, seat in snapshot.seats:
            let point = origin + vec2(float32(i div 5) * 260, 75 + float32(i mod 5) * 86)
            var label = "Open seat"
            if seat.owner != 0:
              label = seat.name
              for participant in snapshot.participants:
                if participant.id == seat.owner:
                  label.add " / " & participant.name
            sk.menuLabel($(i + 1) & " " & label, point, 250, font = "Small")
            if seat.owner == 0 and editable:
              if sk.menuButton(window, "You", point + vec2(0, 29), 70):
                if multiplayerHuman >= 0:
                  client.send(RoomMessage(kind: ReleaseSeat, seat: uint32(multiplayerHuman)))
                multiplayerHuman = i
                networkPolicies[i] = LocalPolicy()
                client.send(RoomMessage(kind: ClaimSeat, seat: uint32(i), name: "Human"))
              if sk.menuButton(window, "Base", point + vec2(78, 29), 70):
                networkPolicies[i] = base
                client.send(RoomMessage(kind: ClaimSeat, seat: uint32(i), name: base.name))
              if sk.menuButton(window, "Bot", point + vec2(156, 29), 88):
                networkPolicies[i] = chosenPolicy
                client.send(RoomMessage(kind: ClaimSeat, seat: uint32(i), name: chosenPolicy.name))
            elif seat.owner == client.participant and editable:
              if sk.menuButton(window, "Release seat", point + vec2(0, 29), 244):
                client.send(RoomMessage(kind: ReleaseSeat, seat: uint32(i)))
                networkPolicies[i] = LocalPolicy()
                if multiplayerHuman == i:
                  multiplayerHuman = -1
          if sk.menuButton(window, "Choose local bot...", origin + vec2(0, 520), 244, editable):
            let selected = selectPolicy()
            if selected.bytes.len > 0:
              chosenPolicy = selected
          sk.menuLabel(chosenPolicy.name, origin + vec2(260, 524), 250, MenuMuted, "Small")
          if sk.menuButton(window, "Ready", origin + vec2(0, 568), 118, editable):
            var sources: array[HeroClassCount, string]
            for i, policy in networkPolicies:
              sources[i] = policy.bytes
            prepared = prepareNetworkMatch(client, sources)
            preparedRevision = snapshot.revision
            client.send(RoomMessage(
              kind: Ready, revision: snapshot.revision, hash: prepared.game.networkHash()
            ))
          if sk.menuButton(window, "Start", origin + vec2(128, 568), 116, editable and owner):
            client.send(RoomMessage(kind: StartMatch))
          if sk.menuButton(window, "Copy invite", origin + vec2(260, 568), 244):
            copyInvite(inviteBase() & "?server=" & encodeUrl(preferences.server) &
              "&room=" & encodeUrl(snapshot.room))
          sk.menuLabel("Match settings", origin + vec2(550, 0), font = "Bold")
          if owner and editable:
            sk.menuInput(window, "roomConfig", configText, origin + vec2(550, 36),
              470, 270, multiline = true)
            if sk.menuButton(window, "Apply settings", origin + vec2(550, 314), 470):
              config = parseConfig(configText)
              client.send(RoomMessage(
                kind: ConfigureRoom, name: snapshot.name, number: HeroClassCount,
                tickRate: uint32(TickRate), flag: publicRoom, payload: config.toJson()
              ))
          else:
            sk.menuLabel($snapshot.phase, origin + vec2(550, 38), color = MenuMuted)
          sk.menuLabel("Participants", origin + vec2(550, 368), font = "Bold")
          participantPage = min(participantPage,
            max(0, (snapshot.participants.len - 1) div 6))
          for i in participantPage * 6 ..<
            min(snapshot.participants.len, (participantPage + 1) * 6):
              let
                participant = snapshot.participants[i]
                point = origin + vec2(550, 408 + float32(i mod 6) * 36)
              sk.menuLabel(participant.name &
                (if not participant.connected: " / disconnected"
                 elif participant.ready: " / ready" else: " / loading"),
                point, 330, MenuMuted, "Small")
              if owner and editable and participant.id != client.participant:
                if sk.menuButton(window, "Remove", point + vec2(350, 0), 120):
                  client.send(RoomMessage(kind: KickParticipant, participant: participant.id))
          if sk.menuButton(window, "Previous", origin + vec2(550, 640), 180,
            participantPage > 0):
              dec participantPage
          if sk.menuButton(window, "Next", origin + vec2(750, 640), 180,
            (participantPage + 1) * 6 < snapshot.participants.len):
              inc participantPage
          if snapshot.phase in {rooms.Ended, Desynced} and owner:
            if sk.menuButton(window, "Return to lobby", origin + vec2(0, 620), 244):
              client.send(RoomMessage(kind: ReturnLobby))
              client.error = ""
              error = ""
          elif editable or snapshot.phase in {rooms.Ended, Desynced}:
            if sk.menuButton(window, "Leave room", origin + vec2(0, 620), 244):
              client.send(RoomMessage(kind: LeaveRoom))
              page = MultiplayerMenu
              prepared = nil
              preparedRevision = 0
              viewedRevision = 0
              multiplayerHuman = -1
              networkPolicies = default(array[HeroClassCount, LocalPolicy])
        of SettingsMenu:
          if sk.settingsPanel(window, preferences, AppName, origin):
            page = HomeMenu
      except CatchableError as problem:
        error = problem.msg
      if error.len > 0:
        sk.menuLabel(error, origin + vec2(0, 678), 1040, rgbx(245, 151, 139, 255), "Small")
      sk.endUi()
      window.presentFrame(framePaceHz)
      reportReplayFrame(0, 0)
    pollEvents()
    waitForDisplay()
    if launchLocal:
      connection.close()
      connection = nil
      error = ""
      window.onFrame = nil
      config.players.setLen(HeroClassCount)
      var sources: array[HeroClassCount, string]
      for i, policy in localPolicies:
        if i == humanSeat:
          config.players[i].name = preferences.name
        else:
          sources[i] = policy.bytes
          config.players[i].name = policy.name
      try:
        initializeLocalMatch(config, sources, humanSeat)
        runGraphics()
        preferences = readPreferences(AppName)
      except CatchableError as problem:
        error = problem.msg
      page = HomeMenu
      run = nil
  window.onFrame = nil
  connection.close()
