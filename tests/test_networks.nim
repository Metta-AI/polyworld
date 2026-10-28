import
  std/random,
  polyworld/[rooms, relays, roomclients, networks]

echo "Testing normal-packet server-clock RTT and piggybacked receipts"
let
  relay = Relay()
  client = RoomClient(identity: GameIdentity(game: "test", gameplay: 1,
    protocol: 1), name: "Tester")
client.opened()
relay.receive(1, decode(client.outgoing[0]), 100)
client.outgoing.setLen(0)
let welcome = decode(relay.outgoing[^1].bytes)
doAssert welcome.timing.server == 100_000_000
client.accept(welcome.encode())
doAssert client.outgoing.len == 1
let request = decode(client.outgoing[0])
doAssert request.kind == ListRooms
doAssert request.timing.echo == welcome.timing.server
doAssert request.timing.received == welcome.delivery
relay.receive(1, request, 100.125)
let first = decode(relay.outgoing[^1].bytes)
doAssert first.timing.rtt == 125_000
client.outgoing.setLen(0)
client.accept(first.encode())
doAssert client.outgoing.len == 0 and client.receiptPending
client.send(RoomMessage(kind: ListRooms))
relay.receive(1, decode(client.outgoing[0]), 100.325)
let second = decode(relay.outgoing[^1].bytes)
doAssert second.timing.rtt == 200_000
doAssert second.timing.jitter == 75_000
let stats = NetworkStats()
stats.sample(10)
stats.measure(second.timing, 10.1)
stats.measure(second.timing, 10.2)
stats.measure(PacketTiming(measuredAt: 101_000_000,
  rtt: 100_000, jitter: 25_000), 10.3)
stats.sample(10.5)
doAssert stats.current.rttMs == 0 and stats.current.jitterMs == 0
var forged = RoomMessage(kind: ListRooms,
  timing: PacketTiming(received: second.delivery, echo: 1))
var rejected = false
try:
  relay.receive(1, forged, 101)
except RoomsError:
  rejected = true
doAssert rejected

# Repeated tick content remains immutable despite new transport measurements.
client.match = 1
client.accept(RoomMessage(kind: TickPacket, match: 1, tick: 1,
  timing: PacketTiming(server: 10)).encode())
client.accept(RoomMessage(kind: TickPacket, match: 1, tick: 1,
  timing: PacketTiming(server: 20, rtt: 30)).encode())
doAssert client.packets.len == 1

echo "Testing bounded ordered delay and one-second traffic samples"
var
  queue: PacketQueue
  rng = initRand(42)
queue.enqueue("first", 1, 200, 0, rng)
doAssert queue.packets[0].due == 1.2
for i in 0 ..< 100:
  queue.enqueue("next", 1, 100, 150, rng)
  doAssert queue.packets[^1].due >= queue.packets[^2].due
  doAssert queue.packets[^1].due <= 1.25
doAssert queue.bytes == 405
queue.consume(1)
doAssert queue.bytes == 400 and queue.packets.len == 100
queue.clear()
doAssert queue.bytes == 0 and queue.packets.len == 0
rejected = false
try:
  queue.enqueue(newString(MaxDelayedBytes + 1), 1, 0, 0, rng)
except RoomsError:
  rejected = true
doAssert rejected
stats.sample(10)
stats.sentBytes = 2048
stats.receivedBytes = 1024
stats.sentPackets = 24
stats.receivedPackets = 12
stats.sample(11)
doAssert stats.current.sentKb == 2 and stats.current.receivedKb == 1
doAssert stats.current.sentPackets == 24 and stats.current.receivedPackets == 12
doAssert stats.current.rttMs == 150 and stats.current.jitterMs == 50
stats.measure(PacketTiming(measuredAt: 102_000_000,
  rtt: 300_000, jitter: 20_000), 11.1)
doAssert stats.current.rttMs == 150 and stats.current.jitterMs == 50
stats.sample(12)
doAssert stats.current.rttMs == 300 and stats.current.jitterMs == 20
for i in 12 .. 100:
  stats.sample(i.float64)
doAssert stats.count == NetworkSamples

echo "Network timing, immutable payloads, queue bounds and rates passed"

echo "Testing adaptive playback, stalls, toggles and catch-up"
let paced = RoomClient(match: 4)
var
  playback: TickPlayback
  tick: RoomMessage
# Even the first packet plays immediately on a steady connection.
for i in 1 .. 24:
  let now = i.float64 / 24
  paced.accept(RoomMessage(kind: TickPacket, match: 4, tick: i.uint32).encode)
  doAssert playback.takeTick(paced, tick, now, 24, true)
  doAssert tick.tick == i.uint32
  paced.appliedTick(tick.tick)
  doAssert not playback.takeTick(paced, tick, now, 24, true)
# A burst is spaced out, with a shorter interval while the queue is fuller.
for i in 25 .. 30:
  paced.accept(RoomMessage(kind: TickPacket, match: 4, tick: i.uint32).encode)
var played: seq[float64]
for frame in 0 .. 200:
  let now = 2.0 + frame.float64 / 1000
  if playback.takeTick(paced, tick, now, 24, true):
    doAssert tick.tick == 25.uint32 + played.len.uint32
    paced.appliedTick(tick.tick)
    played.add now
    doAssert not playback.takeTick(paced, tick, now, 24, true)
doAssert played.len == 6
for i in 1 ..< played.len:
  doAssert played[i] > played[i - 1]
  doAssert played[i] - played[i - 1] < 1.0 / 24
doAssert played[1] - played[0] < played[^1] - played[^2]
# A long gap earns no catch-up burst, and disabling drains immediately.
doAssert not playback.takeTick(paced, tick, 20, 24, true)
for i in 31 .. 33:
  paced.accept(RoomMessage(kind: TickPacket, match: 4, tick: i.uint32).encode)
doAssert playback.takeTick(paced, tick, 20, 24, true)
paced.appliedTick(tick.tick)
doAssert not playback.takeTick(paced, tick, 20, 24, true)
doAssert playback.takeTick(paced, tick, 20, 24, false)
paced.appliedTick(tick.tick)
doAssert not playback.started
paced.catchupPending = true
doAssert playback.takeTick(paced, tick, 20, 24, true)
paced.appliedTick(tick.tick)
paced.snapshot.phase = Desynced
doAssert not playback.takeTick(paced, tick, 30, 24, true)
echo "Adaptive playback catches up without changing tick order"

# Repeated jitter at 60 FPS must not grow an ever-larger playback backlog.
let jittered = RoomClient(match: 5)
var
  smoothing: TickPlayback
  sent = 0
  peakQueue = 0
for frame in 0 .. 3660:
  let
    now = frame.float64 / 60
    # Deliver groups of three ticks every 125 ms.
    arrived = min(1440, int(now * 8) * 3)
  while sent < arrived:
    inc sent
    jittered.accept(RoomMessage(
      kind: TickPacket, match: 5, tick: sent.uint32
    ).encode)
  peakQueue = max(peakQueue, jittered.packets.len)
  while smoothing.takeTick(jittered, tick, now, 24, true):
    jittered.appliedTick(tick.tick)
doAssert jittered.applied == 1440 and jittered.packets.len == 0
doAssert peakQueue <= 5
echo "Repeated bursts stay bounded and drain completely"

echo "Testing effective simulation ticks per second"
let playbackStats = NetworkStats(tickRate: 24)
playbackStats.sample(10)
playbackStats.playedTicks = 48
playbackStats.sample(12)
doAssert playbackStats.current.ticksPerSecond == 24
playbackStats.sample(13)
doAssert playbackStats.current.ticksPerSecond == 0
playbackStats.playedTicks += 60
playbackStats.sample(14)
doAssert playbackStats.current.ticksPerSecond == 60
doAssert playbackStats.samples[0].ticksPerSecond == 24
doAssert playbackStats.samples[1].ticksPerSecond == 0
doAssert playbackStats.samples[2].ticksPerSecond == 60
