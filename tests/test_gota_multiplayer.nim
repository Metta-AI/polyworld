import
  std/os,
  jsony,
  polyworld/[rooms, relays, roomclients, tapes, mailboxes, networks],
  ../examples/gods_of_the_arena/[bots, content, maps, multiplayer, replays, sim]

var
  relay = Relay()
  clients: seq[RoomClient]
  sessions: seq[NetworkMatch]
  now = 0.0
  playbacks: array[16, TickPlayback]

proc exchange() =
  ## Pumps synthetic sockets through the real binary client and relay code.
  for iteration in 0 ..< 20:
    var sent = false
    for i, client in clients:
      if not client.connected:
        continue
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        relay.process(i + 1, bytes, now)
        sent = true
    let outgoing = relay.outgoing
    relay.outgoing = @[]
    for message in outgoing:
      let client = clients[message.connection - 1]
      if client.connected:
        if message.bytes.len > 0:
          client.accept(message.bytes)
          doAssert client.error.len == 0, client.error
          sent = true
        if message.close:
          client.lost()
    if not sent:
      return
  doAssert false, "Network did not settle"

proc addClient(): RoomClient =
  ## Opens an independent logical client with no policy state on the relay.
  result = RoomClient(identity: gotaIdentity(), name: "Player " & $clients.len)
  clients.add result
  result.opened()
  exchange()

proc advanceClients() =
  ## Applies every available packet and compares every participating simulation.
  for i, session in sessions:
    if not session.client.connected or session.finished:
      continue
    var packet: RoomMessage
    while playbacks[i].takeTick(
      session.client,
      packet,
      now,
      24,
      i == 0
    ):
      session.applyPacket(packet)
      if session.finished:
        break
  exchange()
  if sessions.len > 1:
    let tick = sessions[0].game.world.tick
    for session in sessions:
      if session.game.world.tick == tick:
        doAssert session.game.stateHash == sessions[0].game.stateHash

echo "Testing distributed GotA policies and packet-only advancement"
let
  first = addClient()
  second = addClient()
  third = addClient()
  config = parseConfig("{\"maxTicks\":240,\"draftMode\":\"open\"}")
  base = readFile("examples/gods_of_the_arena/players/base.bas")
first.send(RoomMessage(
  kind: CreateRoom, name: "GotA test", number: 10, tickRate: 24,
  flag: true, payload: config.toJson()
))
exchange()
let roomId = first.snapshot.room
second.send(RoomMessage(kind: JoinRoom, room: roomId))
third.send(RoomMessage(kind: JoinRoom, room: roomId))
exchange()
echo "Testing one human slot per participant with multiple bot slots"
first.claimHumanSeat(0)
second.claimHumanSeat(1)
first.send(RoomMessage(kind: ClaimSeat, seat: 9, name: "Base bot"))
exchange()
first.claimHumanSeat(3, 0)
first.claimHumanSeat(6, 3)
exchange()
doAssert first.snapshot.humanSeatFor(first.participant) == 6
doAssert first.snapshot.humanSeatFor(second.participant) == 1
doAssert first.snapshot.seats[0].owner == 0
doAssert first.snapshot.seats[3].owner == 0
doAssert first.snapshot.seats[9].owner == first.participant
try:
  first.claimHumanSeat(1, 6)
  doAssert false, "Another participant's human slot must remain theirs"
except RoomsError:
  discard
doAssert first.outgoing.len == 0
first.send(RoomMessage(kind: ClaimSeat, seat: 3, name: "Human"))
exchange()
try:
  discard prepareNetworkMatch(first, [])
  doAssert false, "Duplicate human slots must fail setup validation"
except RoomsError:
  discard
first.claimHumanSeat(6)
exchange()
doAssert first.snapshot.seats[3].owner == 0
for seat in 0 ..< 10:
  clients[seat mod 3].send(RoomMessage(
    kind: ClaimSeat, seat: uint32(seat), name: "Seat " & $seat
  ))
exchange()
for client in clients:
  var sources = newSeq[string](10)
  for seat in 0 ..< 10:
    if seat >= 2 and client.snapshot.seats[seat].owner == client.participant:
      sources[seat] = base
  let session = prepareNetworkMatch(client, sources)
  sessions.add session
  for seat, vm in session.game.heroVms:
    doAssert (vm != nil) ==
      (seat >= 2 and client.snapshot.seats[seat].owner == client.participant)
  client.send(RoomMessage(
    kind: Ready, revision: session.revision, hash: session.game.networkHash
  ))
exchange()
first.send(RoomMessage(kind: StartMatch))
exchange()
for session in sessions:
  doAssert session.client.events.len == 1
  session.start(session.client.events[0])
  session.client.events.setLen(0)
exchange()
var disconnectedTick = 0'u32
for iteration in 0 ..< 600:
  now += 1.0 / 23
  if iteration mod 60 == 0:
    for client in clients:
      if client.connected:
        client.send(RoomMessage(kind: Keepalive))
  if iteration == 40:
    relay.disconnect(1)
    first.lost()
    disconnectedTick = relay.rooms[0].tick
  if iteration in 41 .. 49:
    doAssert relay.rooms[0].tick == disconnectedTick
  if iteration == 50:
    first.opened()
  if iteration == 80:
    let spectator = addClient()
    spectator.send(RoomMessage(kind: JoinRoom, room: roomId))
    exchange()
    let session = prepareNetworkMatch(spectator, [])
    sessions.add session
    for vm in session.game.heroVms:
      doAssert vm == nil
    session.start(spectator.events[0])
    spectator.events.setLen(0)
  for seat in 0 .. 1:
    let session = sessions[seat]
    if not session.client.connected:
      continue
    let hero = session.game.world.heroes[seat]
    if session.game.world.draftHeroId() == hero.id:
      doAssert session.game.submitAction(ReplayAction(
        heroId: hero.id, kind: ActionDraft, first: int32(seat)
      ))
    if iteration == 100:
      # Queue acceptance does not turn a rejected attack into a success.
      doAssert session.game.submitAction(ReplayAction(
        heroId: hero.id, kind: ActionAttackTarget, first: -999
      ))
      if seat == 0:
        doAssert session.game.sendChat(0, 1, "Across clients") == 1
    session.flushSubmissions()
  exchange()
  relay.advance(now)
  exchange()
  advanceClients()
  if relay.rooms[0].phase == rooms.Ended:
    break
  doAssert relay.rooms[0].phase != Desynced, relay.rooms[0].detail
for session in sessions:
  doAssert session.finished
  let mailbox = session.game.inboxes[1]
  var received = false
  for i in 0 ..< mailbox.count:
    if mailbox.messages[(mailbox.first + i) mod MaxMailboxMessages] ==
      "Across clients":
        received = true
  doAssert received, "Cross-client bot mail was not delivered"
  doAssert session.game.stateHash == sessions[0].game.stateHash
  for vm in session.game.heroVms:
    if vm != nil:
      doAssert not vm.failed, vm.lastError
let
  data = sessions[0].game.recorder.data
  replay = newGame(
    generateMap(data.config.seed, data.config.mapPreset),
    data.config.spawnIntervalTicks, 0, true, data
  )
replay.historyPlayback = true
replay.replayPlayer = initReplayPlayer(data)
for tick in 0 ..< data.hashes.len:
  replay.tickWorld(nil)
doAssert replay.hashCheck.mismatches == 0
for session in sessions:
  doAssert session.game.recorder.data.actions == data.actions
  doAssert session.game.recorder.data.hashes == data.hashes
# A valid envelope still cannot issue commands for another seat's hero.
var rejected = false
try:
  discard decodeSubmission("bad")
except RoomsError:
  rejected = true
doAssert rejected
echo "Distributed bots, reconnect, spectator catch-up and replay hashes passed"

let previousTick = sessions[0].game.world.tick
var badPacket = RoomMessage(
  kind: TickPacket, match: first.match, tick: uint32(previousTick + 1),
  commands: @[Command(
    participant: first.participant, seat: 0, sequence: 999,
    payload: GameSubmission(action: ReplayAction(
      heroId: sessions[0].game.world.heroes[1].id,
      kind: ActionAttackTarget, first: -999
    )).encodeSubmission()
  )]
)
rejected = false
try:
  sessions[0].applyPacket(badPacket)
except RoomsError:
  rejected = true
doAssert rejected and sessions[0].game.world.tick == previousTick
# Configuration mutation must change the network digest before simulation.
let original = sessions[0].game.networkHash()
inc sessions[0].game.recorder.data.config.maxTicks
doAssert sessions[0].game.networkHash() != original
echo "Multiple humans, queued rejection, ownership and mailbox checks passed"
