import
  std/times,
  windy,
  rooms, roomclients

type Connection* = ref object
  client*: RoomClient
  address*: string
  socket: WebSocketHandle
  retryAt, heartbeatAt: float64
  opening, closed: bool

proc close*(connection: Connection) =
  ## Closes networking and releases callbacks before discarding a session.
  if connection == nil:
    return
  connection.closed = true
  connection.socket.onOpen = nil
  connection.socket.onMessage = nil
  connection.socket.onError = nil
  connection.socket.onClose = nil
  connection.socket.close()
  connection.client.lost()

proc open(connection: Connection) =
  ## Uses Windy's identical native and browser WebSocket interface.
  connection.socket.onOpen = nil
  connection.socket.onMessage = nil
  connection.socket.onError = nil
  connection.socket.onClose = nil
  connection.socket.close()
  connection.opening = true
  connection.socket = openWebSocket(connection.address)
  connection.socket.onOpen = proc() =
    ## Starts the identity handshake on this socket.
    connection.opening = false
    connection.client.opened()
  connection.socket.onMessage = proc(bytes: string, kind: WebSocketMessageKind) =
    ## Validates bytes on the application's event thread.
    try:
      if kind != windy.BinaryMessage:
        reject("The relay sent a nonbinary message")
      connection.client.accept(bytes)
    except RoomsError as error:
      connection.client.error = error.msg
      connection.close()
  connection.socket.onError = proc(message: string) =
    ## Reports failed connections while retaining reconnectable local state.
    connection.opening = false
    connection.client.lost()
    connection.client.status = message
    connection.retryAt = epochTime() + 2
  connection.socket.onClose = proc() =
    ## Schedules reconnect without replacing seats or bot runtimes.
    connection.opening = false
    connection.client.lost()
    connection.retryAt = epochTime() + 2

proc reconnectAfter*(connection: Connection, seconds: float64) =
  ## Interrupts transport for reconnect testing without discarding local state.
  connection.close()
  connection.closed = false
  connection.opening = false
  connection.retryAt = epochTime() + max(seconds, 0)

proc connect*(address, name: string, identity: GameIdentity): Connection =
  ## Creates a reusable game-independent connection.
  result = Connection(
    address: address, client: RoomClient(identity: identity, name: name)
  )
  result.open()

proc pump*(connection: Connection) =
  ## Flushes bounded traffic and reconnects while rendering remains responsive.
  if connection == nil or connection.closed:
    return
  let now = epochTime()
  if not connection.client.connected:
    if not connection.opening and now >= connection.retryAt:
      connection.open()
    return
  if now >= connection.heartbeatAt:
    connection.client.send(RoomMessage(kind: Keepalive))
    connection.heartbeatAt = now + 3
  for bytes in connection.client.outgoing:
    connection.socket.send(bytes, windy.BinaryMessage)
  connection.client.outgoing.setLen(0)
