## Browser startup regression: runGraphics asset loading blocks pumping for >16 ticks.
## The relay keeps advancing, but clients must discover history beyond their last
## pushed packet, even when their initial Catchup completed before loading began.
import std/unittest
import polyworld/[rooms, roomclients, relays]

suite "Browser graphics loading gap":
  test "two sparse humans rediscover ticks after exhausting pushed startup packets":
    let relay = Relay()
    var clients: array[2, RoomClient]
    for i in 0 .. 1:
      clients[i] = RoomClient(identity: GameIdentity(
        game: "galcon", gameplay: 77, protocol: 1),
        name: if i == 0: "DraftBrowserHost" else: "DraftBrowserGuest")
      clients[i].opened()

    proc pump() =
      for i, client in clients:
        var outgoing: seq[string]
        swap(outgoing, client.outgoing)
        for bytes in outgoing:
          relay.receive(i + 1, decode(bytes), 0)
      var outgoing: seq[Outgoing]
      swap(outgoing, relay.outgoing)
      for packet in outgoing:
        if packet.bytes.len > 0:
          clients[packet.connection - 1].accept(packet.bytes)

    pump()
    pump()
    clients[0].send(RoomMessage(kind: CreateRoom, name: "Loading gap QA",
      number: 10, tickRate: 24, flag: false))
    pump()
    clients[1].send(RoomMessage(kind: JoinRoom, room: relay.rooms[0].id))
    pump()
    for i, seat in [0'u32, 5'u32]:
      clients[i].send(RoomMessage(kind: ClaimSeat, seat: seat, name: "Human"))
    pump()
    for client in clients:
      client.send(RoomMessage(kind: Ready,
        revision: relay.rooms[0].revision, hash: 42))
    pump()
    clients[0].send(RoomMessage(kind: StartMatch))
    pump()
    pump() # Initial Catchup -> CaughtUp(0), before graphics loading.
    check not clients[0].catchupPending
    check not clients[1].catchupPending

    # About four seconds of synchronous graphics loading: callbacks cannot pump
    # and neither browser can publish AppliedTick. Relay only pushes ticks 1..16.
    for tick in 1 .. 96:
      relay.advance(tick.float64 * 0.05)
    pump()
    for client in clients:
      var packet: RoomMessage
      while client.takeTick(packet):
        client.appliedTick(packet.tick)
      check client.applied == 16
    pump()
    # Actual first host pick is accepted, but cannot be applied while stranded.
    check clients[0].submit(0, "ordinary queued host hero selection")
    pump()
    relay.advance(97.0 * 0.05)
    check decode(relay.rooms[0].history[96]).commands[0].payload ==
      "ordinary queued host hero selection"

    var received: array[2, seq[uint32]]
    var selections: array[2, seq[string]]
    for i in 0 .. 1:
      for tick in 1'u32 .. 16'u32:
        received[i].add tick
    proc drain() =
      # Bound exchanges by history batches, not a wall-clock timeout. The relay
      # does not advance here: recovery must discover already retained history.
      for attempt in 0 ..< 32:
        pump()
        for i, client in clients:
          var packet: RoomMessage
          while client.takeTick(packet):
            check packet.tick == uint32(received[i].len + 1)
            received[i].add packet.tick
            for command in packet.commands:
              selections[i].add command.payload
            client.appliedTick(packet.tick)
        if clients[0].outgoing.len == 0 and clients[1].outgoing.len == 0 and
            relay.outgoing.len == 0:
          return
      require false # Catchup(0)/CaughtUp(0) or empty-edge response loop.

    drain()
    for i, client in clients:
      check client.error.len == 0
      check client.applied == 97
      check received[i].len == 97
      check selections[i] == @["ordinary queued host hero selection"]
      check not client.catchupPending
    check clients[1].submit(5, "ordinary queued guest hero selection")
    pump()
    relay.advance(98.0 * 0.05)
    drain()
    for i, client in clients:
      check client.applied == 98
      check selections[i] == @["ordinary queued host hero selection",
        "ordinary queued guest hero selection"]
    check relay.rooms[0].tick == 98

    # The same consumed-edge recovery must work without another produced tick.
    # Pause and completion retain their exact edge; reconnect retains the cursor.
    for tick in 99 .. 194:
      relay.advance(tick.float64 * 0.05)
    clients[0].send(RoomMessage(kind: PauseMatch, match: clients[0].match,
      flag: true))
    pump()
    relay.advance(195.0 * 0.05)
    drain()
    for client in clients:
      check client.applied == 194
      check client.snapshot.phase == Waiting
      check not client.catchupPending
    clients[0].send(RoomMessage(kind: PauseMatch, match: clients[0].match,
      flag: false))
    pump()
    relay.advance(196.0 * 0.05)
    for tick in 197 .. 292:
      relay.advance(tick.float64 * 0.05)
    clients[0].send(RoomMessage(kind: FinishMatch,
      match: clients[0].match, tick: 290, hash: 900))
    pump()
    relay.advance(293.0 * 0.05)
    drain()
    for client in clients:
      check client.applied == 290
      check client.snapshot.phase == Ended
      check not client.catchupPending
    relay.disconnect(2)
    clients[1].lost()
    clients[1].opened()
    drain()
    check clients[1].applied == 290
    check clients[1].snapshot.phase == Ended
