import std/[sets, strutils]
import polyworld/[rooms, relays]

proc send(relay: Relay, connection: int, message: RoomMessage) =
  ## Exercise the wire codec, including room IDs in both directions.
  relay.receive(connection, decode(message.encode()), 0)

proc connect(relay: Relay, connection: int, game = "galcon"): RoomMessage =
  relay.send(connection, RoomMessage(kind: Hello, name: "Guest " & $connection,
    identity: GameIdentity(game: game, gameplay: 7, protocol: 1)))
  result = decode(relay.outgoing[^1].bytes)
  doAssert result.kind == Welcome

proc create(relay: Relay, connection: int): RoomMessage =
  relay.send(connection, RoomMessage(kind: CreateRoom,
    room: "CLIENT", name: "Invite test", number: 2, tickRate: 24, flag: false))
  result = decode(relay.outgoing[^1].bytes)
  doAssert result.kind == RoomState

block:
  let relay = Relay()
  let host = relay.connect(1)
  let created = relay.create(1)
  doAssert created.room.len == 6, "Server room IDs must contain six characters"
  doAssert created.room.allCharsInSet({'A'..'Z', '0'..'9'})
  doAssert created.room == relay.rooms[0].id
  doAssert created.room == relay.guest(host.participant).room
  doAssert host.token.len == 48 # Existing 24-byte OS-random reconnect secret.
  doAssert host.token.allCharsInSet({'a'..'f', '0'..'9'})
  let guest = relay.connect(2)
  doAssert guest.token != host.token
  relay.send(2, RoomMessage(kind: JoinRoom, room: created.room))
  let joined = decode(relay.outgoing[^1].bytes)
  doAssert joined.kind == RoomState and joined.room == created.room
  doAssert joined.participants.len == 2
  relay.disconnect(1)
  relay.send(3, RoomMessage(kind: Hello, name: "Restored", token: host.token,
    identity: GameIdentity(game: "galcon", gameplay: 7, protocol: 1)))
  doAssert relay.guest(host.participant).connection == 3
  doAssert relay.guest(host.participant).token == host.token
  doAssert decode(relay.outgoing[^1].bytes).room == created.room

block:
  # Collisions must be checked globally, not only within a game's listings.
  let occupied = RelayRoom(id: "AAAAAA",
    identity: GameIdentity(game: "light_vs_dark", gameplay: 7, protocol: 1))
  let relay = Relay(rooms: @[occupied])
  var draws = 0
  proc entropy(bytes: var openArray[byte]): bool =
    inc draws
    for value in bytes.mitems:
      value = (if draws == 1: 0'u8 else: 1'u8)
    true
  doAssert relay.newRoomId(entropy) == "BBBBBB"
  doAssert draws == 2
  doAssert relay.rooms == @[occupied]

block:
  let relay = Relay(rooms: @[RelayRoom(id: "AAAAAA")])
  var draws = 0
  proc entropy(bytes: var openArray[byte]): bool =
    inc draws
    doAssert draws <= 32, "Room ID collision retries must be bounded"
    for value in bytes.mitems:
      value = 0
    true
  var rejected = false
  try:
    discard relay.newRoomId(entropy)
  except RoomsError:
    rejected = true
  doAssert rejected
  doAssert draws == 32
  doAssert relay.rooms.len == 1 and relay.rooms[0].id == "AAAAAA"

block:
  let relay = Relay()
  var draws = 0
  proc entropy(bytes: var openArray[byte]): bool =
    inc draws
    doAssert draws <= 32, "Rejection sampling must also be bounded"
    for value in bytes.mitems:
      value = 255
    true
  var rejected = false
  try:
    discard relay.newRoomId(entropy)
  except RoomsError:
    rejected = true
  doAssert rejected and draws == 32

block:
  # Every accepted byte maps through seven complete, equally sized buckets.
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  let relay = Relay()
  for raw in 0 ..< 252:
    proc entropy(bytes: var openArray[byte]): bool =
      for value in bytes.mitems:
        value = byte(raw)
      true
    doAssert relay.newRoomId(entropy) == repeat(alphabet[raw mod 36], 6)
  var draws = 0
  proc tailEntropy(bytes: var openArray[byte]): bool =
    inc draws
    let values = if draws == 1: [252'u8, 253, 254, 255, 35, 36]
                 else: [0'u8, 1, 2, 251, 0, 0]
    for index, value in bytes.mpairs:
      value = values[index]
    true
  doAssert relay.newRoomId(tailEntropy) == "9AABC9"
  doAssert draws == 2

block:
  let relay = Relay()
  proc noEntropy(bytes: var openArray[byte]): bool = false
  var rejected = false
  try:
    discard relay.newRoomId(noEntropy)
  except RoomsError as error:
    rejected = true
    doAssert error.msg == "Cannot obtain room code entropy"
  doAssert rejected and relay.rooms.len == 0

block:
  # Fill live shared-relay capacity repeatedly using all three actual game IDs.
  const games = ["galcon", "gods_of_the_arena", "light_vs_dark"]
  var creations = 0
  for batch in 0 ..< 16:
    let relay = Relay()
    var liveCodes = initHashSet[string]()
    for connection in 1 .. MaxRooms:
      discard relay.connect(connection, games[connection mod games.len])
      let created = relay.create(connection)
      doAssert created.room.len == 6
      doAssert created.room.allCharsInSet({'A'..'Z', '0'..'9'})
      doAssert created.room notin liveCodes
      liveCodes.incl created.room
      inc creations
    doAssert liveCodes.len == MaxRooms and relay.rooms.len == MaxRooms
  echo "Validated ", creations, " creations across three games"

block:
  # An existing long room identifier remains exact and wire-compatible.
  let relay = Relay()
  let host = relay.connect(1)
  discard relay.create(1)
  let legacy = repeat("0123456789abcdef", 4)
  relay.rooms[0].id = legacy
  relay.guest(host.participant).room = legacy
  discard relay.connect(2)
  relay.send(2, RoomMessage(kind: JoinRoom, room: legacy))
  let joined = decode(relay.outgoing[^1].bytes)
  doAssert joined.kind == RoomState and joined.room == legacy
  doAssert joined.participants.len == 2

block:
  let relay = Relay()
  discard relay.connect(1)
  discard relay.create(1)
  # Deliberately distinct from the client-supplied CreateRoom.room = CLIENT.
  relay.rooms[0].id = "ABC123"
  relay.guests[0].room = "ABC123"
  discard relay.connect(2)
  relay.send(2, RoomMessage(kind: JoinRoom, room: "abc123"))
  doAssert decode(relay.outgoing[^1].bytes).room == "ABC123"
  doAssert relay.guests[1].room == "ABC123"

block:
  # Unknown codes, legacy case, game identity and host permissions stay strict.
  let relay = Relay()
  let host = relay.connect(1)
  discard relay.create(1)
  let legacy = repeat("aBcD0123", 6)
  relay.rooms[0].id = legacy
  relay.guests[0].room = legacy
  discard relay.connect(2)
  for invalid in ["ZZZZZZ", legacy.toUpperAscii, " abc123", "abc12!"]:
    var rejected = false
    try:
      relay.send(2, RoomMessage(kind: JoinRoom, room: invalid))
    except RoomsError:
      rejected = true
    doAssert rejected and relay.guests[1].room == ""
  relay.send(2, RoomMessage(kind: JoinRoom, room: legacy))
  for operation in [
      RoomMessage(kind: ConfigureRoom, name: "Hijacked", number: 2, tickRate: 24),
      RoomMessage(kind: StartMatch),
      RoomMessage(kind: KickParticipant, participant: host.participant)]:
    var rejected = false
    try:
      relay.send(2, operation)
    except RoomsError:
      rejected = true
    doAssert rejected
  doAssert relay.rooms[0].owner == host.participant
  doAssert relay.rooms[0].name == "Invite test"
  discard relay.connect(3, "light_vs_dark")
  var rejected = false
  try:
    relay.send(3, RoomMessage(kind: JoinRoom, room: legacy))
  except RoomsError:
    rejected = true
  doAssert rejected and relay.guests[2].room == ""
  # A public invite can never be substituted for the private reconnect secret.
  rejected = false
  try:
    relay.send(4, RoomMessage(kind: Hello, name: "Impostor", token: legacy,
      identity: GameIdentity(game: "galcon", gameplay: 7, protocol: 1)))
  except RoomsError:
    rejected = true
  doAssert rejected and relay.guests.len == 3

block:
  # Exact old IDs win even if a case-folded six-character room also exists.
  let relay = Relay()
  discard relay.connect(1)
  discard relay.create(1)
  relay.rooms[0].id = "abc123"
  relay.guests[0].room = "abc123"
  relay.rooms.add RelayRoom(id: "ABC123")
  discard relay.connect(2)
  relay.send(2, RoomMessage(kind: JoinRoom, room: "abc123"))
  doAssert relay.guests[1].room == "abc123"

echo "Room codes: format, snapshots, joins, legacy IDs, reconnect, authorization, unbiased entropy and bounded collisions passed"
