import
  std/random,
  rooms, roomclients

const
  NetworkSamples* = 60
  MaxDelayedPackets* = 1024
  MaxDelayedBytes* = 2 * 1024 * 1024

type
  TickPlayback* = object
    match: uint32
    started*: bool
    playedAt, interval: float64
  NetworkSample* = object
    sentKb*, receivedKb*, sentPackets*, receivedPackets*: float32
    rttMs*, jitterMs*, ticksPerSecond*: float32
  DelayedPacket* = object
    bytes*: string
    due*: float64
  PacketQueue* = object
    packets*: seq[DelayedPacket]
    bytes*: int
  NetworkStats* = ref object
    active*: bool
    smoothPlayback*: bool
    tickRate*: int
    playedTicks*: uint64
    lagMs*, jitterMs*: int
    sentBytes*, receivedBytes*, sentPackets*, receivedPackets*: uint64
    samples*: array[NetworkSamples, NetworkSample]
    cursor*, count*: int
    current*: NetworkSample
    measuredAt*: uint64
    measurementTime*, age*: float64
    epoch: float64
    rttTotal, jitterTotal: float64
    measurements: int
    sentStart, receivedStart, sentPacketStart, receivedPacketStart: uint64
    ticksStart: uint64

proc sample*(stats: NetworkStats, now: float64) =
  ## Stores one-second traffic rates in a bounded scrolling history.
  stats.age = now - stats.measurementTime
  if stats.epoch == 0:
    stats.epoch = now
  let elapsed = now - stats.epoch
  if elapsed < 1:
    return
  stats.current.sentKb = float32(stats.sentBytes - stats.sentStart) /
    (1024 * elapsed).float32
  stats.current.receivedKb = float32(stats.receivedBytes - stats.receivedStart) /
    (1024 * elapsed).float32
  stats.current.sentPackets = float32(stats.sentPackets - stats.sentPacketStart) /
    elapsed.float32
  stats.current.receivedPackets =
    float32(stats.receivedPackets - stats.receivedPacketStart) / elapsed.float32
  stats.current.ticksPerSecond =
    float32(stats.playedTicks - stats.ticksStart) / elapsed.float32
  if stats.measurements > 0:
    stats.current.rttMs = float32(stats.rttTotal / stats.measurements.float64)
    stats.current.jitterMs =
      float32(stats.jitterTotal / stats.measurements.float64)
    stats.rttTotal = 0
    stats.jitterTotal = 0
    stats.measurements = 0
  stats.samples[stats.cursor] = stats.current
  stats.cursor = (stats.cursor + 1) mod NetworkSamples
  stats.count = min(stats.count + 1, NetworkSamples)
  stats.ticksStart = stats.playedTicks
  stats.sentStart = stats.sentBytes
  stats.receivedStart = stats.receivedBytes
  stats.sentPacketStart = stats.sentPackets
  stats.receivedPacketStart = stats.receivedPackets
  stats.epoch = now

proc measure*(stats: NetworkStats, timing: PacketTiming, now: float64) =
  ## Accumulates server measurements for a stable one-second average.
  if timing.measuredAt > 0 and timing.measuredAt != stats.measuredAt:
    stats.measuredAt = timing.measuredAt
    stats.measurementTime = now
    stats.rttTotal += timing.rtt.float64 / 1000
    stats.jitterTotal += timing.jitter.float64 / 1000
    inc stats.measurements

proc enqueue*(
    queue: var PacketQueue, bytes: string, now: float64,
    lagMs, jitterMs: int, rng: var Rand
) =
  ## Adds bounded delay while preserving the WebSocket's ordered delivery.
  if queue.packets.len >= MaxDelayedPackets or
    queue.bytes + bytes.len > MaxDelayedBytes:
      reject("Network simulator queue exhausted")
  let
    jitter = if jitterMs > 0: rng.rand(jitterMs) else: 0
    due = now + float64(lagMs + jitter) / 1000
  queue.packets.add DelayedPacket(
    bytes: bytes,
    due: max(due, if queue.packets.len > 0: queue.packets[^1].due else: now)
  )
  queue.bytes += bytes.len

proc consume*(queue: var PacketQueue, count: int) =
  ## Removes a delivered prefix without reallocating the reusable queue.
  for i in 0 ..< count:
    queue.bytes -= queue.packets[i].bytes.len
  for i in count ..< queue.packets.len:
    queue.packets[i - count] = queue.packets[i]
  queue.packets.setLen(queue.packets.len - count)

proc clear*(queue: var PacketQueue) =
  ## Discards only transport bytes when a socket ends or reconnects.
  queue.packets.setLen(0)
  queue.bytes = 0

proc takeTick*(
  playback: var TickPlayback,
  client: RoomClient,
  packet: var RoomMessage,
  now: float64,
  tickRate: int,
  smooth: bool
): bool =
  ## Paces live ticks without delaying control packets or history catch-up.
  if not smooth or client.catchupPending or
    client.serverTick > client.applied + 8:
      playback = TickPlayback()
      return client.takeTick(packet)
  let
    step = 1.0 / tickRate.float64
    queued = client.packets.len
    backlog = max(0, queued - 1).float64
    interval = step * max(0.2, 0.9 / (1 + 0.25 * backlog))
  if playback.match != client.match:
    playback = TickPlayback(match: client.match)
  if playback.started and now < playback.playedAt + interval:
    return false
  result = client.takeTick(packet)
  if result:
    # Keep fractional frame time, but never accumulate a large catch-up burst.
    playback.playedAt =
      if playback.started:
        max(playback.playedAt + interval, now - interval * 0.1)
      else:
        now
    playback.interval = interval
    playback.started = true

proc elapsed*(playback: TickPlayback, now: float64, tickRate: int): float64 =
  ## Scales visual interpolation with the adaptive playback interval.
  if playback.interval == 0:
    return 0
  clamp((now - playback.playedAt) / playback.interval, 0.0, 1.0) /
    tickRate.float64
