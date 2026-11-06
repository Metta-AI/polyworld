## Actual binary RoomClients + authoritative Relay, with sparse human seats.
import std/strutils
import jsony
import polyworld/[rooms, roomclients, relays, mailboxes]
import ../[chats, bots, multiplayer, replays, sim]

block twoHumans:
  var relay = Relay()
  var now = 0.0
  let clients = [RoomClient(identity: gotaIdentity(), name: "mason :)"),
    RoomClient(identity: gotaIdentity(), name: "小明 (guest)"),
    RoomClient(identity: gotaIdentity(), name: "Watcher")]
  proc exchange() =
    for attempt in 0 ..< 30:
      var sent = false
      for i, client in clients:
        let outgoing = client.outgoing
        client.outgoing = @[]
        for bytes in outgoing:
          relay.process(i + 1, bytes, now)
          sent = true
      var outgoing: seq[Outgoing]
      swap(outgoing, relay.outgoing)
      for output in outgoing:
        if output.bytes.len > 0:
          clients[output.connection - 1].accept(output.bytes)
          sent = true
      if not sent: return
    doAssert false, "exchange did not settle"
  for client in clients: client.opened()
  exchange()
  clients[0].send(RoomMessage(kind: CreateRoom, name: "Human chat QA", number: 10,
    tickRate: 24, payload: parseConfig("{\"maxTicks\":48}").toJson()))
  exchange()
  for i in 1 .. 2:
    clients[i].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
    exchange()
  clients[0].claimHumanSeat(1)
  clients[1].claimHumanSeat(8)
  exchange()
  let sessions = [prepareNetworkMatch(clients[0], []), prepareNetworkMatch(clients[1], []),
    prepareNetworkMatch(clients[2], [])]
  for i in 0 .. 1:
    clients[i].send(RoomMessage(kind: Ready, revision: sessions[i].revision,
      hash: sessions[i].game.networkHash()))
  exchange()
  clients[0].send(RoomMessage(kind: StartMatch, revision: sessions[0].revision,
    hash: sessions[0].game.networkHash()))
  exchange()
  for i, session in sessions:
    doAssert clients[i].error.len == 0, clients[i].error
    session.start(clients[i].events[0])
    clients[i].events.setLen(0)
  exchange()
  doAssert sessions[0].sendHumanChat("你好 🙂 <b>A</b>")
  doAssert sessions[1].sendHumanChat("reply :)")
  doAssert not sessions[2].sendHumanChat("cannot speak as a bot")
  doAssert not sessions[0].sendHumanChat("   ")
  doAssert not sessions[0].sendHumanChat(repeat("🙂", 257))
  doAssert sessions[0].humanChat.len == 0, "No optimistic/unauthoritative display"
  exchange()
  proc step() =
    now += 1.0 / 24
    relay.advance(now)
    exchange()
    for i, session in sessions:
      while clients[i].packets.len > 0:
        let packet = clients[i].packets[0]
        clients[i].packets.delete(0)
        session.applyPacket(packet)
    exchange()
  for i in 0 ..< 3: step()
  for session in sessions:
    doAssert session.humanChat.len == 2
    doAssert session.humanChat[0].sender == "mason :)"
    doAssert session.humanChat[0].text == "你好 🙂 <b>A</b>"
    doAssert session.humanChat[1].sender == "小明 (guest)"
    doAssert session.humanChat[1].text == "reply :)"
    doAssert session.game.inboxes[0].count == 0, "Human text is not policy mailbox logs"
  doAssert sessions[0].game.sendChat(0, 1, "policy preserved") == 1
  sessions[0].flushSubmissions()
  doAssert sessions[0].sendHumanChat("team only", team = true)
  for i in 0 ..< 3: step()
  doAssert sessions[1].visibleHumanChat().len == 2, "Opponent must not display team chat"
  doAssert sessions[0].visibleHumanChat().len == 3
  doAssert sessions[0].game.stateHash() == sessions[1].game.stateHash()
  doAssert sessions[1].game.inboxes[1].count == 1
  doAssert sessions[1].game.inboxes[1].messages[0] == "policy preserved"
  # Chat never contaminates the action-only replay or deterministic world.
  doAssert sessions[0].game.recorder.data.actions.len == 0
  doAssert sessions[0].game.recorder.data.hashes == sessions[1].game.recorder.data.hashes
  for text in ["\xFF", "hello\nworld", repeat("🙂", 257), "   "]:
    var rejected = false
    try:
      discard decodeSubmission(GameSubmission(humanChat: true, text: text,
        action: ReplayAction(first: -2)).encodeSubmission())
    except RoomsError: rejected = true
    doAssert rejected, "Remote human text must be validated before mutation"
  # Relay rejects a controller claiming another human's stable seat.
  let payload = GameSubmission(humanChat: true, text: "forged", action:
    ReplayAction(heroId: sessions[0].game.world.heroes[1].id, first: -2)).encodeSubmission()
  clients[2].send(RoomMessage(kind: SubmitCommand, match: clients[2].match,
    seat: 8, sequence: 100, payload: payload))
  exchange()
  doAssert clients[2].error.len > 0
  clients[2].error = ""
  clients[0].send(RoomMessage(kind: SubmitCommand, match: clients[0].match,
    seat: 8, sequence: 100, payload: payload))
  exchange()
  doAssert clients[0].error.len > 0
  clients[0].error = ""
  # Opaque relay cannot inspect hero IDs; the game validates the entire packet.
  let before = sessions[0].game.world.tick
  var rejected = false
  try:
    sessions[0].applyPacket(RoomMessage(kind: TickPacket, match: clients[0].match,
      tick: uint32(before + 1), commands: @[Command(participant: clients[0].participant,
      seat: 1, sequence: 101, payload: payload)]))
  except RoomsError: rejected = true
  doAssert rejected and sessions[0].game.world.tick == before
  doAssert sessions[0].humanChat.len == 3
  # Game category cannot let even an owned bot speak as a human.
  let humanName = clients[0].snapshot.seats[1].name
  clients[0].snapshot.seats[1].name = "private bot"
  doAssert not sessions[0].sendHumanChat("bot impersonation")
  clients[0].snapshot.seats[1].name = humanName
  echo "Two-human relay chat: exact names/text, team filtering, policy isolation, ownership passed"
