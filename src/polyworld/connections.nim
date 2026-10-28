import
  std/[monotimes, random],
  windy,
  rooms, roomclients, networks

type Connection* = ref object
  client*: RoomClient
  address*: string
  socket: WebSocketHandle
  retryAt, heartbeatAt, receiptAt: float64
  stats*: NetworkStats
  playback*: TickPlayback
  incoming, outgoing: PacketQueue
  rng: Rand
  opening, closed: bool

proc networkTime*(): float64 =
  ## Reads a local monotonic clock for scheduling, never server comparisons.
  float64(getMonoTime().ticks) / 1_000_000_000

proc close*(connection: Connection) =
  ## Closes networking and releases callbacks before discarding a session.
  if connection == nil:
    return
  connection.closed = true
  connection.stats.active = false
  connection.playback = TickPlayback()
  connection.incoming.clear()
  connection.outgoing.clear()
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
  connection.playback = TickPlayback()
  connection.incoming.clear()
  connection.outgoing.clear()
  connection.opening = true
  connection.socket = openWebSocket(connection.address)
  connection.socket.onOpen = proc() =
    ## Starts the identity handshake on this socket.
    connection.opening = false
    connection.client.opened()
    connection.stats.active = true
  connection.socket.onMessage = proc(bytes: string, kind: WebSocketMessageKind) =
    ## Validates bytes on the application's event thread.
    try:
      if kind != windy.BinaryMessage:
        reject("The relay sent a nonbinary message")
      connection.stats.receivedBytes += uint64(bytes.len)
      inc connection.stats.receivedPackets
      connection.incoming.enqueue(bytes, networkTime(),
        connection.stats.lagMs, connection.stats.jitterMs, connection.rng)
    except RoomsError as error:
      connection.client.error = error.msg
      connection.close()
  connection.socket.onError = proc(message: string) =
    ## Reports failed connections while retaining reconnectable local state.
    connection.opening = false
    connection.client.lost()
    connection.stats.active = false
    connection.incoming.clear()
    connection.outgoing.clear()
    connection.client.status = message
    connection.retryAt = networkTime() + 2
  connection.socket.onClose = proc() =
    ## Schedules reconnect without replacing seats or bot runtimes.
    connection.opening = false
    connection.client.lost()
    connection.stats.active = false
    connection.incoming.clear()
    connection.outgoing.clear()
    connection.retryAt = networkTime() + 2

proc reconnectAfter*(connection: Connection, seconds: float64) =
  ## Interrupts transport for reconnect testing without discarding local state.
  connection.close()
  connection.closed = false
  connection.opening = false
  connection.retryAt = networkTime() + max(seconds, 0)

proc connect*(address, name: string, identity: GameIdentity): Connection =
  ## Creates a reusable game-independent connection.
  result = Connection(
    address: address, client: RoomClient(identity: identity, name: name),
    stats: NetworkStats(smoothPlayback: true), rng: initRand(8128)
  )
  result.open()

proc pump*(connection: Connection) =
  ## Delivers ordered delayed packets while rendering remains responsive.
  if connection == nil:
    return
  let now = networkTime()
  connection.stats.sample(now)
  if connection.closed:
    return
  if not connection.client.connected:
    if not connection.opening and now >= connection.retryAt:
      connection.open()
    return
  try:
    var consumed = 0
    for packet in connection.incoming.packets:
      if packet.due > now:
        break
      connection.client.accept(packet.bytes)
      connection.stats.measure(connection.client.timing, now)
      inc consumed
    connection.incoming.consume(consumed)
    if connection.client.receiptPending and connection.receiptAt == 0:
      connection.receiptAt = now
    elif not connection.client.receiptPending:
      connection.receiptAt = 0
    # Allow next-tick input and applied-tick messages to carry the receipt.
    if connection.client.outgoing.len == 0:
      if connection.client.receiptPending and now - connection.receiptAt >= 0.1:
        connection.client.send(RoomMessage(kind: Received))
      elif now >= connection.heartbeatAt:
        connection.client.send(RoomMessage(kind: Keepalive))
    for bytes in connection.client.outgoing:
      connection.outgoing.enqueue(bytes, now,
        connection.stats.lagMs, connection.stats.jitterMs, connection.rng)
    connection.client.outgoing.setLen(0)
    consumed = 0
    for packet in connection.outgoing.packets:
      if packet.due > now:
        break
      connection.socket.send(packet.bytes, windy.BinaryMessage)
      connection.stats.sentBytes += uint64(packet.bytes.len)
      inc connection.stats.sentPackets
      connection.heartbeatAt = now + 3
      inc consumed
    connection.outgoing.consume(consumed)
  except RoomsError as error:
    connection.client.error = error.msg
    connection.close()

proc takeTick*(
  connection: Connection,
  packet: var RoomMessage,
  tickRate: int
): bool =
  ## Consumes authoritative ticks at a steady rate when smoothing is enabled.
  connection.playback.takeTick(
    connection.client,
    packet,
    networkTime(),
    tickRate,
    connection.stats.smoothPlayback
  )
