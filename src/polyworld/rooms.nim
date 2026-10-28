import std/[strutils]

const
  RoomProtocolVersion* = 3'u32
  RoomHeaderBytes* = 64
  MaxWireBytes* = 256 * 1024
  MaxPayloadBytes* = 64 * 1024
  MaxCommandBytes* = 4096
  MaxSeats* = 64
  MaxParticipants* = 64
  MaxCommandsPerTick* = 1024

type
  RoomsError* = object of CatchableError
  RoomPhase* = enum
    Lobby, Playing, Waiting, Ended, Desynced
  MessageKind* = enum
    Hello, Welcome, ListRooms, RoomList, CreateRoom, JoinRoom, RoomState,
    ConfigureRoom, ClaimSeat, ReleaseSeat, Ready, StartMatch, BeginMatch,
    SubmitCommand, CommandAck, TickPacket, AppliedTick, Catchup, CaughtUp,
    ReportHash, MatchStatus, LeaveRoom, KickParticipant, ReturnLobby,
    FinishMatch, Received, Keepalive, Failure, AbortMatch, PauseMatch
  GameIdentity* = object
    game*: string
    gameplay*, protocol*: uint32
  Participant* = object
    id*: uint32
    name*: string
    connected*, ready*: bool
  Seat* = object
    owner*: uint32
    name*: string
  Command* = object
    participant*, seat*: uint32
    sequence*: uint64
    payload*: string
  RoomListing* = object
    id*, name*: string
    phase*: RoomPhase
    occupied*, seats*: uint32
  PacketTiming* = object
    server*, echo*, received*, measuredAt*: uint64
    rtt*, jitter*: uint32
  RoomMessage* = object
    timing*: PacketTiming
    kind*: MessageKind
    delivery*: uint64
    identity*: GameIdentity
    room*, name*, token*, payload*, detail*: string
    participant*, seat*, revision*, match*, tick*, number*, tickRate*: uint32
    sequence*, hash*: uint64
    flag*: bool
    phase*: RoomPhase
    participants*: seq[Participant]
    seats*: seq[Seat]
    rooms*: seq[RoomListing]
    commands*: seq[Command]
  PacketReader* = object
    data*: string
    cursor*: int

proc reject*(message: string) {.noreturn, raises: [RoomsError].} =
  ## Raises a protocol error without relying on release-mode assertions.
  raise newException(RoomsError, message)

proc put32*(bytes: var string, value: uint32) =
  ## Writes an unsigned integer in little endian order.
  for shift in [0, 8, 16, 24]:
    bytes.add char((value shr shift) and 255)

proc put64*(bytes: var string, value: uint64) =
  ## Writes a wide unsigned integer in little endian order.
  bytes.put32(uint32(value and 0xffffffff'u64))
  bytes.put32(uint32(value shr 32))

proc putString*(bytes: var string, value: string) =
  ## Writes a length-prefixed byte string.
  bytes.put32(uint32(value.len))
  bytes.add value

proc get32*(reader: var PacketReader): uint32 =
  ## Reads a bounded unsigned integer.
  if reader.cursor > reader.data.len - 4:
    reject("Truncated packet")
  for shift in [0, 8, 16, 24]:
    result = result or (uint32(reader.data[reader.cursor]) shl shift)
    inc reader.cursor

proc get64*(reader: var PacketReader): uint64 =
  ## Reads a wide unsigned integer.
  let low = reader.get32()
  result = uint64(low) or (uint64(reader.get32()) shl 32)

proc getString*(reader: var PacketReader, limit: int): string =
  ## Reads bytes only after checking the declared length.
  let size = reader.get32()
  if size > uint32(limit) or uint64(size) >
    uint64(reader.data.len - reader.cursor):
      reject("Invalid string length")
  result = reader.data[reader.cursor ..< reader.cursor + int(size)]
  reader.cursor += int(size)

proc count(reader: var PacketReader, limit: int): int =
  ## Validates a collection count before allocation.
  let size = reader.get32()
  if size > uint32(limit):
    reject("Collection limit exceeded")
  int(size)

proc putIdentity(bytes: var string, identity: GameIdentity) =
  ## Writes the exact game compatibility tuple.
  bytes.putString(identity.game)
  bytes.put32(identity.gameplay)
  bytes.put32(identity.protocol)

proc getIdentity(reader: var PacketReader): GameIdentity =
  ## Reads a bounded compatibility tuple.
  result.game = reader.getString(96)
  result.gameplay = reader.get32()
  result.protocol = reader.get32()

proc putCommand*(bytes: var string, command: Command) =
  ## Writes an opaque game command and its authoritative ownership.
  bytes.put32(command.participant)
  bytes.put32(command.seat)
  bytes.put64(command.sequence)
  bytes.putString(command.payload)

proc getCommand(reader: var PacketReader): Command =
  ## Reads a command without interpreting game data.
  result.participant = reader.get32()
  result.seat = reader.get32()
  result.sequence = reader.get64()
  result.payload = reader.getString(MaxCommandBytes)

proc encode*(message: RoomMessage): string =
  ## Encodes the versioned binary switchboard envelope.
  result = "PWRM"
  result.put32(RoomProtocolVersion)
  result.put32(uint32(message.kind))
  result.put64(message.delivery)
  result.put32(message.match)
  result.put64(message.timing.server)
  result.put64(message.timing.echo)
  result.put64(message.timing.received)
  result.put64(message.timing.measuredAt)
  result.put32(message.timing.rtt)
  result.put32(message.timing.jitter)
  case message.kind
  of Hello:
    result.putIdentity(message.identity)
    result.putString(message.name)
    result.putString(message.token)
  of Welcome:
    result.put32(message.participant)
    result.putString(message.token)
  of CreateRoom, ConfigureRoom:
    result.putString(message.name)
    result.put32(uint32(message.flag))
    result.put32(message.tickRate)
    result.put32(message.number)
    result.putString(message.payload)
  of JoinRoom:
    result.putString(message.room)
  of RoomList:
    result.put32(uint32(message.rooms.len))
    for room in message.rooms:
      result.putString(room.id)
      result.putString(room.name)
      result.put32(uint32(room.phase))
      result.put32(room.occupied)
      result.put32(room.seats)
  of RoomState:
    result.putString(message.room)
    result.putString(message.name)
    result.put32(message.participant)
    result.put32(message.revision)
    result.put32(uint32(message.phase))
    result.put32(message.tickRate)
    result.put32(uint32(message.flag))
    result.putString(message.payload)
    result.put32(uint32(message.participants.len))
    for participant in message.participants:
      result.put32(participant.id)
      result.putString(participant.name)
      result.put32(uint32(participant.connected))
      result.put32(uint32(participant.ready))
    result.put32(uint32(message.seats.len))
    for seat in message.seats:
      result.put32(seat.owner)
      result.putString(seat.name)
  of ClaimSeat:
    result.put32(message.seat)
    result.putString(message.name)
  of ReleaseSeat:
    result.put32(message.seat)
  of Ready:
    result.put32(message.revision)
    result.put64(message.hash)
  of BeginMatch:
    result.put32(message.revision)
    result.put64(message.hash)
  of SubmitCommand:
    result.put32(message.seat)
    result.put64(message.sequence)
    result.putString(message.payload)
  of CommandAck:
    result.put64(message.sequence)
    result.put32(message.tick)
  of TickPacket:
    result.put32(message.tick)
    result.put32(uint32(message.commands.len))
    for command in message.commands:
      result.putCommand(command)
  of AppliedTick, Catchup:
    result.put32(message.tick)
  of CaughtUp:
    result.put32(message.tick)
    result.put32(message.number)
  of ReportHash, FinishMatch:
    result.put32(message.tick)
    result.put64(message.hash)
  of PauseMatch:
    result.put32(uint32(message.flag))
  of MatchStatus:
    result.put32(uint32(message.flag))
    result.put32(uint32(message.phase))
    result.put32(message.tick)
    result.putString(message.detail)
  of KickParticipant:
    result.put32(message.participant)
  of Received:
    result.put64(message.sequence)
  of Failure, AbortMatch:
    result.putString(message.detail)
  of ListRooms, StartMatch, LeaveRoom, ReturnLobby, Keepalive:
    discard
  if result.len > MaxWireBytes:
    reject("Packet exceeds wire limit")

proc readPhase(reader: var PacketReader): RoomPhase =
  ## Validates a room phase before converting it to an enum.
  let value = reader.get32()
  if value > uint32(RoomPhase.high):
    reject("Unknown room phase")
  RoomPhase(value)

proc decode*(bytes: string): RoomMessage =
  ## Rejects malformed envelopes before interpreting their payloads.
  if bytes.len > MaxWireBytes or bytes.len < RoomHeaderBytes or bytes[0 .. 3] != "PWRM":
    reject("Invalid switchboard packet")
  var reader = PacketReader(data: bytes, cursor: 4)
  if reader.get32() != RoomProtocolVersion:
    reject("Incompatible switchboard protocol version")
  let kind = reader.get32()
  if kind > uint32(MessageKind.high):
    reject("Unknown message kind")
  result.kind = MessageKind(kind)
  result.delivery = reader.get64()
  result.match = reader.get32()
  result.timing.server = reader.get64()
  result.timing.echo = reader.get64()
  result.timing.received = reader.get64()
  result.timing.measuredAt = reader.get64()
  result.timing.rtt = reader.get32()
  result.timing.jitter = reader.get32()
  case result.kind
  of Hello:
    result.identity = reader.getIdentity()
    result.name = reader.getString(64)
    result.token = reader.getString(64)
  of Welcome:
    result.participant = reader.get32()
    result.token = reader.getString(64)
  of CreateRoom, ConfigureRoom:
    result.name = reader.getString(96)
    let flag = reader.get32()
    if flag > 1:
      reject("Invalid visibility flag")
    result.flag = flag == 1
    result.tickRate = reader.get32()
    result.number = reader.get32()
    result.payload = reader.getString(MaxPayloadBytes)
  of JoinRoom:
    result.room = reader.getString(64)
  of RoomList:
    for i in 0 ..< reader.count(64):
      result.rooms.add RoomListing(
        id: reader.getString(64), name: reader.getString(96),
        phase: reader.readPhase(), occupied: reader.get32(),
        seats: reader.get32()
      )
  of RoomState:
    result.room = reader.getString(64)
    result.name = reader.getString(96)
    result.participant = reader.get32()
    result.revision = reader.get32()
    result.phase = reader.readPhase()
    result.tickRate = reader.get32()
    let paused = reader.get32()
    if paused > 1:
      reject("Invalid pause flag")
    result.flag = paused == 1
    result.payload = reader.getString(MaxPayloadBytes)
    for i in 0 ..< reader.count(MaxParticipants):
      var participant = Participant(id: reader.get32())
      participant.name = reader.getString(64)
      let
        connected = reader.get32()
        ready = reader.get32()
      if connected > 1 or ready > 1:
        reject("Invalid participant flags")
      participant.connected = connected == 1
      participant.ready = ready == 1
      result.participants.add participant
    for i in 0 ..< reader.count(MaxSeats):
      result.seats.add Seat(owner: reader.get32(), name: reader.getString(96))
  of ClaimSeat:
    result.seat = reader.get32()
    result.name = reader.getString(96)
  of ReleaseSeat:
    result.seat = reader.get32()
  of Ready:
    result.revision = reader.get32()
    result.hash = reader.get64()
  of BeginMatch:
    result.revision = reader.get32()
    result.hash = reader.get64()
  of SubmitCommand:
    result.seat = reader.get32()
    result.sequence = reader.get64()
    result.payload = reader.getString(MaxCommandBytes)
  of CommandAck:
    result.sequence = reader.get64()
    result.tick = reader.get32()
  of TickPacket:
    result.tick = reader.get32()
    for i in 0 ..< reader.count(MaxCommandsPerTick):
      result.commands.add reader.getCommand()
  of AppliedTick, Catchup:
    result.tick = reader.get32()
  of CaughtUp:
    result.tick = reader.get32()
    result.number = reader.get32()
  of ReportHash, FinishMatch:
    result.tick = reader.get32()
    result.hash = reader.get64()
  of PauseMatch:
    let paused = reader.get32()
    if paused > 1:
      reject("Invalid pause flag")
    result.flag = paused == 1
  of MatchStatus:
    let paused = reader.get32()
    if paused > 1:
      reject("Invalid pause flag")
    result.flag = paused == 1
    result.phase = reader.readPhase()
    result.tick = reader.get32()
    result.detail = reader.getString(4096)
  of KickParticipant:
    result.participant = reader.get32()
  of Received:
    result.sequence = reader.get64()
  of Failure, AbortMatch:
    result.detail = reader.getString(4096)
  of ListRooms, StartMatch, LeaveRoom, ReturnLobby, Keepalive:
    discard
  if reader.cursor != bytes.len:
    reject("Trailing packet bytes")

proc validName*(name: string): bool =
  ## Accepts printable guest and room names with nonempty visible content.
  if name.strip.len == 0:
    return false
  for letter in name:
    if letter < ' ' or letter == '\x7f':
      return false
  true
