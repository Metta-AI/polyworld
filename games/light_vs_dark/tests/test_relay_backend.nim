import jsony, polyworld/[rooms, relays, roomclients, tapes],
  ../[multiplayer, presets, sim, replays, content]

var relay = Relay()
var clients: seq[RoomClient]
var sessions: seq[NetworkMatch]
var now = 0.0

proc exchange() =
  for iteration in 0 ..< 30:
    var sent = false
    for i, client in clients:
      if not client.connected: continue
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
        if message.close: client.lost()
    if not sent: return
  doAssert false, "Relay exchange did not settle"

for i in 0 ..< 2:
  let client = RoomClient(identity: lvdIdentity(), name: "Player " & $i)
  clients.add client
  client.opened()
  exchange()
var config = defaultConfig(3)
config.maxTicks = 48
config.mapSettings = MapSettings(layout: RandomLayout, expansions: 0)
clients[0].send(RoomMessage(kind: CreateRoom, name: "LvD relay test", number: 3,
  tickRate: uint32(TickRate), flag: true, payload: config.toJson()))
exchange()
clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
exchange()
clients[0].claimHumanSeat(0)
clients[1].send(RoomMessage(kind: ClaimSeat, seat: 1, name: "base"))
clients[0].send(RoomMessage(kind: ClaimSeat, seat: 2, name: "base"))
exchange()
doAssert clients[0].snapshot.humanSeatFor(clients[0].participant) == 0
let source = readFile("games/light_vs_dark/players/base.bas")
for client in clients:
  var sources = newSeq[string](3)
  for i, seat in client.snapshot.seats:
    if i != 0 and seat.owner == client.participant: sources[i] = source
  let session = prepareNetworkMatch(client, sources)
  sessions.add session
  client.send(RoomMessage(kind: Ready, revision: session.revision,
    hash: session.game.networkHash()))
exchange()
clients[0].send(RoomMessage(kind: StartMatch))
exchange()
for session in sessions:
  doAssert session.client.events.len == 1
  session.start(session.client.events[0])
exchange()
for iteration in 0 ..< 200:
  now += 1.0 / 24
  if iteration == 10:
    relay.disconnect(1)
    clients[0].lost()
  if iteration == 15:
    clients[0].opened()
    exchange()
  relay.advance(now)
  exchange()
  for session in sessions:
    if session.client.connected:
      discard session.pump(16)
  exchange()
  if sessions[0].finished and sessions[1].finished:
    relay.advance(now)
    exchange()
    break
for session in sessions:
  doAssert session.finished
  doAssert session.game.world.tick == 48
  doAssert session.game.stateHash() == sessions[0].game.stateHash()
  doAssert session.client.snapshot.phase == Ended
  let data = decodeReplay(encodeReplay(session.game.recorder.data))
  doAssert data.actions.len > 0
  let playback = newGame(session.game.world.map, 48)
  let cursor = initReplayPlayer(data)
  proc replay(w: World) =
    var action: ReplayAction
    while cursor.takeActionAt(uint32(w.tick), action):
      doAssert w.applyReplayAction(action)
  for tick in 1 .. data.hashes.len:
    playback.world.tickWorld(replay)
    doAssert playback.stateHash() == data.hashes[tick - 1]
echo "LvD real relay, reconnect, private bots and replay passed"
