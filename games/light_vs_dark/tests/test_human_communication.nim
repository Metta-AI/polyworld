## Native, headless two-human binary relay chat acceptance.
import std/unicode
import jsony, polyworld/[rooms, roomclients, relays, mailboxes]
import ../[humancommunication, multiplayer, presets, sim, content]

var relay = Relay()
var now = 0.0
let clients = [RoomClient(identity: lvdIdentity(), name: "Alice 雪"),
  RoomClient(identity: lvdIdentity(), name: "Bob 🙂")]
proc exchange() =
  for attempt in 0 ..< 40:
    var sent = false
    for i, client in clients:
      var outgoing: seq[string]
      swap(outgoing, client.outgoing)
      for bytes in outgoing:
        relay.process(i + 1, bytes, now)
        sent = true
    var outgoing: seq[Outgoing]
    swap(outgoing, relay.outgoing)
    for output in outgoing:
      if output.bytes.len > 0:
        clients[output.connection - 1].accept(output.bytes)
        sent = true
    for client in clients: doAssert client.error.len == 0, client.error
    if not sent: return
  doAssert false, "Exchange did not settle"
for client in clients: client.opened()
exchange()
var config = defaultConfig(3)
config.maxTicks = 400
config.diplomacySettings.warGraceSeconds = 1
config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
clients[0].send(RoomMessage(kind: CreateRoom, name: "Human communication QA",
  number: 3, flag: false, tickRate: uint32(TickRate), payload: config.toJson()))
exchange()
clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
exchange()
for i, client in clients:
  client.claimHumanSeat(i)
  exchange()
clients[0].send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Bot"))
exchange()
let sessions = [prepareNetworkMatch(clients[0], ["", "", ""]),
  prepareNetworkMatch(clients[1], ["", "", ""])]
for i, session in sessions:
  clients[i].send(RoomMessage(kind: Ready, revision: session.revision,
    hash: session.game.networkHash()))
  exchange()
clients[0].send(RoomMessage(kind: StartMatch))
exchange()
for i, session in sessions:
  session.start(clients[i].events[0])
  clients[i].events.setLen(0)
exchange()
var ui: array[2, HumanCommunication]
proc advance(ticks = 1) =
  for n in 0 ..< ticks:
    exchange()
    now += 1.0 / float64(TickRate)
    relay.advance(now)
    exchange()
    for i, session in sessions:
      var packet: RoomMessage
      while session.client.takeTick(packet):
        session.applyPacket(packet)
        ui[i].observeHumanPacket(session, packet)
        ui[i].observeHumanPacket(session, packet) # repeated observer is idempotent
    exchange()
    doAssert sessions[0].game.stateHash() == sessions[1].game.stateHash()

block chatRoundTrip:
  let before = sessions[0].game.stateHash()
  doAssert ui[0].chatEnter(sessions[0].game, 0)
  for rune in "Hi 雪🙂".runes: doAssert ui[0].chatRune(rune)
  doAssert ui[0].chatEnter(sessions[0].game, 0)
  doAssert ui[0].feed.len == 0, "No optimistic delivery"
  doAssert sessions[0].game.stateHash() == before
  sessions[0].flushSubmissions()
  advance(3)
  for i in 0 .. 1:
    doAssert ui[i].feed.len == 1
    doAssert ui[i].feed[0].name == "Alice 雪"
    doAssert ui[i].feed[0].text == "Hi 雪🙂"
    doAssert sessions[i].game.inboxes[2].count == 1, "HUD consumed bot mailbox"
  doAssert ui[1].chatEnter(sessions[1].game, 1)
  for rune in "Hello Alice".runes: discard ui[1].chatRune(rune)
  discard ui[1].chatEnter(sessions[1].game, 1)
  sessions[1].flushSubmissions()
  advance(3)
  for i in 0 .. 1:
    doAssert ui[i].feed.len == 2
    doAssert ui[i].feed[1].name == "Bob 🙂"
    doAssert sessions[i].game.inboxes[2].count == 2
  echo "PASS named Unicode chat through real relay on both peers; bot inbox intact"

block editing:
  var editor: HumanCommunication
  discard editor.chatEnter(sessions[0].game, 0)
  for rune in "雪🙂".runes: discard editor.chatRune(rune)
  editor.chatBackspace()
  doAssert editor.draft == "雪"
  for i in 0 ..< MaxChatBytes: discard editor.chatRune(Rune(0x1f642))
  doAssert editor.draft.len <= MaxChatBytes
  doAssert validateUtf8(editor.draft) == -1
  let full = editor.draft
  discard editor.chatRune(Rune(10))
  doAssert editor.draft == full
  doAssert editor.cancelCommunication()
  doAssert editor.draft.len == 0 and not editor.typing
  doAssert editor.blocksGameplay(), "Escape remains consumed for the entire frame"
  editor.finishFrame()
  doAssert not editor.blocksGameplay()
  let count = sessions[0].game.chatSubmissions.len
  discard editor.chatEnter(sessions[0].game, 0)
  discard editor.chatEnter(sessions[0].game, 0)
  doAssert sessions[0].game.chatSubmissions.len == count
  discard editor.chatEnter(sessions[0].game, 0)
  discard editor.chatRune(Rune(0x3000)) # Unicode whitespace
  discard editor.chatEnter(sessions[0].game, 0)
  doAssert sessions[0].game.chatSubmissions.len == count
  editor.reset()
  doAssert not editor.blocksGameplay() and editor.feed.len == 0
  echo "PASS Unicode editing, bounded input, empty sends, cancellation and reset"

block diplomacyRoundTrip:
  let a = sessions[0].game
  let b = sessions[1].game
  doAssert a.world.atWar(0, 1)
  doAssert OfferPeace in a.diplomacyChoices(0, 1)
  doAssert OfferAlliance notin a.diplomacyChoices(0, 1)
  let before = a.stateHash()
  doAssert a.submitHumanDiplomacy(0, 1, OfferPeace)
  doAssert a.stateHash() == before
  sessions[0].flushSubmissions()
  advance(3)
  let offer = b.world.diplomacy.relation(1, 0).offerId
  doAssert AcceptOffer in b.diplomacyChoices(1, 0)
  doAssert AcceptOffer notin a.diplomacyChoices(0, 1)
  doAssert not b.submitHumanDiplomacy(1, 0, AcceptOffer, offer + 1)
  doAssert b.submitHumanDiplomacy(1, 0, AcceptOffer, offer)
  sessions[1].flushSubmissions()
  advance(3)
  doAssert not a.world.atWar(0, 1)
  doAssert a.world.diplomacy.relation(0, 1).state == Neutral
  advance(int(TickRate)) # Authoritative resend cooldown also covers alliance offers.
  doAssert a.submitHumanDiplomacy(0, 1, OfferAlliance)
  sessions[0].flushSubmissions()
  advance(3)
  doAssert b.submitHumanDiplomacy(1, 0, AcceptOffer,
    b.world.diplomacy.relation(1, 0).offerId)
  sessions[1].flushSubmissions()
  advance(3)
  for session in sessions:
    doAssert session.game.world.diplomacy.sharesVision(0, 1)
    doAssert session.game.world.visible(0, session.game.world.map.hallOrigin[1])
    doAssert EndAlliance in session.game.diplomacyChoices(0, 1)
    doAssert DeclareWar notin session.game.diplomacyChoices(0, 1)
  doAssert a.submitHumanDiplomacy(0, 1, EndAlliance)
  sessions[0].flushSubmissions()
  advance(3)
  doAssert a.world.diplomacy.relation(0, 1).state == AllianceEnding
  doAssert a.world.diplomacy.sharesVision(0, 1)
  advance(int(TickRate) * 2)
  doAssert not a.world.diplomacy.sharesVision(0, 1)
  doAssert b.submitHumanDiplomacy(1, 0, OfferAlliance)
  sessions[1].flushSubmissions()
  advance(3)
  doAssert a.submitHumanDiplomacy(0, 1, DeclineOffer,
    a.world.diplomacy.relation(0, 1).offerId)
  sessions[0].flushSubmissions()
  advance(3)
  doAssert a.world.diplomacy.relation(0, 1).offer == NoOffer
  doAssert a.submitHumanDiplomacy(0, 1, DeclareWar)
  sessions[0].flushSubmissions()
  advance(3)
  doAssert a.world.diplomacy.relation(0, 1).state == WarPending
  advance(int(TickRate))
  doAssert a.world.atWar(0, 1)
  echo "PASS peace/alliance acceptance, decline, end alliance, war through real relay; shared vision; peer hashes"

block feedBound:
  for i in 0 ..< MaxHumanChatLines + 5:
    discard ui[0].chatEnter(sessions[0].game, 0)
    discard ui[0].chatRune(Rune(65))
    discard ui[0].chatEnter(sessions[0].game, 0)
  sessions[0].flushSubmissions()
  advance(4)
  for i in 0 .. 1:
    doAssert ui[i].feed.len == MaxHumanChatLines
    doAssert sessions[i].game.inboxes[2].count == MaxMailboxMessages
  echo "PASS bounded feed continues when unread bot mailboxes reach capacity"
