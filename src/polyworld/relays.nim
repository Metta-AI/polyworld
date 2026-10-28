import
  std/[strutils, sysrand, times],
  rooms

const
  MaxRooms* = 64
  MaxGuests* = 512
  MaxHistoryBytes* = 128 * 1024 * 1024
  MaxTotalHistoryBytes* = 512 * 1024 * 1024
  MaxHistoryTicks* = 24 * 60 * 60 * 4
  MaxUnacknowledgedBytes* = 512 * 1024
  MaxInputBytesPerSecond* = 256 * 1024
  CatchupBatch* = 16
  MaxAheadTicks* = 6

type
  Delivery = object
    id, stamp: uint64
    bytes: int
  Checkpoint = object
    present: bool
    hash: uint64
    participant: uint32
  Receipt = object
    tick: uint32
    seat: uint32
    payload: string
  Guest* = ref object
    id*: uint32
    connection*: int
    identity*: GameIdentity
    name*, token*: string
    room*: string
    ready*, recovering*: bool
    readyHash: uint64
    applied*, hashTick*, finishTick: uint32
    hash, finishHash: uint64
    receipts: seq[Receipt]
    deliveries: seq[Delivery]
    delivered, received: uint64
    unacknowledged, inputBytes: int
    lastSeen, inputEpoch: float64
    timing: PacketTiming
  RelayRoom* = ref object
    id*, name*: string
    identity*: GameIdentity
    owner*: uint32
    public*, paused*: bool
    phase*: RoomPhase
    revision*, match*, tickRate*, tick*: uint32
    payload*: string
    seats*: seq[Seat]
    participants*: seq[uint32]
    pending*: seq[Command]
    history*: seq[string]
    historyBytes, pendingBytes: int
    initialHash: uint64
    checkpoints: seq[Checkpoint]
    finalTick: uint32
    finalHash: uint64
    deadline*: float64
    detail*, pausedBy: string
  Outgoing* = object
    connection*: int
    bytes*: string
    close*: bool
  Relay* = ref object
    logEvents*: bool
    guests*: seq[Guest]
    rooms*: seq[RelayRoom]
    outgoing*: seq[Outgoing]
    nextId: uint32
    now: float64

proc secret(): string =
  ## Creates an unguessable guest or invite token from operating-system entropy.
  var bytes: array[24, byte]
  if not urandom(bytes):
    reject("Cannot obtain reconnect token entropy")
  for value in bytes:
    result.add toHex(value, 2).toLowerAscii

proc guest*(relay: Relay, id: uint32): Guest =
  ## Looks up a stable participant identity.
  for candidate in relay.guests:
    if candidate.id == id:
      return candidate

proc connectionGuest(relay: Relay, connection: int): Guest =
  ## Finds the participant bound to one live connection.
  for candidate in relay.guests:
    if candidate.connection == connection:
      return candidate

proc room*(relay: Relay, id: string): RelayRoom =
  ## Finds a room without interpreting its game identity.
  for candidate in relay.rooms:
    if candidate.id == id:
      return candidate

proc controls(room: RelayRoom, id: uint32): bool =
  ## Reports whether a participant owns any seats in this room.
  for seat in room.seats:
    if seat.owner == id:
      return true

proc logEvent*(
    relay: Relay, event: string, connection = 0,
    room: RelayRoom = nil, detail = ""
) =
  ## Echoes lifecycle events without tokens, invite codes or game payloads.
  if not relay.logEvents:
    return
  var
    line = getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'") & " " & event
    activeRoom = room
  if connection > 0:
    line.add " connection=" & $connection
    let guest = relay.connectionGuest(connection)
    if guest != nil:
      line.add " player=" & $guest.id & " name=" & guest.name.escape &
        " game=" & guest.identity.game.escape &
        " gameplay=" & $guest.identity.gameplay &
        " protocol=" & $guest.identity.protocol
      if activeRoom == nil:
        activeRoom = relay.room(guest.room)
  if activeRoom != nil:
    line.add " room=" & activeRoom.name.escape &
      " owner=" & $activeRoom.owner & " match=" & $activeRoom.match &
      " tick=" & $activeRoom.tick
  if detail.len > 0:
    line.add " detail=" & detail.escape
  echo line

proc send(relay: Relay, guest: Guest, message: RoomMessage) =
  ## Bounds transport credit until the peer acknowledges receiving bytes.
  if guest == nil or guest.connection == 0:
    return
  var packet = message
  inc guest.delivered
  packet.delivery = guest.delivered
  packet.timing = guest.timing
  packet.timing.server = uint64(max(0.0, relay.now) * 1_000_000)
  let bytes = packet.encode()
  if guest.unacknowledged + bytes.len > MaxUnacknowledgedBytes:
    relay.logEvent("connection.backpressure", guest.connection,
      detail = "Unacknowledged outgoing byte limit exceeded")
    relay.outgoing.add Outgoing(connection: guest.connection, close: true)
    guest.connection = 0
    return
  guest.deliveries.add Delivery(id: packet.delivery, stamp: packet.timing.server,
    bytes: bytes.len)
  guest.unacknowledged += bytes.len
  relay.outgoing.add Outgoing(connection: guest.connection, bytes: bytes)

proc broadcast(relay: Relay, room: RelayRoom, message: RoomMessage) =
  ## Sends control state to connected room participants.
  for id in room.participants:
    relay.send(relay.guest(id), message)

proc state*(relay: Relay, room: RelayRoom): RoomMessage =
  ## Produces a lobby snapshot without exposing reconnect secrets.
  result = RoomMessage(
    kind: RoomState, room: room.id, name: room.name,
    participant: room.owner, revision: room.revision, phase: room.phase,
    match: room.match, tickRate: room.tickRate, payload: room.payload,
    flag: room.paused,
    seats: room.seats
  )
  for id in room.participants:
    let guest = relay.guest(id)
    result.participants.add Participant(
      id: id, name: guest.name, connected: guest.connection != 0,
      ready: guest.ready
    )

proc publish(relay: Relay, room: RelayRoom) =
  ## Publishes the current room snapshot.
  relay.broadcast(room, relay.state(room))

proc status(relay: Relay, room: RelayRoom) =
  ## Publishes the exact frozen or running server tick.
  relay.broadcast(room, RoomMessage(
    kind: MatchStatus, match: room.match, phase: room.phase,
    tick: room.tick, detail: room.detail, flag: room.paused
  ))

proc stop(relay: Relay, room: RelayRoom, detail: string) =
  ## Stops a match visibly without attempting desync repair.
  if room.phase == Desynced:
    return
  room.phase = Desynced
  room.detail = detail
  relay.logEvent("match.stopped", room = room, detail = detail)
  relay.status(room)

proc retainedBytes(relay: Relay): int =
  ## Counts bounded history and pending storage across all rooms.
  for room in relay.rooms:
    result += room.historyBytes + room.pendingBytes +
      room.checkpoints.len * sizeof(Checkpoint)

proc changed(relay: Relay, room: RelayRoom) =
  ## Invalidates all readiness after a roster or configuration change.
  inc room.revision
  for id in room.participants:
    relay.guest(id).ready = false
  relay.publish(room)

proc disconnect*(relay: Relay, connection: int) =
  ## Freezes active rooms when an owning client loses its connection.
  let guest = relay.connectionGuest(connection)
  if guest == nil:
    return
  relay.logEvent("player.disconnected", connection)
  guest.connection = 0
  guest.deliveries.setLen(0)
  guest.unacknowledged = 0
  let room = relay.room(guest.room)
  if room == nil:
    return
  if room.phase in {Playing, Waiting} and room.controls(guest.id):
    room.phase = Waiting
    room.detail = "Waiting for " & guest.name & " to reconnect"
    relay.status(room)
  elif room.phase == Lobby:
    guest.ready = false
  relay.publish(room)

proc hello(relay: Relay, connection: int, message: RoomMessage, now: float64) =
  ## Binds a new connection or restores an existing participant securely.
  if not message.name.validName or message.identity.game.len == 0 or
    message.identity.protocol == 0:
      reject("A game identity and display name are required")
  if relay.connectionGuest(connection) != nil:
    reject("Connection already identified")
  var guest: Guest
  if message.token.len > 0:
    for candidate in relay.guests:
      if candidate.token == message.token:
        guest = candidate
        break
    if guest == nil or guest.identity != message.identity:
      reject("Reconnect token is unknown or belongs to another game version")
    if guest.connection != 0:
      let oldConnection = guest.connection
      relay.outgoing.add Outgoing(connection: oldConnection, close: true)
      relay.disconnect(oldConnection)
  else:
    if relay.guests.len >= MaxGuests:
      reject("Server participant limit reached")
    inc relay.nextId
    guest = Guest(
      id: relay.nextId, token: secret(), name: message.name,
      identity: message.identity
    )
    relay.guests.add guest
  guest.connection = connection
  relay.logEvent(
    if message.token.len > 0: "player.reconnected" else: "player.identified",
    connection
  )
  guest.lastSeen = now
  guest.inputEpoch = now
  guest.inputBytes = 0
  guest.timing = PacketTiming()
  guest.delivered = 0
  guest.received = 0
  guest.deliveries.setLen(0)
  guest.unacknowledged = 0
  relay.send(guest, RoomMessage(
    kind: Welcome, participant: guest.id, token: guest.token
  ))
  let room = relay.room(guest.room)
  if room != nil:
    relay.publish(room)
    if room.phase != Lobby:
      guest.recovering = room.controls(guest.id)
      relay.send(guest, RoomMessage(
        kind: BeginMatch, match: room.match,
        revision: room.revision, hash: room.initialHash
      ))
      relay.send(guest, RoomMessage(
        kind: MatchStatus, match: room.match, phase: room.phase,
        tick: room.tick, detail: room.detail, flag: room.paused
      ))

proc acknowledge(guest: Guest, sequence: uint64) =
  ## Releases transport credit only for actually issued deliveries.
  if sequence < guest.received or sequence > guest.delivered:
    reject("Invalid delivery acknowledgement")
  guest.received = sequence
  var consumed = 0
  for delivery in guest.deliveries:
    if delivery.id > sequence:
      break
    guest.unacknowledged -= delivery.bytes
    inc consumed
  if consumed > 0:
    for i in consumed ..< guest.deliveries.len:
      guest.deliveries[i - consumed] = guest.deliveries[i]
    guest.deliveries.setLen(guest.deliveries.len - consumed)

proc catchup(relay: Relay, guest: Guest, room: RelayRoom, tick: uint32) =
  ## Streams bounded chunks of the immutable history to one client.
  if tick > room.tick:
    reject("Catch-up tick is ahead of the server")
  let last = min(room.tick, tick + CatchupBatch)
  for index in int(tick) ..< int(last):
    relay.send(guest, decode(room.history[index]))
  relay.send(guest, RoomMessage(
    kind: CaughtUp, match: room.match, tick: last, number: room.tick
  ))

proc removeGuest(relay: Relay, room: RelayRoom, guest: Guest) =
  ## Removes lobby membership and frees its seats without transferring bots.
  relay.logEvent("room.left", guest.connection, room,
    "player=" & $guest.id)
  guest.room = ""
  guest.receipts.setLen(0)
  if room.phase == Lobby:
    for seat in room.seats.mitems:
      if seat.owner == guest.id:
        seat = Seat()
  for i in 0 ..< room.participants.len:
    if room.participants[i] == guest.id:
      room.participants.delete(i)
      break
  if room.owner == guest.id and room.participants.len > 0:
    room.owner = room.participants[0]
  relay.send(guest, RoomMessage(kind: RoomState))
  if room.phase == Lobby:
    relay.changed(room)
  else:
    relay.publish(room)

proc receive*(
    relay: Relay, connection: int, message: RoomMessage, now: float64
) =
  ## Handles one event in the sole owner thread of the relay state.
  relay.now = now
  if message.delivery != 0:
    reject("Clients cannot assign delivery identifiers")
  if message.kind == Hello:
    relay.hello(connection, message, now)
    return
  let guest = relay.connectionGuest(connection)
  if guest == nil:
    reject("Identify before sending room messages")
  guest.lastSeen = now
  if now - guest.inputEpoch >= 1:
    guest.inputEpoch = now
    guest.inputBytes = 0
  guest.inputBytes += message.encode.len
  if guest.inputBytes > MaxInputBytesPerSecond:
    reject("Incoming traffic limit exceeded")
  if message.timing.received > guest.received:
    var found = false
    for delivery in guest.deliveries:
      if delivery.id == message.timing.received:
        if delivery.stamp != message.timing.echo:
          reject("Timestamp echo does not match its delivery")
        let
          stamp = uint64(max(0.0, now) * 1_000_000)
          elapsed = stamp - min(stamp, delivery.stamp)
          rtt = uint32(min(elapsed, uint64(uint32.high)))
        guest.timing.jitter =
          if guest.timing.measuredAt == 0: 0'u32
          else: uint32(abs(int64(rtt) - int64(guest.timing.rtt)))
        guest.timing.rtt = rtt
        guest.timing.measuredAt = stamp
        found = true
        break
    if not found:
      reject("Unknown timestamp delivery")
    guest.acknowledge(message.timing.received)
  if message.kind == Received:
    if message.sequence > 0:
      guest.acknowledge(message.sequence)
    return
  if message.kind == Keepalive:
    relay.send(guest, RoomMessage(kind: Keepalive))
    return
  if message.kind == ListRooms:
    var reply = RoomMessage(kind: RoomList)
    for room in relay.rooms:
      if not room.public or room.identity != guest.identity:
        continue
      var occupied = 0'u32
      for seat in room.seats:
        if seat.owner != 0:
          inc occupied
      reply.rooms.add RoomListing(
        id: room.id, name: room.name, phase: room.phase,
        occupied: occupied, seats: uint32(room.seats.len)
      )
    relay.send(guest, reply)
    return
  if message.kind == CreateRoom:
    if guest.room.len > 0 or relay.rooms.len >= MaxRooms:
      reject("Leave the current room or free server room capacity first")
    if message.number notin 1'u32 .. uint32(MaxSeats) or
      message.tickRate notin 1'u32 .. 120'u32 or not message.name.validName:
        reject("Invalid room settings")
    let room = RelayRoom(
      id: secret(), name: message.name, identity: guest.identity,
      owner: guest.id, public: message.flag, phase: Lobby, revision: 1,
      tickRate: message.tickRate, payload: message.payload,
      seats: newSeq[Seat](int(message.number)), participants: @[guest.id]
    )
    guest.room = room.id
    relay.rooms.add room
    relay.logEvent("room.created", connection, room,
      "seats=" & $message.number & " tickRate=" & $message.tickRate &
      " public=" & $message.flag)
    relay.changed(room)
    return
  if message.kind == JoinRoom:
    if guest.room.len > 0:
      reject("Leave the current room first")
    let room = relay.room(message.room)
    if room == nil or room.identity != guest.identity:
      reject("Room not found or incompatible exact game/protocol version")
    if room.participants.len >= MaxParticipants:
      reject("Room participant limit reached")
    guest.room = room.id
    guest.ready = false
    room.participants.add guest.id
    relay.logEvent("room.joined", connection, room)
    if room.phase == Lobby:
      relay.changed(room)
    else:
      guest.applied = 0
      guest.hashTick = 0
      guest.hash = room.initialHash
      relay.publish(room)
      relay.send(guest, RoomMessage(
        kind: BeginMatch, match: room.match, revision: room.revision,
        hash: room.initialHash
      ))
      relay.send(guest, RoomMessage(
        kind: MatchStatus, match: room.match, phase: room.phase,
        tick: room.tick, detail: room.detail, flag: room.paused
      ))
    return
  let room = relay.room(guest.room)
  if room == nil:
    reject("Join a room first")
  if message.kind in {SubmitCommand, AppliedTick, Catchup, ReportHash,
      FinishMatch, AbortMatch, PauseMatch} and message.match != room.match:
    reject("Stale match identifier")
  case message.kind
  of ConfigureRoom:
    if guest.id != room.owner or room.phase != Lobby:
      reject("Only the lobby owner can change settings")
    if message.number != uint32(room.seats.len) or
      message.tickRate notin 1'u32 .. 120'u32 or not message.name.validName:
        reject("Invalid room settings")
    room.name = message.name
    room.payload = message.payload
    room.public = message.flag
    room.tickRate = message.tickRate
    relay.logEvent("room.configured", connection, room)
    relay.changed(room)
  of ClaimSeat, ReleaseSeat:
    if room.phase != Lobby or message.seat >= uint32(room.seats.len):
      reject("Seats can only change in the lobby")
    let owner = room.seats[message.seat].owner
    if owner != 0 and owner != guest.id:
      reject("Seat belongs to another participant")
    if message.kind == ClaimSeat:
      if not message.name.validName:
        reject("A seat display name is required")
      room.seats[message.seat] = Seat(owner: guest.id, name: message.name)
    else:
      room.seats[message.seat] = Seat()
    relay.changed(room)
  of Ready:
    if room.phase != Lobby or message.revision != room.revision:
      reject("Ready refers to outdated room settings")
    guest.ready = true
    guest.readyHash = message.hash
    relay.publish(room)
  of StartMatch:
    if room.phase != Lobby or room.owner != guest.id:
      reject("Only the owner can start a lobby")
    var
      first = true
      initialHash: uint64
    for seat in room.seats:
      if seat.owner == 0:
        reject("Every game seat must have an owner")
      let controller = relay.guest(seat.owner)
      if controller.connection == 0 or not controller.ready:
        reject("Every controlling client must load the setup and be ready")
      if first:
        initialHash = controller.readyHash
        first = false
      elif initialHash != controller.readyHash:
        relay.stop(room, "Initial state hash mismatch: " &
          $initialHash & " versus " & $controller.readyHash &
          " from " & controller.name)
        return
    room.initialHash = initialHash
    room.checkpoints = @[Checkpoint(present: true, hash: initialHash)]
    room.finalTick = 0
    room.history.setLen(0)
    room.pending.setLen(0)
    room.historyBytes = 0
    room.pendingBytes = 0
    room.tick = 0
    inc room.match
    for id in room.participants:
      let controller = relay.guest(id)
      controller.receipts.setLen(0)
      controller.applied = 0
      controller.hashTick = 0
      controller.hash = initialHash
      controller.finishTick = 0
    room.phase = Playing
    room.paused = false
    room.detail = ""
    room.deadline = now + 1.0 / float64(room.tickRate)
    relay.broadcast(room, RoomMessage(
      kind: BeginMatch, match: room.match,
      revision: room.revision, hash: initialHash
    ))
    relay.status(room)
    relay.logEvent("match.started", connection, room,
      "seats=" & $room.seats.len & " initialHash=" & $initialHash)
  of SubmitCommand:
    if room.phase notin {Playing, Waiting} or
      message.seat >= uint32(room.seats.len) or
      room.seats[message.seat].owner != guest.id:
        reject("Command seat is not owned by this participant")
    if message.sequence == 0 or
      message.sequence > uint64(guest.receipts.len) + 1:
        reject("Command sequence must be consecutive")
    if message.sequence <= uint64(guest.receipts.len):
      let receipt = guest.receipts[int(message.sequence - 1)]
      if receipt.seat != message.seat or receipt.payload != message.payload:
        reject("Retransmitted sequence has different contents")
      relay.send(guest, RoomMessage(
        kind: CommandAck, match: room.match,
        sequence: message.sequence, tick: receipt.tick
      ))
      return
    if room.pending.len >= MaxCommandsPerTick or
      room.pendingBytes + message.payload.len + 32 > MaxWireBytes div 2:
        relay.stop(room, "Pending command limit exhausted")
        return
    if room.historyBytes + room.pendingBytes + message.payload.len * 2 +
      64 > MaxHistoryBytes:
        relay.stop(room, "Match history limit exhausted")
        return
    if relay.retainedBytes() + message.payload.len * 2 + 64 >
      MaxTotalHistoryBytes:
        relay.stop(room, "Server history limit exhausted")
        return
    let tick = room.tick + 1
    guest.receipts.add Receipt(
      tick: tick, seat: message.seat, payload: message.payload
    )
    room.pending.add Command(
      participant: guest.id, seat: message.seat,
      sequence: message.sequence, payload: message.payload
    )
    room.pendingBytes += message.payload.len * 2 + 64
    # The next authoritative tick acknowledges new commands in its payload.
  of AppliedTick:
    if message.tick < guest.applied or message.tick > room.tick:
      reject("Invalid simulated tick acknowledgement")
    guest.applied = message.tick
    if message.tick == room.tick:
      guest.recovering = false
  of Catchup:
    relay.catchup(guest, room, message.tick)
  of ReportHash, FinishMatch:
    if room.phase == Lobby:
      reject("State hashes require an active or completed match")
    if message.tick > room.tick or message.tick < guest.hashTick:
      reject("Invalid state hash tick")
    if message.kind == ReportHash:
      if message.tick mod room.tickRate != 0:
        reject("State hash must refer to a second boundary")
      let index = int(message.tick div room.tickRate)
      if room.checkpoints.len <= index:
        room.checkpoints.setLen(index + 1)
      let checkpoint = room.checkpoints[index]
      if checkpoint.present and checkpoint.hash != message.hash:
        relay.stop(room, "Desync at tick " & $message.tick & ": " &
          $checkpoint.hash & " versus " & $message.hash &
          " from " & guest.name & " (participant " & $guest.id & ")")
        return
      room.checkpoints[index] = Checkpoint(
        present: true, hash: message.hash, participant: guest.id
      )
      guest.hashTick = message.tick
      guest.hash = message.hash
    else:
      if message.tick == 0:
        reject("A finished match must contain at least one tick")
      if room.finalTick != 0 and
        (room.finalTick != message.tick or room.finalHash != message.hash):
          relay.stop(room, "Final desync at tick " & $message.tick & ": " &
            $room.finalHash & " at tick " & $room.finalTick & " versus " &
            $message.hash & " from " & guest.name)
          return
      room.finalTick = message.tick
      room.finalHash = message.hash
      guest.finishTick = message.tick
      guest.finishHash = message.hash
  of LeaveRoom:
    if room.phase in {Playing, Waiting} and room.controls(guest.id):
      reject("A controlling participant must remain until the match ends")
    relay.removeGuest(room, guest)
  of KickParticipant:
    if room.phase != Lobby or guest.id != room.owner or
      message.participant == guest.id:
        reject("Only the owner can remove other lobby participants")
    let removed = relay.guest(message.participant)
    if removed == nil or removed.room != room.id:
      reject("Participant is not in this room")
    relay.removeGuest(room, removed)
  of PauseMatch:
    if room.phase notin {Playing, Waiting} or not room.controls(guest.id):
      reject("Only a controlling participant can pause an active match")
    if room.paused != message.flag:
      relay.logEvent(
        if message.flag: "match.paused" else: "match.resume-requested",
        connection, room
      )
    room.paused = message.flag
    room.pausedBy = guest.name
    room.phase = Waiting
    room.detail =
      if room.paused:
        "Match paused by " & guest.name & " at tick " & $room.tick
      else:
        "Checking controllers and hashes before resuming"
    room.deadline = now + 1.0 / float64(room.tickRate)
    relay.status(room)
  of AbortMatch:
    if room.controls(guest.id) and room.phase in {Playing, Waiting}:
      relay.stop(room, guest.name & ": " & message.detail)
  of ReturnLobby:
    if guest.id != room.owner or room.phase notin {Ended, Desynced}:
      reject("Only the owner can reopen a completed room")
    room.phase = Lobby
    relay.logEvent("room.reopened", connection, room)
    room.paused = false
    room.pausedBy = ""
    for seat in room.seats.mitems:
      if seat.owner notin room.participants:
        seat = Seat()
    room.pending.setLen(0)
    room.history.setLen(0)
    room.historyBytes = 0
    room.pendingBytes = 0
    room.checkpoints.setLen(0)
    for id in room.participants:
      relay.guest(id).receipts.setLen(0)
    relay.changed(room)
  else:
    reject("Message is not a client room operation")

proc advance*(relay: Relay, now: float64) =
  ## Emits immutable ticks only while controllers and hash barriers agree.
  relay.now = now
  for guest in relay.guests:
    if guest.connection != 0 and now - guest.lastSeen > 15:
      let connection = guest.connection
      relay.logEvent("connection.timeout", connection)
      relay.outgoing.add Outgoing(connection: connection, close: true)
      relay.disconnect(connection)
  for room in relay.rooms:
    if room.phase notin {Playing, Waiting}:
      continue
    var
      reason: string
      allFinished = true
      finishedTick: uint32
      finishedHash: uint64
      checkedHash: uint64
      hasHash = false
    let boundary = room.tick - room.tick mod room.tickRate
    for id in room.participants:
      if not room.controls(id):
        continue
      let guest = relay.guest(id)
      if guest.connection == 0:
        reason = "Waiting for " & guest.name & " to reconnect"
      elif guest.recovering:
        reason = "Waiting for " & guest.name & " to catch up"
      elif guest.applied + MaxAheadTicks < room.tick:
        reason = "Waiting for " & guest.name & " at tick " & $guest.applied
      if guest.hashTick < boundary:
        reason = "Waiting for state hash at tick " & $boundary
      elif boundary > 0:
        if hasHash and checkedHash != guest.hash:
          relay.stop(room, "Desync at tick " & $boundary & ": " &
            $checkedHash & " versus " & $guest.hash & " from " & guest.name)
          break
        checkedHash = guest.hash
        hasHash = true
      if guest.finishTick == 0:
        allFinished = false
      elif finishedTick == 0:
        reason = "Waiting for final state confirmations"
        finishedTick = guest.finishTick
        finishedHash = guest.finishHash
      elif finishedTick != guest.finishTick or finishedHash != guest.finishHash:
        relay.stop(room, "Final state mismatch at tick " & $guest.finishTick)
        break
    if room.phase == Desynced:
      continue
    if allFinished:
      room.phase = Ended
      room.detail = "Match completed at tick " & $finishedTick
      relay.logEvent("match.ended", room = room,
        detail = "finalTick=" & $finishedTick & " finalHash=" & $finishedHash)
      relay.status(room)
      continue
    if reason.len == 0 and room.paused:
      reason = "Match paused by " & room.pausedBy & " at tick " & $room.tick
    if reason.len > 0:
      if room.phase != Waiting or room.detail != reason:
        room.phase = Waiting
        room.detail = reason
        relay.status(room)
      room.deadline = now + 1.0 / float64(room.tickRate)
      continue
    if room.phase == Waiting:
      room.phase = Playing
      room.detail = ""
      room.deadline = now + 1.0 / float64(room.tickRate)
      relay.status(room)
    if now < room.deadline:
      continue
    if room.history.len >= MaxHistoryTicks or
      room.historyBytes + room.pendingBytes + 64 > MaxHistoryBytes or
      relay.retainedBytes() + 64 > MaxTotalHistoryBytes:
        relay.stop(room, "Match history limit exhausted")
        continue
    inc room.tick
    let packet = RoomMessage(
      kind: TickPacket, match: room.match, tick: room.tick,
      commands: room.pending
    )
    let bytes = packet.encode()
    room.history.add bytes
    room.historyBytes += bytes.len + room.pendingBytes
    room.pending.setLen(0)
    room.pendingBytes = 0
    for id in room.participants:
      let guest = relay.guest(id)
      if room.controls(id) or guest.applied + CatchupBatch >= room.tick:
        relay.send(guest, packet)
    room.deadline = now + 1.0 / float64(room.tickRate)
  for i in countdown(relay.rooms.high, 0):
    if relay.rooms[i].participants.len == 0:
      relay.logEvent("room.closed", room = relay.rooms[i])
      relay.rooms.delete(i)
  for i in countdown(relay.guests.high, 0):
    let guest = relay.guests[i]
    if guest.room.len == 0 and guest.connection == 0 and
      now - guest.lastSeen > 60:
        relay.guests.delete(i)

proc process*(relay: Relay, connection: int, bytes: string, now: float64) =
  ## Reports invalid input to its sender while preserving the server loop.
  try:
    relay.receive(connection, decode(bytes), now)
  except RoomsError as error:
    relay.logEvent("request.rejected", connection, detail = error.msg)
    let guest = relay.connectionGuest(connection)
    if guest != nil:
      relay.send(guest, RoomMessage(kind: Failure, detail: error.msg))
    else:
      relay.outgoing.add Outgoing(
        connection: connection,
        bytes: RoomMessage(kind: Failure, detail: error.msg).encode(),
        close: true
      )
