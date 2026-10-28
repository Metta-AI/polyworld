import
  std/[os, random, strutils, uri],
  bumpy, chroma, jsony, silky, vmath, windy,
  polyworld/[chrome, connections, menus, roomclients, rooms, policies, viewers],
  content, controls, game, graphics, homes, lobbies, multiplayer, presets, replays

const AppName = "Polyworld GotA"

proc bundledBot(name, file: string): LocalPolicy =
  ## Loads the base bot from the native checkout or the web data bundle.
  let path =
    when defined(emscripten):
      "/policies/gota/" & file & ".bas"
    else:
      currentSourcePath().parentDir / "players" / (file & ".bas")
  LocalPolicy(name: name, bytes: readPolicyBytes(path))

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
    viewedPayload: string
    configDirty, configPending: bool
    lobbyUi = LobbyUi()
    rng = initRand(2026)
    publicRoom = true
    humanSeat = 0
    multiplayerHuman = -1
    localPolicies: array[HeroClassCount, LocalPolicy]
    networkPolicies: array[HeroClassCount, LocalPolicy]
    chosenPolicy: LocalPolicy
    launchLocal, launchNetwork: bool
    homeFocus: int
  try:
    preferences = readPreferences(AppName)
  except MenusError, IOError, OSError:
    error = getCurrentExceptionMsg()
  preferences.applyPreferences(window)
  let bots = @[
    bundledBot("Base bot", "base"),
    bundledBot("Rusher", "rusher"),
    bundledBot("Puller", "puller"),
    bundledBot("Jev", "jev")
  ]
  let base = bots[0]
  for policy in localPolicies.mitems:
    policy = base
  chosenPolicy = base
  config.seed = options.seed
  config.maxTicks = options.maximumTicks
  config.spawnIntervalTicks = options.spawnIntervalTicks
  let inviteServer = inviteParameter("server")
  if inviteServer.len > 0:
    preferences.server = inviteServer
  if invite.len > 0:
    page = MultiplayerMenu
  if serverAddress.len > 0:
    preferences.server = serverAddress
    page = MultiplayerMenu
    try:
      connection = connect(
        preferences.server,
        preferences.name,
        gotaIdentity()
      )
    except CatchableError as problem:
      error = problem.msg

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
          if configPending and client.snapshot.payload == config.toJson():
            configDirty = false
            configPending = false
          if viewedPayload != client.snapshot.payload:
            try:
              config = parseConfig(client.snapshot.payload)
              viewedPayload = client.snapshot.payload
              configDirty = false
            except GotaConfigError as problem:
              error = problem.msg
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
      options.playerSlot = int32(
        connection.client.snapshot.humanSeatFor(connection.client.participant) + 1
      )
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
      if page == HomeMenu:
        case sk.drawHome(window, homeFocus)
        of StayHome: discard
        of PlaySingle:
          page = SingleMenu
          lobbyUi.scroll = 0
          lobbyUi.selectedSeat = -1
        of PlayMultiplayer:
          page = MultiplayerMenu
          lobbyUi.scroll = 0
          lobbyUi.selectedSeat = -1
        of OpenSettings: page = SettingsMenu
        of ExitGame:
          when not defined(emscripten):
            window.closeRequested = true
        if error.len > 0:
          sk.menuLabel(error, vec2(24, 24), color = rgbx(245, 151, 139, 255))
        sk.endUi()
        window.presentFrame(framePaceHz)
        reportReplayFrame(0, 0)
        return
      var layout: LobbyLayout
      let origin =
        if page == SettingsMenu:
          sk.textStyle = "Default"
          sk.beginLobbySettings(window)
        else:
          layout = sk.beginLobby(
            window, lobbyUi,
            if page == MultiplayerMenu: "MULTIPLAYER" else: "BATTLE SETUP",
            page == MultiplayerMenu
          )
          layout.origin
      try:
        case page
        of HomeMenu:
          discard
        of MultiplayerMenu:
          let
            connected = connection != nil and connection.client.welcomed
            p = layout.origin + vec2(32, 144)
            totalWidth = if layout.compact: 936.0'f else: 1450.0'f
          sk.lobbyPanel(p, vec2(totalWidth, 74))
          sk.lobbyLabel("Server", p + vec2(20, 16), 90, "LobbyBold")
          sk.lobbyInput(window, "server", preferences.server,
            p + vec2(112, 15), totalWidth - 470)
          if sk.lobbyButton(if connected: "Reconnect" else: "Connect",
            p + vec2(totalWidth - 340, 15), 160):
              connection.close()
              connection = connect(
                preferences.server, preferences.name, gotaIdentity()
              )
              preferences.savePreferences(AppName)
              prepared = nil
              preparedRevision = 0
              viewedRevision = 0
              viewedPayload = ""
              configPending = false
              multiplayerHuman = -1
              networkPolicies = default(array[HeroClassCount, LocalPolicy])
              error = ""
          sk.lobbyIcon("status", p + vec2(totalWidth - 156, 23), 24,
            if connected: rgbx(130, 215, 110, 255) else: LobbyMuted)
          sk.lobbyLabel(if connected: "Connected" else: "Offline",
            p + vec2(totalWidth - 122, 16), 116)
          sk.lobbyPanel(layout.left, vec2(layout.leftWidth, 622))
          let list = layout.left + vec2(22)
          sk.lobbyIcon("units", list + vec2(0, 8), 38)
          sk.lobbyLabel("PUBLIC ROOMS", list + vec2(50, 0), 500,
            "LobbyHeading")
          sk.lobbyLabel("Rooms for this game version", list + vec2(50, 38),
            500, tint = LobbyMuted)
          if sk.lobbyButton("Refresh", list + vec2(layout.leftWidth - 204, 6),
            160, "loop", connected):
              connection.client.send(RoomMessage(kind: ListRooms))
          sk.lobbyIcon("search", list + vec2(4, 94))
          sk.lobbyInput(window, "roomSearch", lobbyUi.search,
            list + vec2(44, 84), layout.leftWidth - 88)
          sk.lobbyLabel("ROOM", list + vec2(0, 136), 360, tint = LobbyMuted)
          sk.lobbyLabel("PLAYERS", list + vec2(390, 136), 130,
            tint = LobbyMuted)
          sk.lobbyLabel("STATUS", list + vec2(540, 136), 130,
            tint = LobbyMuted)
          var matches: seq[int]
          if connected:
            for i, room in connection.client.listings:
              if lobbyUi.search.toLowerAscii() in room.name.toLowerAscii():
                matches.add i
          lobbyUi.roomPage = min(lobbyUi.roomPage,
            max(0, (matches.len - 1) div 5))
          for row in 0 ..< 5:
            let index = lobbyUi.roomPage * 5 + row
            if index >= matches.len:
              break
            let
              room = connection.client.listings[matches[index]]
              point = list + vec2(0, 184 + row.float32 * 68)
              watching = room.phase != rooms.Lobby or room.occupied == room.seats
            sk.lobbyPanel(point, vec2(layout.leftWidth - 44, 60), true)
            sk.lobbyLabel(room.name, point + vec2(12, 10), 365, "LobbyBold")
            sk.lobbyLabel($room.occupied & " / " & $room.seats,
              point + vec2(390, 10), 130)
            sk.lobbyIcon("status", point + vec2(540, 20), 20,
              if watching: LobbyMuted else: rgbx(130, 215, 110, 255))
            sk.lobbyLabel(if room.phase != rooms.Lobby: $room.phase
              elif watching: "Full" else: "Open", point + vec2(570, 10), 120)
            if sk.lobbyButton(if watching: "Watch" else: "Join",
              point + vec2(layout.leftWidth - 184, 8), 128, "arrow_right"):
                connection.client.send(RoomMessage(kind: JoinRoom, room: room.id))
                lobbyUi.scroll = 0
          if matches.len == 0:
            sk.lobbyLabel(if connected: "No rooms found. Create one to begin."
              else: "Connect to a server to browse rooms.",
              list + vec2(12, 200), layout.leftWidth - 68, tint = LobbyMuted)
          sk.lobbyLabel($matches.len & " rooms", list + vec2(0, 554), 300)
          if sk.lobbyButton("Previous", list + vec2(430, 550), 150,
            enabled = lobbyUi.roomPage > 0):
              dec lobbyUi.roomPage
          sk.lobbyLabel($(lobbyUi.roomPage + 1) & " / " &
            $max(1, (matches.len + 4) div 5), list + vec2(600, 552), 100)
          if sk.lobbyButton("Next", list + vec2(layout.leftWidth - 194, 550),
            150, enabled = (lobbyUi.roomPage + 1) * 5 < matches.len):
              inc lobbyUi.roomPage
          sk.lobbyPanel(layout.right, vec2(layout.rightWidth, 622))
          let
            create = layout.right + vec2(22)
            width = layout.rightWidth - 44
          sk.lobbyIcon("cross", create + vec2(0, 8), 32)
          sk.lobbyLabel("CREATE ROOM", create + vec2(44, 0), width - 44,
            "LobbyHeading")
          sk.lobbyLabel("Room name", create + vec2(0, 52), width)
          sk.lobbyInput(window, "roomName", roomName,
            create + vec2(0, 96), width)
          sk.lobbyLabel("Visibility", create + vec2(0, 146), width)
          if sk.lobbyButton("Public", create + vec2(0, 190),
            width / 2 - 6, "globe", selected = publicRoom):
              publicRoom = true
          if sk.lobbyButton("Private", create + vec2(width / 2 + 6, 190),
            width / 2 - 6, "lock", selected = not publicRoom):
              publicRoom = false
          sk.lobbyLabel(if publicRoom: "Listed in public rooms."
            else: "Only people with an invite can join.",
            create + vec2(0, 238), width, tint = LobbyMuted)
          if sk.lobbyButton("Create Room", create + vec2(0, 288), width,
            "cross", connected and roomName.strip().len > 0):
              connection.client.send(RoomMessage(
                kind: CreateRoom, name: roomName, number: HeroClassCount,
                tickRate: uint32(TickRate), flag: publicRoom,
                payload: config.toJson()
              ))
              lobbyUi.scroll = 0
          sk.lobbyIcon("link", create + vec2(0, 368))
          sk.lobbyLabel("JOIN BY INVITE", create + vec2(44, 360), width - 44,
            "LobbyHeading")
          sk.lobbyLabel("Invite link or room code", create + vec2(0, 410), width)
          sk.lobbyInput(window, "inviteRoom", invite,
            create + vec2(0, 456), width)
          if sk.lobbyButton("Join Room", create + vec2(0, 550), width,
            "arrow_right", connected and invite.strip().len > 0):
              if invite.contains("?"):
                let parsed = parseUri(invite)
                for key, value in decodeQuery(parsed.query):
                  if key == "room":
                    invite = value
              joinRequested = true
              lobbyUi.scroll = 0
          if sk.lobbyButton("Back", layout.footer, 190, "arrow_left"):
            connection.close()
            connection = nil
            error = ""
            page = HomeMenu
        of SingleMenu, LobbyMenu:
          let
            online = page == LobbyMenu
            client = if online: connection.client else: nil
            snapshot = if online: client.snapshot else: RoomMessage()
            editable = not online or snapshot.phase == rooms.Lobby
            owner = not online or snapshot.participant == client.participant
            modal = lobbyUi.selectedSeat != -1
          if online and snapshot.seats.len != HeroClassCount:
            raise newException(MenusError, "GotA rooms require ten seats")
          sk.rosterPanel(layout)
          var
            emptyCount = 0
            ownCount = 0
            readyToStart = true
            selfReady = false
          for i in 0 ..< HeroClassCount:
            let
              seat = if online: snapshot.seats[i] else: Seat()
              empty = if online: seat.owner == 0
                else: i != humanSeat and localPolicies[i].bytes.len == 0
              mine = not online or seat.owner == client.participant
              human = if online: seat.name == "Human" else: i == humanSeat
            var
              name = if empty: "Add player" elif human: "You"
                elif online: seat.name else: localPolicies[i].name
              controller = if empty: "Empty slot" elif human: "HUMAN" else: "BOT"
            if online and not empty:
              for participant in snapshot.participants:
                if participant.id == seat.owner:
                  controller = participant.name &
                    (if participant.ready: " / Ready" else: " / Not ready")
                  if human:
                    name = participant.name
                  readyToStart = readyToStart and participant.ready and
                    participant.connected
                  if mine:
                    selfReady = participant.ready
              if mine:
                inc ownCount
            if empty:
              inc emptyCount
              readyToStart = false
            if sk.seatButton(layout, i, name, controller, human, empty,
              editable and (mine or empty) and not modal):
                lobbyUi.selectedSeat = i
          let
            fill = layout.left + vec2(22, 548)
            botWidth = 216.0'f
          sk.lobbyLabel("Fill empty slots", fill, 210, "LobbyBold")
          var botNames: seq[string]
          for bot in bots:
            botNames.add bot.name
          if chosenPolicy.name notin botNames:
            botNames.add chosenPolicy.name
          sk.lobbySelect(window, lobbyUi.selectedBot, botNames, fill + vec2(216, 0),
            botWidth, editable and not modal)
          for bot in bots:
            if bot.name == lobbyUi.selectedBot:
              chosenPolicy = bot
          if sk.lobbyButton("Fill " & $emptyCount & " slots",
            fill + vec2(444, 0), 198, "cross",
            editable and emptyCount > 0 and not modal):
              for i in 0 ..< HeroClassCount:
                if online:
                  if snapshot.seats[i].owner == 0:
                    networkPolicies[i] = chosenPolicy
                    client.send(RoomMessage(kind: ClaimSeat, seat: uint32(i),
                      name: chosenPolicy.name))
                elif i != humanSeat and localPolicies[i].bytes.len == 0:
                  localPolicies[i] = chosenPolicy
          if sk.lobbyButton(if online: "Shuffle mine" else: "Shuffle",
            fill + vec2(654, 0), layout.leftWidth - 698, "shuffle",
            editable and not modal):
              var seats: seq[int]
              for i in 0 ..< HeroClassCount:
                if not online or snapshot.seats[i].owner == client.participant:
                  seats.add i
              var shuffled = seats
              rng.shuffle(shuffled)
              let
                oldPolicies = if online: networkPolicies else: localPolicies
                oldHuman = if online: multiplayerHuman else: humanSeat
              for j, destination in seats:
                let source = shuffled[j]
                if online:
                  networkPolicies[destination] = oldPolicies[source]
                  if oldHuman == source:
                    multiplayerHuman = destination
                  client.send(RoomMessage(kind: ClaimSeat,
                    seat: uint32(destination), name: snapshot.seats[source].name))
                else:
                  localPolicies[destination] = oldPolicies[source]
                  if oldHuman == source:
                    humanSeat = destination
          sk.lobbyLabel(if online: "Other players keep control of their seats."
            else: "Fill keeps assigned humans and bots. Clear a slot to replace it.",
            fill + vec2(0, 54), layout.leftWidth - 44, tint = LobbyMuted)
          if sk.configPanel(window, lobbyUi, config, layout.right, layout.rightWidth,
            owner and editable and not modal and not configPending):
              configDirty = online
          if online:
            let info = layout.left + vec2(22, 640)
            if sk.lobbyButton("Participants", info, 190, "units", not modal):
              lobbyUi.selectedSeat = -2
            sk.lobbyLabel(snapshot.name, info + vec2(208, 0), 400,
              tint = LobbyMuted)
            if sk.lobbyButton("Copy invite", layout.footer + vec2(204, 0),
              200, "link", not modal):
                copyInvite(inviteBase() & "?server=" & encodeUrl(preferences.server) &
                  "&room=" & encodeUrl(snapshot.room))
            if sk.lobbyButton(if selfReady: "Ready" else: "Ready up",
              layout.footer + vec2(420, 0), 190, "status",
              editable and ownCount > 0 and not configDirty and not modal):
                var sources: array[HeroClassCount, string]
                for i, policy in networkPolicies:
                  sources[i] = policy.bytes
                prepared = prepareNetworkMatch(client, sources)
                preparedRevision = snapshot.revision
                client.send(RoomMessage(kind: Ready, revision: snapshot.revision,
                  hash: prepared.game.networkHash()))
            if configDirty and owner and editable:
              if sk.lobbyButton("Apply Settings", layout.primary,
                250, "settings", not modal and not configPending):
                  discard parseConfig(config.toJson())
                  client.send(RoomMessage(
                    kind: ConfigureRoom, name: snapshot.name,
                    number: HeroClassCount, tickRate: uint32(TickRate),
                    flag: publicRoom, payload: config.toJson()
                  ))
                  configPending = true
            else:
              if sk.lobbyButton("Start Game", layout.primary,
                250, "arrow_right",
                owner and editable and readyToStart and not modal,
                tint = LobbyGreen):
                  client.send(RoomMessage(kind: StartMatch))
            if sk.lobbyButton(
              if owner and snapshot.phase in {rooms.Ended, Desynced}:
                "Return to lobby" else: "Leave room",
              layout.footer, 190, "arrow_left", not modal
            ):
              if owner and snapshot.phase in {rooms.Ended, Desynced}:
                client.send(RoomMessage(kind: ReturnLobby))
                client.error = ""
                error = ""
              else:
                client.send(RoomMessage(kind: LeaveRoom))
                page = MultiplayerMenu
                prepared = nil
                preparedRevision = 0
                viewedRevision = 0
                viewedPayload = ""
                multiplayerHuman = -1
                networkPolicies = default(array[HeroClassCount, LocalPolicy])
                lobbyUi.scroll = 0
          else:
            if sk.lobbyButton("Back", layout.footer, 190, "arrow_left", not modal):
              page = HomeMenu
            if sk.lobbyButton("Start Game", layout.primary,
              250, "arrow_right", emptyCount == 0 and not modal,
              tint = LobbyGreen):
                discard parseConfig(config.toJson())
                launchLocal = true
            sk.lobbyLabel(if humanSeat < 0: "Spectating bots"
              else: "Playing seat " & $(humanSeat + 1),
              layout.left + vec2(22, 638), 800, tint = LobbyMuted)
          let selectedSeat = lobbyUi.selectedSeat
          let choice =
            if modal: sk.seatPicker(window, lobbyUi, bots)
            else: SlotChoice()
          if choice.chosen:
            var selected = if choice.file: selectPolicy()
              elif choice.human or choice.clear: LocalPolicy()
              else: bots[choice.bot]
            if not choice.file or selected.bytes.len > 0:
              if choice.file:
                chosenPolicy = selected
                lobbyUi.selectedBot = selected.name
              if online:
                if choice.human:
                  client.claimHumanSeat(selectedSeat, multiplayerHuman)
                  for i, seat in snapshot.seats:
                    if i == multiplayerHuman or
                      (seat.owner == client.participant and seat.name == "Human"):
                        networkPolicies[i] = LocalPolicy()
                  multiplayerHuman = selectedSeat
                else:
                  if multiplayerHuman == selectedSeat:
                    multiplayerHuman = -1
                  client.send(RoomMessage(
                    kind: if choice.clear: ReleaseSeat else: ClaimSeat,
                    seat: uint32(selectedSeat), name: selected.name
                  ))
                networkPolicies[selectedSeat] = selected
              else:
                if choice.human:
                  if humanSeat >= 0 and humanSeat != selectedSeat:
                    localPolicies[humanSeat] = LocalPolicy()
                  humanSeat = selectedSeat
                elif humanSeat == selectedSeat:
                  humanSeat = -1
                localPolicies[selectedSeat] = selected
              lobbyUi.selectedSeat = -1
          if online and lobbyUi.selectedSeat == -2:
            sk.pushLayer(PopupsLayer)
            let
              view = window.size.vec2 / sk.uiScale
              at = (view - vec2(650, 500)) * 0.5'f
            discard sk.interact(rect(vec2(0), view), true)
            sk.drawRect(vec2(0), view, rgbx(0, 0, 0, 180))
            sk.lobbyPanel(at, vec2(650, 500))
            sk.lobbyLabel("PARTICIPANTS", at + vec2(24, 16), 580,
              "LobbyHeading")
            lobbyUi.participantPage = min(lobbyUi.participantPage,
              max(0, (snapshot.participants.len - 1) div 6))
            for row in 0 ..< 6:
              let index = lobbyUi.participantPage * 6 + row
              if index >= snapshot.participants.len:
                break
              let
                participant = snapshot.participants[index]
                point = at + vec2(24, 76 + row.float32 * 48)
              sk.lobbyLabel(participant.name &
                (if not participant.connected: " / Offline"
                 elif participant.ready: " / Ready" else: " / Not ready"),
                point, 430)
              if sk.lobbyButton("Remove", point + vec2(450, 0), 140,
                enabled = owner and editable and
                  participant.id != client.participant):
                    client.send(RoomMessage(kind: KickParticipant,
                      participant: participant.id))
            if sk.lobbyButton("Previous", at + vec2(24, 422), 170,
              enabled = lobbyUi.participantPage > 0):
                dec lobbyUi.participantPage
            if sk.lobbyButton("Next", at + vec2(210, 422), 170,
              enabled = (lobbyUi.participantPage + 1) * 6 <
                snapshot.participants.len):
                  inc lobbyUi.participantPage
            if sk.lobbyButton("Close", at + vec2(396, 422), 230):
              lobbyUi.selectedSeat = -1
            sk.popLayer()
        of SettingsMenu:
          if sk.settingsPanel(window, preferences, AppName, origin, ""):
            page = HomeMenu
      except CatchableError as problem:
        error = problem.msg
      if error.len > 0:
        sk.lobbyLabel(error, vec2(24, 0), 1400, tint = rgbx(245, 151, 139, 255))
      sk.textStyle = "Default"
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
