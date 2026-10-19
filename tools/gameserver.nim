import
  std/[monotimes, os, strutils],
  mummy,
  polyworld/[relays, rooms]

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

proc serve(server: Server) {.thread.} =
  ## Runs Mummy's socket pump independently of the room scheduler.
  let
    port = parseInt(getEnv("PORT", "8090"))
    address = getEnv("BIND", "127.0.0.1")
  echo "Polyworld gameserver ws://" & address & ":" & $port & "/ws"
  server.serve(Port(port), address)

inbox.open(1024)
var
  server = newServer(
    request, websocket, workerThreads = 2,
    maxBodyLen = 0, maxMessageLen = MaxWireBytes
  )
  thread: Thread[Server]
  relay = Relay()
  connections: seq[Connection]
  nextConnection = 0
createThread(thread, serve, server)
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
        input.socket.close()
      else:
        inc nextConnection
        connections.add Connection(id: nextConnection, socket: input.socket)
    of MessageEvent:
      if index >= 0:
        if input.binary:
          relay.process(connections[index].id, input.bytes, now)
        else:
          input.socket.send(
            RoomMessage(kind: Failure, detail: "Binary packets required").encode,
            BinaryMessage
          )
          input.socket.close()
    of ErrorEvent, CloseEvent:
      if index >= 0:
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
