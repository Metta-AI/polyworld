## Native regression: real RoomClient and Relay, with in-memory transport only.
## Run from the repository root; no listener, browser, or private policy is used.
import
  std/[strutils, unittest],
  jsony,
  polyworld/[rooms, relays, roomclients],
  ../[content, multiplayer, presets, sim]

type NameFixture = ref object
  relay: Relay
  clients: seq[RoomClient]
  sent, received: seq[RoomMessage]

proc newFixture(): NameFixture =
  NameFixture(relay: Relay())

proc exchange(fixture: NameFixture) =
  ## Deliver actual encoded outboxes in both directions, including auto replies.
  for iteration in 0 ..< 32:
    var moved = false
    for i, client in fixture.clients:
      if not client.connected:
        continue
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        # Malformed names must reach Relay.process's real failure path; packet
        # tracing must not reject an oversized envelope before the relay sees it.
        try:
          fixture.sent.add decode(bytes)
        except RoomsError:
          discard
        fixture.relay.process(i + 1, bytes, 0.0)
        moved = true
    let outgoing = fixture.relay.outgoing
    fixture.relay.outgoing = @[]
    for delivery in outgoing:
      let client = fixture.clients[delivery.connection - 1]
      if client.connected:
        if delivery.bytes.len > 0:
          fixture.received.add decode(delivery.bytes)
          client.accept(delivery.bytes)
          moved = true
        if delivery.close:
          client.lost()
    if not moved:
      return
  doAssert false, "Name fixture transport did not settle"

proc connect(fixture: NameFixture, name: string): RoomClient =
  result = RoomClient(identity: gotaIdentity(), name: name)
  fixture.clients.add result
  result.opened()
  fixture.exchange()

proc createRoom(fixture: NameFixture, owner: RoomClient) =
  owner.send(RoomMessage(
    kind: CreateRoom, name: "Names: (exact) \"room\"", number: HeroClassCount,
    tickRate: uint32(TickRate), flag: true,
    payload: parseConfig("{\"maxTicks\":24,\"draftMode\":\"open\"}").toJson()
  ))
  fixture.exchange()

proc namedParticipant(snapshot: RoomMessage, id: uint32): Participant =
  for participant in snapshot.participants:
    if participant.id == id:
      return participant
  doAssert false, "Named participant missing from authoritative snapshot"

proc containsKind(messages: seq[RoomMessage], kind: MessageKind): bool =
  for message in messages:
    if message.kind == kind:
      return true

suite "GotA exact multiplayer player names":
  test "printable names round-trip without trimming, escaping, or tokenization":
    for name in ["mason :)", "  spaced name  ", "'single' \"double\": (ok)",
        "Zoë 雪 🙂: (hi)", repeat("x", 64), repeat("é", 32)]:
      checkpoint "exact name: " & name
      check name.validName
      let hello = RoomMessage(kind: Hello, identity: gotaIdentity(), name: name)
      check decode(hello.encode()).name == name
      let claim = RoomMessage(kind: ClaimSeat, seat: 2, name: name)
      check decode(claim.encode()).name == name
      let snapshot = RoomMessage(kind: RoomState,
        participants: @[Participant(id: 1, name: name, connected: true)],
        seats: @[Seat(owner: 1, name: name)])
      let decoded = decode(snapshot.encode())
      check decoded.participants[0].name == name
      check decoded.seats[0].name == name

  test "Hello Welcome JoinRoom ClaimSeat Ready and prepared configs keep exact names":
    let fixture = newFixture()
    let names = @["mason :)", "  spaced name  ", "'single' \"double\": (ok)",
      "Zoë 雪 🙂: (hi)", repeat("x", 64), repeat("é", 32)]
    for name in names:
      let client = fixture.connect(name)
      require client.welcomed
      check client.connected
      check client.participant != 0
      check client.token.len > 0
      check client.name == name
      check client.error.len == 0
    let owner = fixture.clients[0]
    fixture.createRoom(owner)
    require owner.snapshot.room.len > 0
    check owner.snapshot.namedParticipant(owner.participant).name == "mason :)"
    for i in 1 ..< fixture.clients.len:
      fixture.clients[i].send(RoomMessage(kind: JoinRoom, room: owner.snapshot.room))
      fixture.exchange()
      for observer in fixture.clients:
        if observer.snapshot.room.len > 0:
          for joined in 0 .. i:
            check observer.snapshot.namedParticipant(
              fixture.clients[joined].participant).name == names[joined]
    for i, client in fixture.clients:
      client.claimHumanSeat(i)
    # Fill every remaining seat: this regression does not depend on sparse-start
    # behavior or the readiness refresh API being changed by another writer.
    let botNames = @["Bot :) with spaces", "Bot \"quoted\": (one)",
      "Böt 雪: (two)", "  bot with outer spaces  "]
    for i, name in botNames:
      owner.send(RoomMessage(kind: ClaimSeat,
        seat: uint32(names.len + i), name: name))
    fixture.exchange()
    var sessions: seq[NetworkMatch]
    for client in fixture.clients:
      require client.error.len == 0
      for i, name in names:
        check client.snapshot.namedParticipant(fixture.clients[i].participant).name == name
        check client.snapshot.seats[i].name == "Human"
        check client.snapshot.seats[i].owner == fixture.clients[i].participant
      for i, name in botNames:
        check client.snapshot.seats[names.len + i].name == name
      let session = prepareNetworkMatch(client, [])
      for i, name in names:
        check session.game.config.players[i].name == name
      for i, name in botNames:
        check session.game.config.players[names.len + i].name == name
      let reparsed = parseConfig(session.game.config.toJson())
      for i, name in names:
        check reparsed.players[i].name == name
      sessions.add session
    for session in sessions:
      check session.game.networkHash() == sessions[0].game.networkHash()
      session.client.send(RoomMessage(kind: Ready,
        revision: session.revision, hash: session.game.networkHash()))
    fixture.exchange()
    for observer in fixture.clients:
      require observer.error.len == 0
      for i, name in names:
        let participant = observer.snapshot.namedParticipant(fixture.clients[i].participant)
        check participant.name == name
        check participant.ready
    owner.send(RoomMessage(kind: StartMatch, revision: sessions[0].revision,
      hash: sessions[0].game.networkHash()))
    fixture.exchange()
    for session in sessions:
      require session.client.error.len == 0
      require session.client.events.len == 1
      check session.client.events[0].kind == BeginMatch
      session.start(session.client.events[0])
      check session.started
      for i, name in names:
        check session.game.config.players[i].name == name
        check session.client.snapshot.namedParticipant(fixture.clients[i].participant).name == name
    fixture.exchange()
    for client in fixture.clients:
      check client.error.len == 0
    for kind in [Hello, JoinRoom, ClaimSeat, Ready, StartMatch]:
      check fixture.sent.containsKind(kind)
    for kind in [Welcome, RoomState, BeginMatch]:
      check fixture.received.containsKind(kind)

  test "relay rejects empty whitespace control and over-64-byte Hello names":
    var invalid = @["", " ", "   ", repeat("x", 65), repeat("é", 33)]
    for value in 0 .. 31:
      invalid.add "before" & $char(value) & "after"
    invalid.add "before\x7fafter"
    for name in invalid:
      checkpoint "rejected Hello bytes: " & $name.len
      if name.len <= 64:
        check not name.validName
      let fixture = newFixture()
      let client = fixture.connect(name)
      check not client.welcomed
      check not client.connected
      check client.participant == 0
      check client.error.len > 0
      check not fixture.received.containsKind(Welcome)
      check fixture.received.containsKind(Failure)

  test "relay rejects invalid ClaimSeat labels without changing the seat":
    let fixture = newFixture()
    let owner = fixture.connect("mason :)")
    require owner.welcomed
    fixture.createRoom(owner)
    owner.send(RoomMessage(kind: ClaimSeat, seat: 0, name: "Original: (safe)"))
    fixture.exchange()
    require owner.error.len == 0
    let original = owner.snapshot.seats[0]
    var invalid = @["", "  ", repeat("x", 97), repeat("é", 49)]
    for value in 0 .. 31:
      invalid.add "before" & $char(value) & "after"
    invalid.add "before\x7fafter"
    for name in invalid:
      checkpoint "rejected ClaimSeat bytes: " & $name.len
      owner.error = ""
      owner.send(RoomMessage(kind: ClaimSeat, seat: 0, name: name))
      fixture.exchange()
      check owner.error.len > 0
      check owner.snapshot.seats[0] == original
      check fixture.relay.rooms[0].seats[0] == original
    # 96 bytes is the established seat-label codec boundary, not Hello's 64.
    owner.error = ""
    owner.send(RoomMessage(kind: ClaimSeat, seat: 0, name: repeat("é", 48)))
    fixture.exchange()
    check owner.error.len == 0
    check owner.snapshot.seats[0].name == repeat("é", 48)
