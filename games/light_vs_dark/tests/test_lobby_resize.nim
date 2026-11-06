import jsony, polyworld/[rooms, roomclients]
import ../[rosterstate, presets]
var config = defaultConfig(2)
let client = RoomClient(participant: 1, connected: true, welcomed: true,
  snapshot: RoomMessage(kind: RoomState, room: "room", participant: 1,
    phase: Lobby, name: "Host's game", tickRate: 24, payload: config.toJson()))
var state: RosterState
state.resizeRoster(config, client, 3)
doAssert client.outgoing.len == 1
let packet = decode(client.outgoing[0])
doAssert packet.kind == ResizeRoom
doAssert packet.number == 3 and packet.name == client.snapshot.name
doAssert parseConfig(packet.payload).playerCount == 3
doAssert state.pending
echo "LvD roster resizing uses roster-only operation"
