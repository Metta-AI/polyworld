import std/[strutils, unittest]
import jsony, polyworld/[rooms, roomclients, relays]
import ../[lobbies, multiplayer, presets, content, lobbyreadiness]
let source = readFile("games/light_vs_dark/frontend.nim")
doAssert "roomName = defaultGameName(preferences.name)" in source
when declared(defaultGameName):
  for name in ["mason :)", "空 白 🙂", "quotes \"colon: (name)"]:
    doAssert defaultGameName(name) == name & "'s game"
    doAssert decode(RoomMessage(kind: CreateRoom, name: defaultGameName(name)).encode()).name == name & "'s game"
  var snapshot = RoomMessage(kind: RoomState, room: "room", phase: Lobby, participant: 1)
  doAssert snapshot.canEditGameName(1)
  doAssert not snapshot.canEditGameName(2)
  doAssert not snapshot.canEditGameName(0)
  snapshot.phase = Playing
  doAssert not snapshot.canEditGameName(1)
else:
  doAssert false, "Missing game-name helpers"
doAssert source.count("roomName = defaultGameName(preferences.name)") == 1
doAssert "gameName = if online: addr matchName else: nil" in source
doAssert "client.renameGame(matchName)" in source
doAssert "error = client.error" in source
doAssert "if online and owner and editable and not modal and not roster.pending and" in source
doAssert "window.buttonPressed[KeyEnter]" in source
doAssert "kind: ConfigureRoom, name: matchName" notin source
doAssert "if roomName == defaultGameName(preferences.name):" in source
doAssert "roomName = defaultGameName(updated.name)" in source
when declared(renameGame):
  let client = RoomClient(participant: 1, connected: true, welcomed: true,
    snapshot: RoomMessage(kind: RoomState, room: "room", phase: Lobby,
      participant: 1, name: "Old name"))
  client.snapshot.payload = "{\"untouched\": \"exact bytes\"}"
  client.snapshot.seats = newSeq[Seat](3)
  client.snapshot.tickRate = 23
  client.snapshot.flag = true
  doAssert client.renameGame("空 白 :)'s game")
  doAssert client.outgoing.len == 1
  let packet = decode(client.outgoing[0])
  doAssert packet.kind == ResizeRoom
  doAssert packet.name == "空 白 :)'s game"
  doAssert packet.payload == client.snapshot.payload
  doAssert packet.number == uint32(client.snapshot.seats.len)
  doAssert packet.tickRate == client.snapshot.tickRate
  doAssert packet.flag == client.snapshot.flag
  client.participant = 2
  doAssert not client.renameGame("Guest edit")
  client.participant = 1
  for invalid in ["", "   ", "line\nbreak", "tab\tname", "delete\x7f", "x".repeat(129), "白".repeat(43)]:
    client.error = ""
    doAssert not client.renameGame(invalid)
    doAssert client.error.len > 0, "Validation failure must be visible"
    doAssert client.outgoing.len == 1
  client.error = "previous failure"
  doAssert client.renameGame("Valid retry :)")
  doAssert client.error == ""
  client.outgoing = @[]
  doAssert not client.renameGame(client.snapshot.name)
  client.connected = false
  doAssert not client.renameGame("Disconnected")
  client.connected = true
  client.welcomed = false
  doAssert not client.renameGame("Not welcomed")
  client.welcomed = true
  client.snapshot.phase = Playing
  doAssert not client.renameGame("Already playing")
  doAssert client.outgoing.len == 0
  doAssert not renameGame(nil, "No client")
echo "LvD game-name defaults and owner route guards passed"

type NameFixture = ref object
  relay: Relay
  clients: seq[RoomClient]

proc exchange(f: NameFixture) =
  for iteration in 0 ..< 30:
    var sent = false
    for i, client in f.clients:
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        f.relay.process(i + 1, bytes, 0)
        sent = true
    let outgoing = f.relay.outgoing
    f.relay.outgoing = @[]
    for output in outgoing:
      if output.bytes.len > 0:
        f.clients[output.connection - 1].accept(output.bytes)
        sent = true
    if not sent: return
  doAssert false, "Relay exchange did not settle"

proc nameLobby(publicRoom: bool): NameFixture =
  result = NameFixture(relay: Relay())
  for name in ["mason :)", "空 白 \"colon: (name)"]:
    result.clients.add RoomClient(identity: lvdIdentity(), name: name)
    result.clients[^1].opened()
    result.exchange()
  var config = defaultConfig(2)
  config.maxTicks = 12
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  let host = result.clients[0]
  host.send(RoomMessage(kind: CreateRoom, name: "Original room", number: 2,
    tickRate: uint32(TickRate), flag: publicRoom, payload: config.toJson()))
  result.exchange()
  result.clients[1].send(RoomMessage(kind: JoinRoom, room: host.snapshot.room))
  result.exchange()
  host.claimHumanSeat(0)
  result.clients[1].claimHumanSeat(1)
  result.exchange()

suite "LvD name-only real relay operation":
  test "rename preserves every authoritative setting and public/private visibility":
    for publicRoom in [false, true]:
      let f = nameLobby(publicRoom)
      let host = f.clients[0]
      for name in ["mason :)'s game", "  空 白 🙂 \"quotes\": (room)  "]:
        let before = host.snapshot
        check host.renameGame(name)
        f.exchange()
        check host.error == ""
        check host.snapshot.name == name
        check f.clients[1].snapshot.name == name
        check host.snapshot.payload == before.payload
        check host.snapshot.tickRate == before.tickRate
        check host.snapshot.seats == before.seats
        check host.snapshot.revision == before.revision + 1
        check f.relay.rooms[0].public == publicRoom

  test "guest helper and forged relay packet cannot rename the owner's room":
    let f = nameLobby(false)
    let guest = f.clients[1]
    let before = guest.snapshot
    check not guest.renameGame("Guest edit")
    check guest.outgoing.len == 0
    guest.send(RoomMessage(kind: ResizeRoom, name: "Forged edit",
      number: uint32(before.seats.len), tickRate: before.tickRate,
      flag: before.flag, payload: before.payload))
    f.exchange()
    check guest.error.len > 0
    check guest.snapshot.name == before.name
    check guest.snapshot.revision == before.revision

  test "retained intent requires both controllers to refresh revision-bound hashes":
    let f = nameLobby(false)
    let host = f.clients[0]
    let guest = f.clients[1]
    var hostPrepared = prepareNetworkMatch(host, [])
    var guestPrepared = prepareNetworkMatch(guest, [])
    var hostRevision = hostPrepared.revision
    var guestRevision = guestPrepared.revision
    var hostRefresh, guestRefresh: ReadyRefresh
    for client in f.clients:
      client.send(RoomMessage(kind: Ready, revision: client.snapshot.revision,
        hash: hostPrepared.game.networkHash()))
    f.exchange()
    let oldRevision = hostRevision
    let oldHash = hostPrepared.game.networkHash()
    check host.renameGame("空 白 🙂 \"ready\": (retained)")
    f.exchange()
    check host.snapshot.revision > oldRevision
    check f.relay.guest(host.participant).ready
    check f.relay.guest(guest.participant).ready
    host.send(RoomMessage(kind: StartMatch))
    f.exchange()
    check host.error == ""
    check host.snapshot.phase == Lobby
    guest.send(RoomMessage(kind: Ready, revision: oldRevision, hash: oldHash))
    f.exchange()
    check guest.error.len > 0
    guest.error = ""
    check hostRefresh.refreshRetainedReady(host, [], hostPrepared, hostRevision)
    check hostRevision == host.snapshot.revision
    f.exchange()
    check host.error == ""
    check host.snapshot.phase == Lobby
    check guestRefresh.refreshRetainedReady(guest, [], guestPrepared, guestRevision)
    check guestRevision == guest.snapshot.revision
    check hostPrepared.game.networkHash() == guestPrepared.game.networkHash()
    f.exchange()
    check not hostRefresh.refreshRetainedReady(host, [], hostPrepared, hostRevision)
    check not guestRefresh.refreshRetainedReady(guest, [], guestPrepared, guestRevision)
    check host.error == ""
    check guest.error == ""
    check host.snapshot.phase == Playing
    check guest.snapshot.phase == Playing
    require host.events.len == 1
    require guest.events.len == 1
    hostPrepared.start(host.events[0])
    guestPrepared.start(guest.events[0])
    check hostPrepared.started and guestPrepared.started
