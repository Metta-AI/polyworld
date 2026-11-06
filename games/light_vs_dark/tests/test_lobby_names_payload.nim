
import jsony, polyworld/[rooms, roomclients, relays]
import ../[multiplayer, presets, content]
let names = ["mason :)", "空 白 🙂 : \"quoted\""]
let relay = Relay()
var clients: seq[RoomClient]
proc exchange() =
  for iteration in 0 ..< 20:
    var sent = false
    for i, client in clients:
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        relay.process(i + 1, bytes, 0)
        sent = true
    let outgoing = relay.outgoing
    relay.outgoing = @[]
    for output in outgoing:
      clients[output.connection - 1].accept(output.bytes)
      doAssert clients[output.connection - 1].error.len == 0
      sent = true
    if not sent: return
  doAssert false
for name in names:
  let client = RoomClient(identity: lvdIdentity(), name: name)
  clients.add client
  client.opened()
  exchange()
var config = defaultConfig(2)
config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
clients[0].send(RoomMessage(kind: CreateRoom, name: names[0] & "'s game",
  number: 2, tickRate: uint32(TickRate), payload: config.toJson()))
exchange()
clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
exchange()
for i, client in clients: client.claimHumanSeat(i)
exchange()
var sessions: seq[NetworkMatch]
for client in clients:
  for i, participant in client.snapshot.participants:
    doAssert participant.name == names[i]
  let session = prepareNetworkMatch(client, ["", ""])
  sessions.add session
  for i, player in session.game.recorder.data.config.players:
    doAssert player.name == names[i]
  doAssert session.game.recorder.data.config.toJson().fromJson(GameConfig).players == session.game.recorder.data.config.players
  client.send(RoomMessage(kind: Ready, revision: session.revision, hash: session.game.networkHash()))
exchange()
doAssert sessions[0].game.networkHash() == sessions[1].game.networkHash()
clients[0].send(RoomMessage(kind: StartMatch))
exchange()
for i, client in clients:
  sessions[i].start(client.events[0])
  doAssert sessions[i].started
echo "LvD opaque names survive wire, snapshot, preparation and startup"
