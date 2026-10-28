import
  std/[monotimes, os],
  mummy,
  polyworld/[cli, relays, rooms]

const MaxConnections = 256

type
  Input = object
    socket: WebSocket
    event: WebSocketEvent
    bytes: string
    binary: bool
  Connection = object
    id: int
    socket: WebSocket

var inbox: Channel[Input]

proc serverPort(): Port =
  ## Reads the port override before opening sockets or starting threads.
  var value = getEnv("PORT", "8090")
  let arguments = commandLineParams()
  var index = 0
  while index < arguments.len:
    case arguments[index]
    of "--port":
      value = arguments.argumentValue(index, "--port")
    of "--help", "-h":
      echo "Usage: gameserver [--port NUMBER]"
      echo "Port defaults to PORT or 8090; BIND defaults to 127.0.0.1."
      quit(0)
    else:
      fail("unknown argument: " & arguments[index])
    inc index
  let port = parsePositiveInt32(value, "port")
  if port > 65535:
    fail("port must be between 1 and 65535")
  Port(port)

proc request(request: Request) {.gcsafe.} =
  ## Exposes health checks and the binary WebSocket endpoint.
  if request.path == "/healthz":
    request.respond(200, body = "Polyworld gameserver\n")
  elif request.path == "/ws":
    discard request.upgradeToWebSocket()
  else:
    request.respond(404, body = "Use /ws for Polyworld WebSocket rooms.\n")

proc websocket(
    socket: WebSocket, event: WebSocketEvent, message: Message
) {.gcsafe.} =
  ## Transfers bounded transport events to the single room owner thread.
  if event == MessageEvent and message.kind in {Ping, Pong}:
    return
  if not inbox.trySend(Input(
    socket: socket, event: event, bytes: message.data,
    binary: message.kind == BinaryMessage
  )):
    socket.close()

proc serve(config: tuple[server: Server, port: Port]) {.thread.} =
  ## Runs Mummy's socket pump independently of the room scheduler.
  let address = getEnv("BIND", "127.0.0.1")
  echo "Polyworld gameserver ws://" & address & ":" & $uint16(config.port) & "/ws"
  config.server.serve(config.port, address)

let port = serverPort()
inbox.open(1024)
var
  server = newServer(
    request, websocket, workerThreads = 2,
    maxBodyLen = 0, maxMessageLen = MaxWireBytes
  )
  thread: Thread[tuple[server: Server, port: Port]]
  relay = Relay(logEvents: true)
  connections: seq[Connection]
  nextConnection = 0
createThread(thread, serve, (server, port))
while true:
  let now = float64(getMonoTime().ticks) / 1_000_000_000.0
  for i in 0 ..< 1024:
    let event = inbox.tryRecv()
    if not event.dataAvailable:
      break
    let input = event.msg
    var index = -1
    for i in 0 ..< connections.len:
      if connections[i].socket == input.socket:
        index = i
        break
    case input.event
    of OpenEvent:
      if connections.len >= MaxConnections:
        relay.logEvent("connection.rejected", detail = "Connection limit reached")
        input.socket.close()
      else:
        inc nextConnection
        connections.add Connection(id: nextConnection, socket: input.socket)
        relay.logEvent("connection.opened", nextConnection)
    of MessageEvent:
      if index >= 0:
        if input.binary:
          relay.process(connections[index].id, input.bytes, now)
        else:
          relay.logEvent("request.rejected", connections[index].id,
            detail = "Binary packets required")
          input.socket.send(
            RoomMessage(kind: Failure, detail: "Binary packets required").encode,
            BinaryMessage
          )
          input.socket.close()
    of ErrorEvent, CloseEvent:
      if index >= 0:
        relay.logEvent(
          if input.event == ErrorEvent: "connection.error"
          else: "connection.closed",
          connections[index].id
        )
        relay.disconnect(connections[index].id)
        connections.delete(index)
  relay.advance(now)
  for output in relay.outgoing:
    for connection in connections:
      if connection.id == output.connection:
        if output.bytes.len > 0:
          connection.socket.send(output.bytes, BinaryMessage)
        if output.close:
          connection.socket.close()
        break
  relay.outgoing.setLen(0)
  sleep(2)
