import std/[unittest, random]
import polyworld/[networks, rooms, roomclients, connections]
import ../networkpresentation

suite "LvD network presentation":
  test "smooth visual clock advances between authoritative packets":
    let client = RoomClient(match: 1)
    let stats = NetworkStats(smoothPlayback: true)
    var playback: TickPlayback
    var presentation: NetworkPresentation
    var packet: RoomMessage
    client.accept(RoomMessage(kind: TickPacket, match: 1, tick: 1).encode)
    check playback.takeTick(client, packet, 10, 24, stats.smoothPlayback)
    client.appliedTick(packet.tick)
    presentation.appliedTick()
    check presentation.frameAlpha(playback, stats, 10, 24) == 0
    # Shared smoothing uses a 0.9-tick interval with no backlog.
    check abs(presentation.frameAlpha(playback, stats, 10 + 0.45 / 24, 24) - 0.5) < 0.0001
    check presentation.frameAlpha(playback, stats, 100, 24) == 1
    check client.applied == 1
    check not playback.takeTick(client, packet, 100, 24, stats.smoothPlayback)
    check client.applied == 1

  test "disabled smoothing uses frame time and resets on applied ticks":
    let stats = NetworkStats(smoothPlayback: false)
    var presentation: NetworkPresentation
    var playback: TickPlayback
    presentation.appliedTick()
    presentation.startFrame(0.5 / 24)
    check abs(presentation.frameAlpha(playback, stats, 10, 24) - 0.5) < 0.0001
    presentation.startFrame(5)
    check presentation.frameAlpha(playback, stats, 15, 24) == 1
    presentation.appliedTick()
    check presentation.frameAlpha(playback, stats, 15, 24) == 0

  test "empty and reset sessions do not interpolate unreceived authority":
    let stats = NetworkStats(smoothPlayback: false)
    var presentation: NetworkPresentation
    var playback: TickPlayback
    presentation.startFrame(100)
    check presentation.frameAlpha(playback, stats, 100, 24) == 0
    presentation.appliedTick()
    presentation.startFrame(1)
    check presentation.frameAlpha(playback, stats, 101, 24) == 1
    # A new runGraphics invocation constructs this fresh per-match value.
    presentation = NetworkPresentation()
    presentation.startFrame(1)
    check presentation.frameAlpha(playback, stats, 102, 24) == 0

  test "shared connection enables smoothing by default and toggles immediately":
    # Uses the same constructor as GotA, without opening a server or event loop.
    let connection = connect("ws://127.0.0.1:1/ws", "jitter regression",
      GameIdentity(game: "presentation-test", gameplay: 1, protocol: 1))
    defer: connection.close()
    check connection.stats.smoothPlayback
    check connection.stats.lagMs == 0
    check connection.stats.jitterMs == 0
    connection.client.match = 7
    let stats = connection.stats
    var presentation: NetworkPresentation
    var packet: RoomMessage
    for tick in 1'u32 .. 3'u32:
      connection.client.accept(RoomMessage(kind: TickPacket, match: 7, tick: tick).encode)
    check connection.playback.takeTick(connection.client, packet, 10, 24, stats.smoothPlayback)
    connection.client.appliedTick(packet.tick)
    presentation.appliedTick()
    check not connection.playback.takeTick(connection.client, packet, 10, 24, stats.smoothPlayback)
    stats.smoothPlayback = false
    check not connection.stats.smoothPlayback # Same ref as the debug checkbox.
    check connection.playback.takeTick(connection.client, packet, 10, 24, stats.smoothPlayback)
    connection.client.appliedTick(packet.tick)
    presentation.appliedTick()
    check not connection.playback.started
    presentation.startFrame(0.5 / 24)
    check abs(presentation.frameAlpha(connection.playback, stats, 11, 24) - 0.5) < 0.0001
    stats.smoothPlayback = true
    check connection.playback.takeTick(connection.client, packet, 11, 24, stats.smoothPlayback)
    connection.client.appliedTick(packet.tick)
    presentation.appliedTick()
    check connection.playback.started
    check presentation.frameAlpha(connection.playback, stats, 11, 24) == 0

  test "shared simulated lag and jitter retain packet and control ordering":
    var queue: PacketQueue
    var rng = initRand(8128)
    var expected, delivered: seq[string]
    for i in 0 ..< 100:
      let bytes = RoomMessage(kind: TickPacket, match: 9, tick: uint32(i + 1)).encode
      expected.add bytes
      queue.enqueue(bytes, i.float64 / 1000, 120, 240, rng)
      if i > 0: check queue.packets[^1].due >= queue.packets[^2].due
    # Reset controls affect new delay, not packets already in flight.
    let control = RoomMessage(kind: Keepalive).encode
    expected.add control
    queue.enqueue(control, 0.1, 0, 0, rng)
    for frame in 0 .. 100:
      var consumed = 0
      for packet in queue.packets:
        if packet.due > frame.float64 / 100: break
        delivered.add packet.bytes
        inc consumed
      queue.consume(consumed)
    check delivered == expected
    check queue.packets.len == 0
    check queue.bytes == 0

  test "shared playback resets on a new match and bypasses catchup":
    let client = RoomClient(match: 1)
    let stats = NetworkStats(smoothPlayback: true)
    var playback: TickPlayback
    var presentation: NetworkPresentation
    var packet: RoomMessage
    client.accept(RoomMessage(kind: TickPacket, match: 1, tick: 1).encode)
    check playback.takeTick(client, packet, 10, 24, true)
    client.appliedTick(packet.tick)
    client.match = 2
    client.applied = 0
    client.accept(RoomMessage(kind: TickPacket, match: 2, tick: 1).encode)
    check playback.takeTick(client, packet, 10.001, 24, true)
    client.appliedTick(packet.tick)
    presentation.appliedTick()
    check presentation.frameAlpha(playback, stats, 10.001, 24) == 0
    client.catchupPending = true
    client.accept(RoomMessage(kind: TickPacket, match: 2, tick: 2).encode)
    check playback.takeTick(client, packet, 10.001, 24, true)
    check not playback.started
    presentation.appliedTick()
    presentation.startFrame(0.25 / 24)
    check abs(presentation.frameAlpha(playback, stats, 10.001, 24) - 0.25) < 0.0001
