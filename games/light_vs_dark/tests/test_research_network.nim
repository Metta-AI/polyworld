## In-process real relay test: human research intents, authoritative packets,
## duplicate rejection, completion and serialized replay from the fixture snapshot.
import jsony, polyworld/[rooms, relays, roomclients, tapes],
  ../[multiplayer, presets, sim, replays, content, controls]

var relay = Relay()
var clients: seq[RoomClient]
var sessions: seq[NetworkMatch]
var now = 0.0
proc exchange() =
  for _ in 0 ..< 30:
    var sent = false
    for i, client in clients:
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        relay.process(i + 1, bytes, now)
        sent = true
    let outgoing = relay.outgoing
    relay.outgoing = @[]
    for message in outgoing:
      doAssert not message.close
      if message.bytes.len > 0:
        clients[message.connection - 1].accept(message.bytes)
        doAssert clients[message.connection - 1].error.len == 0,
          clients[message.connection - 1].error
        sent = true
    if not sent: return
  doAssert false, "Research relay exchange did not settle"

for i in 0 ..< 2:
  clients.add RoomClient(identity: lvdIdentity(), name: "Research human " & $i)
  clients[i].opened()
  exchange()
var config = defaultConfig(2)
config.maxTicks = researchStats(KeenflightArrows, 1).ticks + 48
config.mapSettings = MapSettings(layout: RandomLayout, expansions: 0)
clients[0].send(RoomMessage(kind: CreateRoom, name: "Research fixture", number: 2,
  tickRate: TickRate.uint32, flag: false, payload: config.toJson()))
exchange()
clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
exchange()
clients[0].claimHumanSeat(0)
clients[1].claimHumanSeat(1)
exchange()
var initial: World
for client in clients:
  let session = prepareNetworkMatch(client, ["", ""])
  # Isolate research transport from the already-tested economy/construction.
  # Preserve IDs, footprint and resources; use registered opening structures.
  for building in session.game.world.buildings.mitems:
    if building.owner >= 0: building.kind = LumberMillBuilding
  sessions.add session
  if initial == nil: initial = session.game.world.clone()
  client.send(RoomMessage(kind: Ready, revision: session.revision,
    hash: session.game.networkHash()))
exchange()
clients[0].send(RoomMessage(kind: StartMatch))
exchange()
for session in sessions:
  doAssert session.client.events.len == 1
  session.start(session.client.events[0])
exchange()
for player in 0'i32 .. 1'i32:
  let session = sessions[player]
  var id = NoEntity
  for building in session.game.world.buildings:
    if building.owner == player: id = building.id
  let baseline = session.game.stateHash()
  queueResearch(player, id, KeenflightArrows)
  queueResearch(player, id, KeenflightArrows) # same-tick duplicate costs nothing
  session.flushSubmissions()
  doAssert session.game.stateHash() == baseline
exchange()
for _ in 0 ..< config.maxTicks + 50:
  now += 1.0 / TickRate.float64
  relay.advance(now)
  exchange()
  for session in sessions: discard session.pump(16)
  exchange()
  if sessions[0].game.world.tick == sessions[1].game.world.tick:
    doAssert sessions[0].game.stateHash() == sessions[1].game.stateHash()
  if sessions[0].finished and sessions[1].finished: break
for session in sessions:
  doAssert session.finished
  doAssert session.game.recorder.data.actions.len == 2
  for player in 0'i32 .. 1'i32:
    doAssert session.game.world.researchLevel(player, KeenflightArrows) == 1
    doAssert session.game.world.players[player].gold == StartingGold - 600
    doAssert session.game.world.players[player].wood == StartingWood - 200
  let data = decodeReplay(encodeReplay(session.game.recorder.data))
  let playback = Game(world: initial.clone())
  let cursor = initReplayPlayer(data)
  proc replay(w: World) =
    var action: ReplayAction
    while cursor.takeActionAt(w.tick.uint32, action):
      doAssert w.applyReplayAction(action)
  for hash in data.hashes:
    playback.world.tickWorld(replay)
    doAssert playback.stateHash() == hash
  doAssert playback.stateHash() == session.game.stateHash()
echo "LvD research: two humans, real relay packets, duplicate rejection and replay passed"
