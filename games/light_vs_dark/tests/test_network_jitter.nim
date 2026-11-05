## Real LvD authority/replay under the existing ordered delay + paced playback.
import std/random
import jsony
import polyworld/[networks, rooms, roomclients]
import ../[networkpresentation, multiplayer, presets, content, sim, replays]

proc session(): NetworkMatch =
  var config = defaultConfig(2)
  config.maxTicks = TickRate * 10
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  let client = RoomClient(identity: lvdIdentity(), participant: 1, match: 1,
    began: true, welcomed: true)
  client.snapshot = RoomMessage(kind: RoomState, revision: 2, phase: Playing,
    tickRate: uint32(TickRate), payload: config.toJson(), seats: @[
      Seat(owner: 1, name: "Human"), Seat(owner: 2, name: "Human")],
    participants: @[Participant(id: 1, name: "A"), Participant(id: 2, name: "B")])
  result = prepareNetworkMatch(client, ["", ""])
  result.start(RoomMessage(kind: BeginMatch, revision: 2, match: 1,
    hash: result.game.networkHash()))

let reference = session()
let delayed = session()
var playback: TickPlayback
var presentation: NetworkPresentation
var packet: RoomMessage
let stats = NetworkStats(smoothPlayback: true)
let originalHash = delayed.game.stateHash()
let originalMessages = delayed.client.outgoing.len
for frame in 0 ..< 120:
  presentation.startFrame(1.0 / 60)
  doAssert not playback.takeTick(delayed.client, packet, frame.float64 / 60,
    int(TickRate), stats.smoothPlayback)
  doAssert presentation.frameAlpha(playback, stats, frame.float64 / 60,
    int(TickRate)) == 0
  doAssert delayed.game.world.tick == 0
  doAssert delayed.game.stateHash() == originalHash
  doAssert delayed.game.recorder.data.hashes.len == 0
  doAssert delayed.client.outgoing.len == originalMessages

var queue: PacketQueue
var rng = initRand(8128)
let unit = reference.game.world.units[0]
let action = ReplayAction(kind: ActionMove, playerId: 0, entityId: unit.id,
  first: int32(unit.tile.x), second: int32(unit.tile.y))
for tick in 1'u32 .. 48'u32:
  let packet = RoomMessage(kind: TickPacket, match: 1, tick: tick,
    commands: (if tick == 1: @[Command(participant: 1, seat: 0, sequence: 1,
      payload: encodeSubmission(action))] else: @[]))
  reference.applyPacket(packet)
  queue.enqueue(packet.encode, 2 + tick.float64 / TickRate.float64,
    80, 180, rng)

var lastTick = 0'u32
for frame in 0 .. 300:
  let now = 2 + frame.float64 / 60
  var consumed = 0
  for entry in queue.packets:
    if entry.due > now: break
    delayed.client.accept(entry.bytes)
    inc consumed
  queue.consume(consumed)
  presentation.startFrame(1.0 / 60)
  # The live debug toggle must not alter hashes or authority.
  stats.smoothPlayback = frame notin 90 .. 110
  while playback.takeTick(delayed.client, packet, now, int(TickRate), stats.smoothPlayback):
    doAssert packet.tick == lastTick + 1
    delayed.applyPacket(packet)
    presentation.appliedTick()
    inc stats.playedTicks
    lastTick = packet.tick
    doAssert delayed.game.stateHash() == reference.game.recorder.data.hashes[int(lastTick) - 1]
  let before = delayed.game.stateHash()
  let alpha = presentation.frameAlpha(playback, stats, now, int(TickRate))
  doAssert alpha >= 0 and alpha <= 1
  doAssert delayed.game.stateHash() == before

doAssert queue.packets.len == 0
doAssert delayed.game.world.tick == 48
doAssert stats.playedTicks == 48
doAssert delayed.game.recorder.data.hashes == reference.game.recorder.data.hashes
doAssert encodeReplay(delayed.game.recorder.data) == encodeReplay(reference.game.recorder.data)
echo "LvD delayed/smoothed authority: 48 ordered ticks, identical hashes and replay; empty frames inert"
