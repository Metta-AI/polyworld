import std/unittest
import jsony, polyworld/[rooms, roomclients, relays]
import ../[presets, rosterstate]

proc exchange(relay: Relay, client: RoomClient) =
  for iteration in 0 ..< 20:
    let requests = client.outgoing
    client.outgoing = @[]
    for bytes in requests:
      relay.process(1, bytes, 0)
    let replies = relay.outgoing
    relay.outgoing = @[]
    for reply in replies:
      if reply.bytes.len > 0: client.accept(reply.bytes)
    if client.outgoing.len == 0: return
  doAssert false, "exchange did not settle"

proc lobby(): tuple[relay: Relay, client: RoomClient, config: LvdConfig] =
  result.relay = Relay()
  result.client = RoomClient(name: "Host",
    identity: GameIdentity(game: "lvd-roster-test", gameplay: 1, protocol: 1))
  result.client.opened()
  exchange(result.relay, result.client)
  result.config = defaultConfig(2)
  result.client.send(RoomMessage(kind: CreateRoom, name: "Roster",
    number: 2, tickRate: 24, flag: false, payload: result.config.toJson()))
  exchange(result.relay, result.client)

suite "LvD roster state":
  test "only an in-flight relay update blocks assignments, not a map draft":
    let saving = RosterState(pendingPayload: "in flight")
    check not saving.assignmentsEnabled(true)
    check saving.assignmentsEnabled(false)
    check RosterState(dirty: true).assignmentsEnabled(true)

  test "add player sends exactly one resize without Apply Settings":
    var (relay, client, config) = lobby()
    var state: RosterState
    state.resizeRoster(config, client, 3)
    check client.outgoing.len == 1
    check state.pending
    check not state.dirty
    exchange(relay, client)
    check client.error == ""
    check client.snapshot.seats.len == 3
    check parseConfig(client.snapshot.payload).playerCount == 3

  test "resize acknowledgement preserves unapplied map settings":
    var (relay, client, config) = lobby()
    var state = RosterState(dirty: true)
    config.seed = 88
    state.resizeRoster(config, client, 3)
    let published = state.pendingPayload
    check parseConfig(published).seed == 2026
    check config.seed == 88
    state.acceptConfig(config, published)
    check not state.pending
    check state.dirty
    check config.seed == 88
    check config.playerCount == 3
    check state.assignmentsEnabled(true)

  test "rejected resize restores authoritative count without losing map draft":
    var (relay, client, config) = lobby()
    var state = RosterState(dirty: true)
    config.seed = 88
    state.resizeRoster(config, client, 3)
    state.rejectConfig(config, client.snapshot.payload)
    check not state.pending
    check state.dirty
    check config.playerCount == 2
    check config.seed == 88
    check state.assignmentsEnabled(true)

  test "pending resize cannot be sent twice":
    var (relay, client, config) = lobby()
    var state: RosterState
    state.resizeRoster(config, client, 3)
    state.resizeRoster(config, client, 4)
    check client.outgoing.len == 1
    check config.playerCount == 3
    check parseConfig(client.outgoing[0].decode().payload).playerCount == 3

  test "Apply Settings acknowledgement clears the explicit map draft":
    var config = defaultConfig(2)
    config.seed = 88
    var state = RosterState(dirty: true, pendingPayload: config.toJson())
    state.acceptConfig(config, config.toJson())
    check not state.pending
    check not state.dirty

  test "local resize adds no relay pending state":
    var config = defaultConfig(2)
    var state: RosterState
    state.resizeRoster(config, nil, 3)
    check config.playerCount == 3
    check config.players.len == 3
    check not state.pending
    check not state.dirty

  test "invalid resize is atomic":
    var (relay, client, config) = lobby()
    var state: RosterState
    expect LvdError:
      state.resizeRoster(config, client, MaxSeats + 1)
    check config.playerCount == 2
    check client.outgoing.len == 0
    check not state.pending
