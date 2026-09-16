## AWM multiplayer server. Manages a shared game with human and bot seats,
## WebSocket connections for players and spectators, and HTTP asset serving.
import std/[asynchttpserver, asyncdispatch, httpcore, json, os,
  strutils, times, uri, sysrand]
import awmsessions, awmwebsocket

type
  SeatKind = enum HumanSeat, BotSeat

  SeatState = enum Disconnected, Connected, ClassSelected

  Seat = object
    kind: SeatKind
    state: SeatState
    token: string
    heroClass: HeroClass
    classFixed: bool
    ws: WebSocket

  MatchPhase = enum
    WaitingForPlayers, WaitingForClasses, Playing

  Match = ref object
    phase: MatchPhase
    seats: array[PlayerCount, Seat]
    game: GameState
    revision: int
    matchId: string
    cycle: int
    spectators: seq[WebSocket]
    playsThisTurn: int
    actionWaiter: Future[JsonNode]

  ServerOptions = object
    host, webDir: string
    port, stepMs, maxTurns: int
    seed: int64
    seatKinds: array[PlayerCount, SeatKind]
    classes: array[PlayerCount, HeroClass]
    classFixed: array[PlayerCount, bool]
    connectTimeout: int

proc generateToken(): string =
  var raw: array[24, byte]
  if not urandom(raw):
    raise newException(OSError, "Cannot generate random token")
  for b in raw:
    result.add "0123456789abcdefghijklmnopqrstuvwxyz"[b.int mod 36]

proc serverOptions(): ServerOptions =
  result = ServerOptions(host: "127.0.0.1", port: 8080, stepMs: 2500,
    maxTurns: 60, webDir: getAppDir() / "web", seed: DefaultSessionSeed,
    seatKinds: [HumanSeat, BotSeat],
    classes: [Archer, Mage], classFixed: [false, false],
    connectTimeout: 180)
  let args = commandLineParams()
  var index = 0
  while index < args.len:
    if args[index] in ["--help", "-h"]:
      echo "AWM browser server\n" &
        "  --host ADDRESS       Bind address (127.0.0.1)\n" &
        "  --port PORT          HTTP port (8080)\n" &
        "  --web-dir PATH       Built browser assets (web beside executable)\n" &
        "  --step-ms NUMBER     Milliseconds between bot actions (2500)\n" &
        "  --max-turns NUMBER   Restart after this many turns (60)\n" &
        "  --seed INTEGER       Match seed\n" &
        "  --player0 human|bot  Seat 0 type (human)\n" &
        "  --player1 human|bot  Seat 1 type (bot)\n" &
        "  --class CLASS        Seat 0 hero class\n" &
        "  --opponent CLASS     Seat 1 hero class\n" &
        "  --connect-timeout S  Seconds to wait for human players (180)"
      quit(0)
    let separator = args[index].find('=')
    let key = if separator >= 0: args[index][0 ..< separator] else: args[index]
    if key notin ["--host", "--port", "--web-dir", "--step-ms", "--max-turns",
        "--seed", "--class", "--opponent", "--player0", "--player1",
        "--connect-timeout"]:
      raise newException(ValueError, "Unknown server option: " & key)
    var value: string
    if separator >= 0:
      value = args[index][separator + 1 .. ^1]
    else:
      inc index
      if index >= args.len or args[index].startsWith("--"):
        raise newException(ValueError, "Missing value for " & key)
      value = args[index]
    if value.len == 0:
      raise newException(ValueError, "Missing value for " & key)
    case key
    of "--host": result.host = value
    of "--web-dir": result.webDir = absolutePath(value)
    of "--port":
      result.port = parseInt(value)
      if result.port notin 1 .. 65535:
        raise newException(ValueError, "--port must be between 1 and 65535")
    of "--step-ms":
      result.stepMs = parseInt(value)
      if result.stepMs < 1 or result.stepMs > 3_600_000:
        raise newException(ValueError,
          "--step-ms must be between 1 and 3600000")
    of "--max-turns":
      result.maxTurns = parseInt(value)
      if result.maxTurns < 1:
        raise newException(ValueError, "--max-turns must be positive")
    of "--seed":
      result.seed = parseBiggestInt(value).int64
    of "--player0":
      case value.toLowerAscii()
      of "human": result.seatKinds[0] = HumanSeat
      of "bot": result.seatKinds[0] = BotSeat
      else: raise newException(ValueError,
        "--player0 must be human or bot")
    of "--player1":
      case value.toLowerAscii()
      of "human": result.seatKinds[1] = HumanSeat
      of "bot": result.seatKinds[1] = BotSeat
      else: raise newException(ValueError,
        "--player1 must be human or bot")
    of "--class":
      result.classes[0] = parseHeroClass(value)
      result.classFixed[0] = true
    of "--opponent":
      result.classes[1] = parseHeroClass(value)
      result.classFixed[1] = true
    of "--connect-timeout":
      result.connectTimeout = parseInt(value)
      if result.connectTimeout < 1:
        raise newException(ValueError,
          "--connect-timeout must be positive")
    else: discard
    inc index
  result.webDir = absolutePath(result.webDir)
  if not fileExists(result.webDir / "awm.html"):
    raise newException(ValueError,
      "Missing " & result.webDir / "awm.html" &
        "; run tools/build_web.sh first")

proc contentType(path: string): string =
  case path.splitFile.ext.toLowerAscii()
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".json", ".map": "application/json"
  of ".wasm": "application/wasm"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".svg": "image/svg+xml"
  of ".ttf": "font/ttf"
  of ".woff2": "font/woff2"
  else: "application/octet-stream"

proc staticPath(root, urlPath: string): string =
  let decoded = decodeUrl(urlPath, decodePlus = false)
  if decoded.len == 0 or decoded[0] != '/' or
      '\0' in decoded or '\\' in decoded:
    return ""
  result = root
  for component in decoded.split('/'):
    if component.len == 0:
      continue
    if component in [".", ".."]:
      return ""
    result = result / component
    if symlinkExists(result):
      return ""
  if not fileExists(result):
    return ""

proc injectMode(html, mode: string, slot = -1, token = ""): string =
  var script = "<script>"
  script.add "Module.locateFile=function(p){return '/'+p;};"
  script.add "(Module[\"arguments\"]||(Module[\"arguments\"]=[])).push(\"--mode\",\"" & mode & "\");"
  if slot >= 0:
    script.add "Module[\"arguments\"].push(\"--slot\",\"" & $slot & "\");"
  if token.len > 0:
    script.add "Module[\"arguments\"].push(\"--token\",\"" & token & "\");"
  script.add "</script>\n  "
  let marker = "<script async type=\"text/javascript\" src=\"awm.js\"></script>"
  let absolute = "<script async type=\"text/javascript\" src=\"/awm.js\"></script>"
  if marker in html:
    html.replace(marker, script & absolute)
  else:
    html.replace("</body>", script & "</body>")

proc snapshotText(match: Match): string =
  $snapshotToJson(Snapshot(matchId: match.matchId,
    revision: match.revision, game: match.game))

proc observationJson(match: Match, slot: int): string =
  $(%*{"type": "observation", "slot": slot,
    "game": gameToJson(match.game),
    "revision": match.revision,
    "yourTurn": match.phase == Playing and
      match.game.currentPlayer == slot,
    "matchId": match.matchId})

proc waitingJson(message: string): string =
  $(%*{"type": "waiting", "message": message})

proc serve(options: ServerOptions) {.async.} =
  let gameHtml = readFile(options.webDir / "awm.html")
  let globalHtml = gameHtml.injectMode("global")

  var match = Match(phase: WaitingForPlayers,
    matchId: $getTime().toUnix & "-" & $getCurrentProcessId())
  for i in 0 ..< PlayerCount:
    match.seats[i] = Seat(kind: options.seatKinds[i],
      token: generateToken(), heroClass: options.classes[i],
      classFixed: options.classFixed[i])
    if options.seatKinds[i] == BotSeat:
      match.seats[i].state = ClassSelected
      if not options.classFixed[i]:
        match.seats[i].classFixed = true

  proc broadcastState() =
    for i in 0 ..< PlayerCount:
      let seat = match.seats[i]
      if seat.ws != nil and not seat.ws.closed:
        try:
          asyncCheck seat.ws.send(match.observationJson(i))
        except CatchableError:
          discard
    var alive: seq[WebSocket]
    for ws in match.spectators:
      if not ws.closed:
        try:
          asyncCheck ws.send(match.snapshotText())
          alive.add ws
        except CatchableError:
          discard
      else:
        discard
    match.spectators = alive

  proc broadcastWaiting(message: string) =
    let msg = waitingJson(message)
    for i in 0 ..< PlayerCount:
      let seat = match.seats[i]
      if seat.ws != nil and not seat.ws.closed:
        try:
          asyncCheck seat.ws.send(msg)
        except CatchableError:
          discard
    for ws in match.spectators:
      if not ws.closed:
        try:
          asyncCheck ws.send(msg)
        except CatchableError:
          discard

  proc allReady(): bool =
    for seat in match.seats:
      if seat.state != ClassSelected:
        return false
    true

  proc anyHumanDisconnected(): bool =
    for seat in match.seats:
      if seat.kind == HumanSeat and seat.state == Disconnected:
        return true
    false

  proc startGame() =
    match.game = newGame(match.seats[0].heroClass,
      match.seats[1].heroClass, options.seed xor match.cycle.int64)
    match.phase = Playing
    match.revision = 0
    match.playsThisTurn = 0
    broadcastState()

  proc checkTransition() =
    if match.phase == WaitingForPlayers:
      if not anyHumanDisconnected():
        var needsSelection = false
        for seat in match.seats:
          if seat.state == Connected:
            needsSelection = true
        if needsSelection:
          match.phase = WaitingForClasses
          let msg = waitingJson("Waiting for class selections...")
          for ws in match.spectators:
            if not ws.closed:
              try:
                asyncCheck ws.send(msg)
              except CatchableError:
                discard
        elif allReady():
          startGame()
    if match.phase == WaitingForClasses:
      if allReady():
        startGame()

  proc submitAction(action: JsonNode) =
    if match.actionWaiter != nil and not match.actionWaiter.finished:
      match.actionWaiter.complete(action)
      match.actionWaiter = nil

  proc waitForAction(): Future[JsonNode] =
    let future = newFuture[JsonNode]("waitForAction")
    match.actionWaiter = future
    future

  proc restartMatch() =
    inc match.cycle
    match.matchId = $getTime().toUnix & "-" & $getCurrentProcessId() &
      "-" & $match.cycle
    match.game = newGame(match.seats[0].heroClass,
      match.seats[1].heroClass,
      options.seed xor match.cycle.int64)
    match.revision = 0
    match.playsThisTurn = 0
    broadcastState()

  proc gameLoop() {.async.} =
    while match.phase != Playing:
      await sleepAsync(100)
    while true:
      let current = match.game.currentPlayer
      let seat = match.seats[current]
      if seat.kind == BotSeat:
        await sleepAsync(options.stepMs)
        discard match.game.takeVisualEvents()
        let action = nextBotAction(match.game, match.playsThisTurn)
        if not match.game.applyBotAction(action):
          break
        if action.kind == EndTurnAction:
          match.playsThisTurn = 0
        else:
          inc match.playsThisTurn
        inc match.revision
        broadcastState()
      else:
        if seat.ws == nil or seat.ws.closed:
          await sleepAsync(200)
          continue
        let action = await waitForAction()
        try:
          let actionType = action.getOrDefault("type").getStr()
          discard match.game.takeVisualEvents()
          case actionType
          of "playCard":
            let handIndex = action["handIndex"].getInt()
            # "choices" answers each of the card's targets in order;
            # "choice" is the one-target form.
            var choices: seq[Choice]
            if action.hasKey("choices") and action["choices"].kind == JArray:
              for entry in action["choices"]:
                choices.add choiceFromJson(entry)
            elif action.hasKey("choice"):
              choices.add choiceFromJson(action["choice"])
            else:
              choices.add Canceled
            if match.game.playCard(handIndex, choices):
              inc match.playsThisTurn
              inc match.revision
              broadcastState()
          of "endTurn":
            match.game.finishTurn()
            match.playsThisTurn = 0
            inc match.revision
            broadcastState()
          else: discard
        except CatchableError:
          discard
      if match.game.turnNumber >= options.maxTurns:
        restartMatch()

  asyncCheck gameLoop()

  proc connectTimeout() {.async.} =
    await sleepAsync(options.connectTimeout * 1000)
    if match.phase in {WaitingForPlayers, WaitingForClasses}:
      for i in 0 ..< PlayerCount:
        if match.seats[i].state != ClassSelected:
          match.seats[i].state = ClassSelected
      if not allReady():
        return
      startGame()

  asyncCheck connectTimeout()

  proc handlePlayerWs(request: Request) {.async.} =
    var slot = -1
    var token = ""
    for param in request.url.query.split('&'):
      let kv = param.split('=', 1)
      if kv.len == 2:
        case kv[0]
        of "slot":
          try: slot = parseInt(kv[1])
          except ValueError: discard
        of "token": token = decodeUrl(kv[1])
    if slot < 0 or slot >= PlayerCount or
        token != match.seats[slot].token:
      let headers = newHttpHeaders({"Content-Type": "text/plain"})
      await request.respond(Http403, "Forbidden\n", headers)
      return
    if match.seats[slot].kind != HumanSeat:
      let headers = newHttpHeaders({"Content-Type": "text/plain"})
      await request.respond(Http403, "Seat is not open\n", headers)
      return
    if match.seats[slot].ws != nil and not match.seats[slot].ws.closed:
      match.seats[slot].ws.close()
    let ws = await upgradeWebSocket(request)
    match.seats[slot].ws = ws
    match.seats[slot].state = Connected
    if match.seats[slot].classFixed:
      match.seats[slot].state = ClassSelected
    else:
      await ws.send($(%*{"type": "selectClass"}))
    if match.phase == Playing:
      match.seats[slot].state = ClassSelected
      await ws.send(match.observationJson(slot))
    else:
      checkTransition()
      if match.phase == Playing:
        await ws.send(match.observationJson(slot))
      elif match.seats[slot].state == ClassSelected:
        await ws.send(waitingJson("Waiting for all players..."))
    try:
      while not ws.closed:
        let msg = await ws.recv()
        if msg.opcode == WsClose:
          break
        if msg.opcode != WsText:
          continue
        let data = parseJson(msg.data)
        case data.getOrDefault("type").getStr()
        of "selectClass":
          let className = data.getOrDefault("class").getStr()
          if className.len > 0:
            try:
              match.seats[slot].heroClass = parseHeroClass(className)
              match.seats[slot].state = ClassSelected
              checkTransition()
            except ValueError:
              discard
        of "playCard", "endTurn":
          if match.phase == Playing and
              match.game.currentPlayer == slot:
            submitAction(data)
        else: discard
    except CatchableError:
      discard
    match.seats[slot].ws = nil
    if match.phase in {WaitingForPlayers, WaitingForClasses}:
      match.seats[slot].state = Disconnected

  proc handleGlobalWs(request: Request) {.async.} =
    let ws = await upgradeWebSocket(request)
    match.spectators.add ws
    if match.phase == Playing:
      try:
        await ws.send(match.snapshotText())
      except CatchableError:
        discard
    else:
      try:
        await ws.send(waitingJson("Waiting for game to start..."))
      except CatchableError:
        discard
    try:
      while not ws.closed:
        let msg = await ws.recv()
        if msg.opcode == WsClose:
          break
    except CatchableError:
      discard
    ws.close()

  proc handle(request: Request) {.async, gcsafe.} =
    if request.headers.getOrDefault("Upgrade").toLowerAscii() == "websocket":
      case request.url.path
      of "/player":
        await handlePlayerWs(request)
      of "/global":
        await handleGlobalWs(request)
      else:
        let headers = newHttpHeaders({"Content-Type": "text/plain"})
        await request.respond(Http404, "Not found\n", headers)
      return

    var headers = newHttpHeaders({
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff"
    })

    proc respond(code: HttpCode, body: string,
        mime = "text/plain; charset=utf-8") {.async.} =
      headers["Content-Type"] = mime
      headers["Content-Length"] = $body.len
      await request.respond(code,
        if request.reqMethod == HttpHead: "" else: body, headers)

    if request.reqMethod notin {HttpGet, HttpHead}:
      headers["Allow"] = "GET, HEAD"
      await respond(Http405, "Method not allowed\n")
      return
    case request.url.path
    of "/healthz", "/api/health":
      await respond(Http200, "ok")
    of "/api/global":
      if match.phase == Playing:
        await respond(Http200, match.snapshotText(), "application/json")
      else:
        await respond(Http200, $(%*{"waiting": true}), "application/json")
    of "/", "/client/global":
      await respond(Http200, globalHtml, "text/html; charset=utf-8")
    of "/client/player":
      var slot = -1
      var token = ""
      for param in request.url.query.split('&'):
        let kv = param.split('=', 1)
        if kv.len == 2:
          case kv[0]
          of "slot":
            try: slot = parseInt(kv[1])
            except ValueError: discard
          of "token": token = decodeUrl(kv[1])
      if slot < 0 or slot >= PlayerCount or
          token != match.seats[slot].token:
        await respond(Http403, "Invalid seat or token\n")
        return
      let playerHtml = gameHtml.injectMode("player", slot, token)
      await respond(Http200, playerHtml, "text/html; charset=utf-8")
    else:
      try:
        let path = staticPath(options.webDir, request.url.path)
        if path.len == 0:
          await respond(Http404, "Not found\n")
        else:
          await respond(Http200, readFile(path), contentType(path))
      except IOError, OSError, ValueError:
        await respond(Http404, "Not found\n")

  let server = newAsyncHttpServer()
  server.listen(Port(options.port), options.host)
  let urlHost = if ':' in options.host: "[" & options.host & "]"
    else: options.host
  let baseUrl = "http://" & urlHost & ":" & $options.port
  echo "AWM server: " & baseUrl
  echo "Global spectator: " & baseUrl & "/client/global"
  for i in 0 ..< PlayerCount:
    if match.seats[i].kind == HumanSeat:
      echo "Player " & $(i + 1) & ": " & baseUrl &
        "/client/player?slot=" & $i & "&token=" & match.seats[i].token
    else:
      echo "Player " & $(i + 1) & ": bot (" &
        match.seats[i].heroClass.className() & ")"
  if allReady():
    startGame()
  else:
    checkTransition()
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handle)
    else:
      await sleepAsync(50)

when isMainModule:
  try:
    waitFor serve(serverOptions())
  except CatchableError as error:
    quit("AWM server: " & error.msg, 1)
