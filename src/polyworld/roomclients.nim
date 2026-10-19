import rooms

const
  MaxClientCommands* = 4096
  MaxBufferedTicks* = 128

type
  PendingCommand = object
    message: RoomMessage
    sent: bool
  RoomClient* = ref object
    identity*: GameIdentity
    name*, token*, error*, status*: string
    participant*, match*, applied*, serverTick*: uint32
    connected*, welcomed*, catchupPending*, began*: bool
    snapshot*: RoomMessage
    listings*: seq[RoomListing]
    packets*: seq[RoomMessage]
    outgoing*: seq[string]
    events*: seq[RoomMessage]
    pending: seq[PendingCommand]
    sequence: uint64
    received: uint64
    lastHash, finalHash: RoomMessage

proc send*(client: RoomClient, message: RoomMessage) =
  ## Adds a bounded control operation to the transport outbox.
  if message.kind == ReportHash:
    client.lastHash = message
  elif message.kind == FinishMatch:
    client.finalHash = message
  if client.outgoing.len >= 1024:
    reject("Client outgoing queue exhausted")
  client.outgoing.add message.encode()

proc opened*(client: RoomClient) =
  ## Identifies this connection without persisting the private reconnect token.
  client.connected = true
  client.welcomed = false
  client.received = 0
  client.outgoing.setLen(0)
  client.send(RoomMessage(
    kind: Hello, identity: client.identity, name: client.name, token: client.token
  ))

proc lost*(client: RoomClient) =
  ## Retains simulation, local VMs and unacknowledged submissions in memory.
  client.connected = false
  client.welcomed = false
  client.catchupPending = false
  client.status = "Disconnected. Reconnecting with the same seats."
  client.outgoing.setLen(0)
  for pending in client.pending.mitems:
    pending.sent = false

proc requestHistory*(client: RoomClient) =
  ## Requests a bounded history batch starting after the applied tick.
  if not client.welcomed or not client.began or client.catchupPending:
    return
  client.send(RoomMessage(
    kind: Catchup, match: client.match, tick: client.applied
  ))
  client.catchupPending = true

proc flushCommands*(client: RoomClient) =
  ## Retransmits commands using their original participant sequence numbers.
  if not client.welcomed:
    return
  for pending in client.pending.mitems:
    if not pending.sent:
      client.send(pending.message)
      pending.sent = true

proc submit*(client: RoomClient, seat: uint32, payload: string): bool =
  ## Reports queue acceptance only, never gameplay success.
  if not client.began or payload.len > MaxCommandBytes or
    client.pending.len >= MaxClientCommands or
    seat >= uint32(client.snapshot.seats.len) or
    client.snapshot.seats[seat].owner != client.participant or
    client.snapshot.phase in {Ended, Desynced}:
      return false
  inc client.sequence
  client.pending.add PendingCommand(message: RoomMessage(
    kind: SubmitCommand, match: client.match,
    seat: seat, sequence: client.sequence, payload: payload
  ))
  client.flushCommands()
  true

proc accept*(client: RoomClient, bytes: string) =
  ## Validates relay messages and preserves packets until their exact tick runs.
  let message = decode(bytes)
  if message.delivery > 0:
    if message.delivery != client.received + 1:
      reject("Relay delivery sequence is not consecutive")
    client.received = message.delivery
    client.send(RoomMessage(kind: Received, sequence: message.delivery))
  case message.kind
  of Welcome:
    if client.participant != 0 and client.participant != message.participant:
      reject("Reconnect changed participant identity")
    client.participant = message.participant
    client.token = message.token
    client.welcomed = true
    client.status = "Connected"
    client.flushCommands()
    if client.began:
      if client.lastHash.kind == ReportHash:
        client.send(client.lastHash)
      if client.finalHash.kind == FinishMatch:
        client.send(client.finalHash)
    client.send(RoomMessage(kind: ListRooms))
  of RoomList:
    client.listings = message.rooms
  of RoomState:
    client.snapshot = message
    if message.phase == Lobby or message.room.len == 0:
      client.began = false
      client.match = 0
      client.applied = 0
      client.serverTick = 0
      client.sequence = 0
      client.pending.setLen(0)
      client.packets.setLen(0)
      client.catchupPending = false
      client.lastHash = RoomMessage()
      client.finalHash = RoomMessage()
  of BeginMatch:
    if client.began and client.match == message.match:
      client.requestHistory()
    else:
      client.match = message.match
      client.began = true
      client.applied = 0
      client.serverTick = 0
      client.sequence = 0
      client.packets.setLen(0)
      client.pending.setLen(0)
      client.events.add message
      client.requestHistory()
  of TickPacket:
    if message.match != client.match or message.tick == 0:
      reject("Tick packet belongs to an unexpected match")
    client.serverTick = max(client.serverTick, message.tick)
    if message.tick <= client.applied:
      return
    for packet in client.packets:
      if packet.tick == message.tick:
        var original = packet
        var repeated = message
        original.delivery = 0
        repeated.delivery = 0
        if original != repeated:
          reject("Immutable tick packet changed")
        return
    if client.packets.len >= MaxBufferedTicks:
      reject("Client tick buffer exhausted")
    client.packets.add message
  of CommandAck:
    if message.match != client.match or message.sequence > client.sequence:
      reject("Unknown command acknowledgement")
    for i in 0 ..< client.pending.len:
      if client.pending[i].message.sequence == message.sequence:
        client.pending.delete(i)
        break
  of CaughtUp:
    if message.match != client.match:
      reject("Catch-up belongs to another match")
    client.catchupPending = false
    client.serverTick = max(client.serverTick, message.number)
    if client.applied == message.number:
      client.send(RoomMessage(
        kind: AppliedTick, match: client.match, tick: client.applied
      ))
  of MatchStatus:
    if message.match != client.match:
      reject("Status belongs to another match")
    client.snapshot.phase = message.phase
    client.snapshot.flag = message.flag
    client.serverTick = max(client.serverTick, message.tick)
    client.status = message.detail
    if message.phase == Desynced:
      client.error = message.detail
  of Failure:
    client.error = message.detail
  of Keepalive:
    discard
  else:
    reject("Unexpected server message")

proc takeTick*(client: RoomClient, packet: var RoomMessage): bool =
  ## Returns only the next authoritative tick, without advancing the cursor.
  if client.snapshot.phase == Desynced:
    return false
  for i in 0 ..< client.packets.len:
    if client.packets[i].tick == client.applied + 1:
      packet = client.packets[i]
      client.packets.delete(i)
      return true
  if client.serverTick > client.applied:
    client.requestHistory()

proc appliedTick*(client: RoomClient, tick: uint32) =
  ## Acknowledges a tick only after the game simulation executed it.
  if tick != client.applied + 1:
    reject("Simulation tick did not advance exactly once")
  client.applied = tick
  if client.welcomed:
    client.send(RoomMessage(kind: AppliedTick, match: client.match, tick: tick))
  if client.packets.len == 0 and client.serverTick > client.applied:
    client.requestHistory()
