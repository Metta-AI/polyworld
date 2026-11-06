import
  std/[os, random, strutils, uri],
  bumpy, chroma, jsony, silky, vmath, windy,
  polyworld/[displays, chrome, connections, menus, roomclients, rooms, policies, viewers],
  content, controls, game, graphics, homes, lobbies, multiplayer, presets, replays,
  rosterstate, participantcontext, lobbyreadiness

const AppName = "Polyworld LvD"

proc bundledBot(name, file: string): LocalPolicy =
  ## Loads the base bot from the native checkout or the web data bundle.
  let path =
    when defined(emscripten):
      "/policies/lvd/" & file & ".bas"
    else:
      currentSourcePath().parentDir / "players" / (file & ".bas")
  LocalPolicy(name: name, bytes: readPolicyBytes(path))

proc runFrontend*() =
  ## Owns menu, lobby, match and return transitions on the same window.
  initializeGraphics()
  let inviteServer = inviteParameter("server")
  var
    preferences = Preferences()
    page = HomeMenu
    error: string
    roomName: string
    matchName, namedRoom, publishedName: string
    invite = inviteParameter("room")
    joinRequested = invite.len > 0
    connection: Connection
    prepared: NetworkMatch
    preparedRevision = 0'u32
    readyRefresh: ReadyRefresh
    viewedRevision = 0'u32
    config = defaultConfig()
    viewedPayload: string
    roster: RosterState
    lobbyUi = LobbyUi()
    rosterScroll = FrameState()
    participantMenu: ParticipantContext
    contextDismissGuard: bool
    rng = initRand(2026)
    publicRoom = true
    humanSeat = -1
    multiplayerHuman = -1
    localPolicies = newSeq[LocalPolicy](config.playerCount)
    networkPolicies = newSeq[LocalPolicy](config.playerCount)
    chosenPolicy: LocalPolicy
    launchLocal, launchNetwork: bool
    homeFocus: int
    playerName: string
    editingPlayer: bool
    connectRequested: bool
  try:
    preferences = readLvdPreferences()
  except MenusError, IOError, OSError:
    error = getCurrentExceptionMsg()
  preferences = effectivePreferences(preferences, inviteServer, serverAddress)
  preferences.applyPreferences(window)
  roomName = defaultGameName(preferences.name)
  let bots = @[
    bundledBot("Base bot", "base")
  ]
  let base = bots[0]

  chosenPolicy = base
  config.seed = options.seed
  config.maxTicks = options.maximumTicks
  config.mapSettings = mapSettings
  config.diplomacySettings = diplomacySettings
  if opensMultiplayer(invite):
    page = MultiplayerMenu
    connectRequested = true

  while not window.closeRequested:
    when not defined(emscripten):
      window.updateWindowSettings()
    launchLocal = false
    launchNetwork = false
    if connectRequested and preferences.name.len <= 64 and
      validName(preferences.name):
        connectRequested = false
        try:
          preferences.server = serverUrl(preferences.server)
          preferences.savePreferences(AppName)
          connection.close()
          connection = connect(
            preferences.server,
            preferences.name,
            lvdIdentity()
          )
          prepared = nil
          preparedRevision = 0
          viewedRevision = 0
          readyRefresh = ReadyRefresh()
          viewedPayload = ""
          roster = RosterState()
          multiplayerHuman = -1
          networkPolicies = newSeq[LocalPolicy](config.playerCount)
          error = ""
        except CatchableError as problem:
          error = problem.msg
    if connection != nil:
      connection.pump()
      let client = connection.client
      if client.welcomed and joinRequested and invite.len > 0 and
        client.snapshot.room.len == 0:
        client.send(RoomMessage(kind: JoinRoom, room: invite))
        joinRequested = false
      if client.snapshot.room.len == 0 and
          (page == LobbyMenu or viewedRevision != 0 or prepared != nil):
        if page == LobbyMenu: page = MultiplayerMenu
        prepared = nil
        preparedRevision = 0
        readyRefresh = ReadyRefresh()
        viewedRevision = 0
        viewedPayload = ""
        roster = RosterState()
        multiplayerHuman = -1
        networkPolicies = newSeq[LocalPolicy](config.playerCount)
      if client.snapshot.room.len > 0:
        if namedRoom != client.snapshot.room or publishedName != client.snapshot.name:
          namedRoom = client.snapshot.room
          publishedName = client.snapshot.name
          matchName = publishedName
        page = LobbyMenu
        if viewedRevision != client.snapshot.revision:
          if viewedPayload != client.snapshot.payload or
            (roster.pending and client.snapshot.payload == roster.pendingPayload):
            try:
              roster.acceptConfig(config, client.snapshot.payload)
              networkPolicies.setLen(config.playerCount)
              viewedPayload = client.snapshot.payload
            except CatchableError as problem:
              error = problem.msg
          viewedRevision = client.snapshot.revision
        try:
          var sources = newSeq[string](networkPolicies.len)
          for i, policy in networkPolicies:
            sources[i] = policy.bytes
          discard readyRefresh.refreshRetainedReady(client, sources,
            prepared, preparedRevision)
        except CatchableError as problem:
          error = problem.msg
      if client.events.len > 0:
        let event = client.events[0]
        client.events.delete(0)
        try:
          if prepared == nil or preparedRevision != event.revision:
            var sources = newSeq[string](networkPolicies.len)
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
        if roster.pending and client.snapshot.room.len > 0:
          roster.rejectConfig(config, client.snapshot.payload)
          networkPolicies.setLen(config.playerCount)
    if launchNetwork:
      run = prepared.game
      options.playerSlot = int32(
        prepared.humanPlayerFor(connection.client.participant) + 1
      )
      options.replayPath = ""
      options.recordPath = ""
      options.pauseOnStart = false
      options.speed = 1
      let quitToMenu = runGraphics(prepared, connection)
      preferences = effectivePreferences(
        readLvdPreferences(), inviteServer, serverAddress
      )
      if quitToMenu:
        connection.close()
        connection = nil
        page = HomeMenu
        error = ""
        viewedRevision = 0
        multiplayerHuman = -1
        networkPolicies = newSeq[LocalPolicy](config.playerCount)
        viewedPayload = ""
        roster = RosterState()
      prepared = nil
      preparedRevision = 0
      clearPlayerCommands()
      readyRefresh = ReadyRefresh()
      run = nil
      continue

    window.onButtonPress = proc(button: Button) =
      ## Adjusts UI scale with the same shortcuts as a browser.
      discard window.scaleKey(
        button, preferences, sk.uiScale, AppName
      )
    window.onFrame = proc() =
      ## Draws this lifecycle state without constructing a hidden match.
      var contextInputBlocked = false
      if page != LobbyMenu:
        participantMenu.dismiss()
        contextDismissGuard = false
      let needsPlayerName = preferences.name.len > 64 or
        not validName(preferences.name)
      if editingPlayer or (page == MultiplayerMenu and needsPlayerName):
          sk.textStyle = "Default"
          discard sk.beginSettings(window)
          sk.drawHomeBackground(window)
          let
            view = window.size.vec2 / sk.uiScale
            at = (view - vec2(620, 260)) * 0.5'f
            name = playerName.strip()
            valid = name.len <= 64 and validName(name)
          sk.drawRect(vec2(0), view, rgbx(0, 0, 0, 110))
          sk.lobbyPanel(at, vec2(620, 260))
          sk.drawLabel(if needsPlayerName: "Please enter your player name"
            else: "Change your player name",
            at + vec2(24, 20), vec2(572, 40),
            sk.theme.defaultTextColor, "H1")
          sk.menuInput(window, "newPlayerName", playerName,
            at + vec2(24, 80), 572, 44)
          if playerName.len > 0 and not valid:
            sk.drawLabel("Enter a shorter name without line breaks.",
              at + vec2(24, 128), vec2(572, 28),
              sk.theme.disabledTextColor)
          if sk.lobbyButton("Cancel", at + vec2(24, 188), 180) or
            window.buttonPressed[KeyEscape]:
              if needsPlayerName and page == MultiplayerMenu:
                page = HomeMenu
                connectRequested = false
              editingPlayer = false
              playerName = ""
              error = ""
          elif sk.lobbyButton(if needsPlayerName: "Continue" else: "Save",
            at + vec2(396, 188), 200,
            enabled = valid) or (valid and window.buttonPressed[KeyEnter]):
              var updated = preferences
              updated.name = name
              try:
                updated.savePreferences(AppName)
                if roomName == defaultGameName(preferences.name):
                  roomName = defaultGameName(updated.name)
                preferences = updated
                editingPlayer = false
                if connection != nil and connection.client.name != name:
                  connection.client.name = name
                  connection.reconnectAfter(0)
                error = ""
              except MenusError, IOError, OSError:
                error = getCurrentExceptionMsg()
          if error.len > 0:
            sk.menuLabel(error, at + vec2(0, 272), color = LobbyRed)
          sk.endUi()
          window.presentFrame(framePaceHz)
          reportReplayFrame(0, 0)
          return
      if page == HomeMenu:
        case sk.drawLvdHome(window, homeFocus)
        of StayHome: discard
        of PlaySingle:
          roster = RosterState()
          localPolicies.setLen(config.playerCount)
          if humanSeat >= config.playerCount: humanSeat = -1
          config.playerSlot = 0
          page = SingleMenu
          lobbyUi.scroll = 0
          lobbyUi.selectedSeat = -1
          rosterScroll.scrollPos = vec2(0)
        of PlayMultiplayer:
          config.playerSlot = 0
          page = MultiplayerMenu
          connectRequested = preferences.server.strip().len > 0 and
            not connection.connecting() and
            (connection == nil or not connection.client.connected)
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
          layout =
            if page in {SingleMenu, LobbyMenu}:
              sk.beginLvdBattle(window, lobbyUi, config.playerCount,
                participantMenu.isOpen or contextDismissGuard)
            else:
              sk.beginLobby(window, lobbyUi, "MULTIPLAYER", true)
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
          let previousServer = preferences.server
          sk.lobbyInput(window, "server", preferences.server,
            p + vec2(112, 15), totalWidth - 470)
          if preferences.server != previousServer:
            preferences.savePreferences(AppName)
          if sk.lobbyButton(if connected: "Reconnect" else: "Connect",
            p + vec2(totalWidth - 340, 15), 160):
              connectRequested = true
          sk.lobbyIcon("status", p + vec2(totalWidth - 156, 23), 24,
            if connected: rgbx(130, 215, 110, 255) else: LobbyMuted)
          sk.lobbyLabel(if connected: "Connected" else: "Offline",
            p + vec2(totalWidth - 122, 16), 116)
          sk.lobbyPanel(layout.left, vec2(layout.leftWidth, layout.panelHeight))
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
          let
            rowsAt = list + vec2(0, 184)
            rowsSize = vec2(layout.leftWidth - 44, layout.panelHeight - 268)
            contentSize = vec2(rowsSize.x, matches.len.float32 * 68)
          if lobbyUi.roomScroll == nil:
            lobbyUi.roomScroll = FrameState()
          lobbyUi.roomListOverflow = contentSize.y > rowsSize.y
          sk.frameScrollbars(window, lobbyUi.roomScroll,
            rect(rowsAt, rowsSize), contentSize, vec2(1))
          sk.pushClipRect(rect(rowsAt, rowsSize - vec2(14, 0)))
          let rowsOrigin = rowsAt - lobbyUi.roomScroll.scrollPos
          for row in 0 ..< matches.len:
            let
              room = connection.client.listings[matches[row]]
              point = rowsOrigin + vec2(0, row.float32 * 68)
              watching = room.phase != rooms.Lobby or room.occupied == room.seats
            sk.lobbyPanel(point, vec2(rowsSize.x - 16, 60), true)
            sk.lobbyLabel(room.name, point + vec2(12, 10), 365, "LobbyBold")
            sk.lobbyLabel($room.occupied & " / " & $room.seats,
              point + vec2(390, 10), 130)
            sk.lobbyIcon("status", point + vec2(540, 20), 20,
              if watching: LobbyMuted else: rgbx(130, 215, 110, 255))
            sk.lobbyLabel(if room.phase != rooms.Lobby: $room.phase
              elif watching: "Full" else: "Open", point + vec2(570, 10), 120)
            if sk.lobbyButton(if watching: "Watch" else: "Join",
              point + vec2(rowsSize.x - 156, 8), 128, "arrow_right"):
                connection.client.send(RoomMessage(kind: JoinRoom, room: room.id))
                lobbyUi.scroll = 0
          sk.popClipRect()
          if matches.len == 0:
            sk.lobbyLabel(if connected: "No rooms found. Create one to begin."
              elif error.len > 0: error
              else: connection.status(),
              list + vec2(12, 200), layout.leftWidth - 68, tint = LobbyMuted)
            if not connected:
              sk.lobbyLabel("Plain server: ws://host:port/ws",
                list + vec2(12, 240), layout.leftWidth - 68, tint = LobbyMuted)
              sk.lobbyLabel("wss:// requires a server with TLS enabled.",
                list + vec2(12, 278), layout.leftWidth - 68, tint = LobbyMuted)
          sk.lobbyLabel($matches.len & " rooms",
            list + vec2(0, layout.panelHeight - 68), 300)
          sk.lobbyPanel(layout.right, vec2(layout.rightWidth, layout.panelHeight))
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
                kind: CreateRoom, name: roomName, number: uint32(config.playerCount),
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
          if sk.lobbyButton("Join Room", create + vec2(0, layout.panelHeight - 72), width,
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
            contextBlocked = participantMenu.isOpen or contextDismissGuard
            modal = lobbyUi.selectedSeat != -1 or contextBlocked
          # Keep the underlying UI inert for the entire dismissal gesture.
          contextInputBlocked = contextBlocked
          contextDismissGuard = contextBlocked and window.buttonDown[MouseLeft]
          participantMenu.update(client, sk.mousePos, window.size.vec2 / sk.uiScale,
            leftPressed = window.buttonPressed[MouseLeft],
            leftReleased = window.buttonReleased[MouseLeft],
            rightPressed = window.buttonPressed[MouseRight],
            escape = window.buttonPressed[KeyEscape])
          if online and not roster.pending and snapshot.seats.len != config.playerCount:
            raise newException(MenusError, "Room roster does not match its settings")
          sk.lvdRosterPanel(layout)
          sk.beginRoster(window, layout, rosterScroll, config.playerCount, not modal)
          var
            emptyCount = 0
            ownCount = 0
            selfReady = readyRefresh.cosmeticReady
          for i in 0 ..< config.playerCount:
            let
              seat = if online and i < snapshot.seats.len: snapshot.seats[i] else: Seat()
              empty = if online: seat.owner == 0
                else: i != humanSeat and localPolicies[i].bytes.len == 0
              mine = not online or seat.owner == client.participant
              human = if online: seat.name == "Human" else: i == humanSeat
            var
              name = if empty: "Add player"
                elif human:
                  if preferences.name.len > 0: preferences.name else: "Player"
                elif online: seat.name else: localPolicies[i].name
              controller = if empty: "Empty slot" elif human: "HUMAN" else: "BOT"
            if online and not empty:
              for participant in snapshot.participants:
                if participant.id == seat.owner:
                  controller = participant.name
                  if mine:
                    controller.add(if selfReady: " / Ready" else: " / Not ready")
                  if human:
                    name = participant.name

              if mine:
                inc ownCount
            if empty:
              inc emptyCount
            if sk.seatButton(layout, i, rosterScroll.scrollPos.y, name, controller, human, empty,
              editable and (mine or empty) and not modal and
                roster.assignmentsEnabled(online), config.seed):
                lobbyUi.selectedSeat = i
            if online and not modal and window.buttonPressed[MouseRight] and
                rosterCardHit(layout, i, rosterScroll.scrollPos.y, sk.mousePos):
              participantMenu.openSeat(client, i, sk.mousePos)
          sk.popClipRect()
          let rosterAt = rosterControlsPosition(layout)
          sk.lobbyLabel($config.playerCount & " players", rosterAt + vec2(454, 0), 180)
          if owner:
            let canResize = owner and editable and not modal and not roster.pending
            if sk.lobbyButton("Add player", rosterAt, 210, "cross",
              canResize and config.playerCount < MaxSeats):
                if online: client.error = ""
                roster.resizeRoster(config, client, config.playerCount + 1, publicRoom)
                if online:
                  networkPolicies.setLen(config.playerCount)
                else:
                  localPolicies.add LocalPolicy()
            if sk.lobbyButton("Remove last", rosterAt + vec2(222, 0), 210, "minus",
              canResize and config.playerCount > 1):
                if online: client.error = ""
                roster.resizeRoster(config, client, config.playerCount - 1, publicRoom)
                if online:
                  networkPolicies.setLen(config.playerCount)
                  multiplayerHuman = humanAfterRemoval(multiplayerHuman, config.playerCount)
                else:
                  localPolicies.setLen(config.playerCount)
                  humanSeat = humanAfterRemoval(humanSeat, config.playerCount)
            let
              fill = layout.left + vec2(22, layout.panelHeight - 164)
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
              editable and emptyCount > 0 and not modal and
                roster.assignmentsEnabled(online)):
                for i in 0 ..< config.playerCount:
                  if online:
                    if snapshot.seats[i].owner == 0:
                      networkPolicies[i] = chosenPolicy
                      client.send(RoomMessage(kind: ClaimSeat, seat: uint32(i),
                        name: chosenPolicy.name))
                  elif i != humanSeat and localPolicies[i].bytes.len == 0:
                    localPolicies[i] = chosenPolicy
            if sk.lobbyButton("Shuffle players",
              fill + vec2(654, 0), layout.leftWidth - 698, "shuffle",
              editable and not modal and roster.assignmentsEnabled(online)):
                var seats: seq[int]
                for i in 0 ..< config.playerCount:
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
            sk.lobbyLabel(if online and roster.pending: "Saving roster / settings..."
              elif online: "Host-owned slots only; guests keep their seats."
              else: "Fill keeps assigned humans and bots. Clear a slot to replace it.",
              fill + vec2(0, 54), layout.leftWidth - 44, tint = LobbyMuted)
          if sk.configPanel(window, lobbyUi, config, layout.right,
            layout.rightWidth, layout.panelHeight,
            owner and editable and not modal and not roster.pending,
            showControls = owner,
            gameName = if online: addr matchName else: nil):
              roster.dirty = online
          if online and owner and editable and not modal and not roster.pending and
              matchName != snapshot.name and window.buttonPressed[KeyEnter]:
            discard client.renameGame(matchName)
            error = client.error
          if online:
            let info = layout.left + vec2(22, layout.panelHeight - 72)
            sk.lobbyLabel(snapshot.name, info, 600,
              tint = LobbyMuted)
            if sk.lobbyButton("Copy invite", layout.footer + vec2(204, 0),
              200, "link", not modal):
                copyInvite(inviteBase() & "?server=" & encodeUrl(preferences.server) &
                  "&room=" & encodeUrl(snapshot.room))
            if sk.lobbyButton(if selfReady: "Ready" else: "Not ready",
              layout.footer + vec2(420, 0), 190, "status",
              editable and ownCount > 0 and not roster.dirty and not roster.pending and not modal,
              iconTint = readinessColor(selfReady)):
                readyRefresh.toggleCosmeticReady()
            if roster.dirty and owner and editable:
              if sk.lobbyButton("Apply Settings", layout.primary,
                250, "settings", not modal and not roster.pending):
                  discard parseConfig(config.toJson())
                  client.error = ""
                  client.send(RoomMessage(
                    kind: ConfigureRoom, name: snapshot.name,
                    number: uint32(config.playerCount), tickRate: uint32(TickRate),
                    flag: publicRoom, payload: config.toJson()
                  ))
                  roster.pendingPayload = config.toJson()
            elif owner:
              if sk.lobbyButton("Start Game", layout.primary,
                250, "arrow_right",
                owner and editable and not roster.pending and not modal,
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
                readyRefresh = ReadyRefresh()
                viewedRevision = 0
                viewedPayload = ""
                roster = RosterState()
                multiplayerHuman = -1
                networkPolicies = newSeq[LocalPolicy](config.playerCount)
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
              layout.left + vec2(22, layout.panelHeight - 74), 800, tint = LobbyMuted)
          let selectedSeat = lobbyUi.selectedSeat
          let choice =
            if modal and not contextBlocked and lobbyUi.selectedSeat >= 0:
              sk.seatPicker(window, lobbyUi, bots)
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
          if participantMenu.isOpen:
            sk.pushLayer(PopupsLayer)
            let
              view = window.size.vec2 / sk.uiScale
              panel = participantMenu.bounds(view)
              item = participantMenu.itemRect(view)
            discard sk.interact(rect(vec2(0), view), true)
            sk.lobbyPanel(panel.xy, panel.wh)
            discard sk.lobbyButton(participantMenu.label(client), item.xy,
              item.w, tint = LobbyRed)
            sk.lobbyLabel(participantMenu.warning(client), panel.xy + vec2(12, 60),
              panel.w - 24, tint = LobbyMuted)
            sk.popLayer()
        of SettingsMenu:
          let height = max(440.0'f,
            window.size.y.float32 / sk.uiScale - origin.y - 50)
          if sk.lvdSettingsPanel(
            window, preferences, AppName, origin, "", height
          ):
            page = HomeMenu
            preferences = effectivePreferences(preferences, inviteServer, serverAddress)
      except CatchableError as problem:
        error = problem.msg
      if page in {MultiplayerMenu, LobbyMenu, SettingsMenu} and
        not participantMenu.isOpen and not contextInputBlocked and
        lobbyUi.selectedSeat == -1 and
        sk.playerButton(window, preferences.name,
          page != LobbyMenu or connection.client.snapshot.phase == rooms.Lobby):
          playerName = preferences.name
          editingPlayer = true
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
      config.players.setLen(config.playerCount)
      var sources = newSeq[string](config.playerCount)
      for i, policy in localPolicies:
        if i == humanSeat:
          config.players[i].name = preferences.name
        else:
          sources[i] = policy.bytes
          config.players[i].name = policy.name
      try:
        config.playerSlot = int32(humanSeat + 1)
        initializeLocalMatch(config, sources)
        runGraphics()
        preferences = effectivePreferences(
          readLvdPreferences(), inviteServer, serverAddress
        )
      except CatchableError as problem:
        error = problem.msg
      page = HomeMenu
      run = nil
  window.onFrame = nil
  connection.close()
