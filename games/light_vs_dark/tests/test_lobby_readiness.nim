## Exercise retained readiness through the real relay and LvD preparation.
import std/unittest
import jsony, polyworld/[rooms, relays, roomclients]
import ../[multiplayer, presets, content, lobbyreadiness, rosterstate]

type Fixture = ref object
  relay: Relay
  clients: seq[RoomClient]
  config: LvdConfig

proc exchange(f: Fixture) =
  for iteration in 0 ..< 30:
    var sent = false
    for i, client in f.clients:
      let outgoing = client.outgoing
      client.outgoing = @[]
      for bytes in outgoing:
        f.relay.process(i + 1, bytes, 0)
        sent = true
    let outgoing = f.relay.outgoing
    f.relay.outgoing = @[]
    for output in outgoing:
      if output.bytes.len > 0:
        f.clients[output.connection - 1].accept(output.bytes)
        sent = true
    if not sent: return
  doAssert false, "Relay exchange did not settle"

proc lobby(): Fixture =
  result = Fixture(relay: Relay(), config: defaultConfig(3))
  result.config.maxTicks = 12
  result.config.mapSettings = MapSettings(layout: RandomLayout, size: 90,
    expansions: 0)
  for name in ["Host", "Departing", "Newcomer"]:
    let client = RoomClient(identity: lvdIdentity(), name: name)
    result.clients.add client
    client.opened()
    result.exchange()
  let host = result.clients[0]
  host.send(RoomMessage(kind: CreateRoom, name: "Retained ready", number: 3,
    tickRate: uint32(TickRate), payload: result.config.toJson()))
  result.exchange()
  result.clients[1].send(RoomMessage(kind: JoinRoom, room: host.snapshot.room))
  result.exchange()
  host.claimHumanSeat(0)
  host.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Private bot"))
  result.clients[1].claimHumanSeat(1)
  result.exchange()

proc manualReady(client: RoomClient, sources: openArray[string]): NetworkMatch =
  result = prepareNetworkMatch(client, sources)
  client.send(RoomMessage(kind: Ready, revision: result.revision,
    hash: result.game.networkHash()))

suite "LvD retained readiness":
  test "new controllers automatically prepare without clicking cosmetic Ready":
    let f = lobby()
    let host = f.clients[0]
    var prepared: NetworkMatch
    var revision = 0'u32
    var refresh: ReadyRefresh
    check not f.relay.guest(host.participant).ready
    check refresh.refreshRetainedReady(host,
      ["", "", readFile("games/light_vs_dark/players/base.bas")], prepared, revision)
    require prepared != nil
    check revision == host.snapshot.revision
    f.exchange()
    check f.relay.guest(host.participant).ready

  test "roster resize retains readiness intent without treating it as map settings":
    let f = lobby()
    let host = f.clients[0]
    discard host.manualReady(["", "", readFile("games/light_vs_dark/players/base.bas")])
    discard f.clients[1].manualReady(["", "", ""])
    f.exchange()
    var roster: RosterState
    roster.resizeRoster(f.config, host, 4)
    f.exchange()
    check f.relay.guest(host.participant).ready
    check f.relay.guest(f.clients[1].participant).ready
    check host.snapshot.seats.len == 4

  test "cosmetic toggles preserve prepared object hash revision and relay confirmation":
    let f = lobby()
    let host = f.clients[0]
    let sources = @["", "", readFile("games/light_vs_dark/players/base.bas")]
    var prepared: NetworkMatch
    var revision = 0'u32
    var refresh: ReadyRefresh
    check refresh.refreshRetainedReady(host, sources, prepared, revision)
    f.exchange()
    let original = prepared
    let hash = prepared.game.networkHash()
    let confirmedRevision = revision
    for i in 0 ..< 4:
      refresh.toggleCosmeticReady()
      check not refresh.refreshRetainedReady(host, sources, prepared, revision)
      check host.outgoing.len == 0
      check prepared == original
      check prepared.game.networkHash() == hash
      check revision == confirmedRevision
      check f.relay.guest(host.participant).ready


  test "ResizeRoom cannot disguise map or surviving player changes as roster only":
    for alterName in [false, true]:
      let f = lobby()
      let host = f.clients[0]
      discard host.manualReady(["", "", readFile("games/light_vs_dark/players/base.bas")])
      discard f.clients[1].manualReady(["", "", ""])
      f.exchange()
      var config = f.config
      config.playerCount = 4
      config.players.setLen(4)
      if alterName:
        config.players[0].name = "Changed player"
      else:
        inc config.seed
      host.send(RoomMessage(kind: ResizeRoom, name: host.snapshot.name,
        number: 4, tickRate: host.snapshot.tickRate, payload: config.toJson()))
      f.exchange()
      check not f.relay.guest(host.participant).ready
      check not f.relay.guest(f.clients[1].participant).ready

  test "remaining host refreshes after controller leave/refill without another click":
    let
      f = lobby()
      host = f.clients[0]
      leaving = f.clients[1]
      newcomer = f.clients[2]
      bot = readFile("games/light_vs_dark/players/base.bas")
      hostSources = @["", "", bot]
    var
      prepared = host.manualReady(hostSources)
      preparedRevision = prepared.revision
      refresh: ReadyRefresh
      newcomerRefresh: ReadyRefresh
    discard leaving.manualReady(["", "", "not our private bot"])
    f.exchange()
    let oldHash = prepared.game.networkHash()
    leaving.send(RoomMessage(kind: LeaveRoom))
    f.exchange()
    check f.relay.guest(host.participant).ready
    let vacantRevision = host.snapshot.revision
    check refresh.refreshRetainedReady(host, hostSources, prepared, preparedRevision)
    f.exchange()
    for frame in 0 ..< 5:
      check not refresh.refreshRetainedReady(host, hostSources, prepared, preparedRevision)
      check host.outgoing.len == 0
    check preparedRevision == vacantRevision
    newcomer.send(RoomMessage(kind: JoinRoom, room: host.snapshot.room))
    f.exchange()
    newcomer.claimHumanSeat(1)
    f.exchange()
    check f.relay.guest(host.participant).ready
    check not f.relay.guest(newcomer.participant).ready
    # Start queues intent, but stale preparation cannot bypass hash safety.
    host.send(RoomMessage(kind: StartMatch))
    f.exchange()
    check host.snapshot.phase == Lobby
    check host.error == ""
    check refresh.refreshRetainedReady(host, hostSources, prepared, preparedRevision)
    check preparedRevision == host.snapshot.revision
    check prepared.game.networkHash() != oldHash
    require host.outgoing.len == 1
    let confirmation = decode(host.outgoing[0])
    check confirmation.kind == Ready
    check confirmation.revision == host.snapshot.revision
    check confirmation.hash == prepared.game.networkHash()
    for frame in 0 ..< 5:
      check not refresh.refreshRetainedReady(host, hostSources, prepared, preparedRevision)
      check host.outgoing.len == 1
    f.exchange()
    var
      newPrepared: NetworkMatch
      newRevision = 0'u32
    check newcomerRefresh.refreshRetainedReady(newcomer, ["", "", ""],
      newPrepared, newRevision)
    check newPrepared != nil
    check not f.relay.guest(newcomer.participant).ready
    f.exchange()
    check newPrepared.game.networkHash() == prepared.game.networkHash()
    check host.error == ""
    check host.snapshot.phase == Playing
    check newcomer.snapshot.phase == Playing
    require host.events.len == 1
    prepared.start(host.events[0])
    newPrepared.start(newcomer.events[0])
    check prepared.started
    check newPrepared.started

  test "a late retained peer refresh queues Start until its current hash arrives":
    let
      f = lobby()
      host = f.clients[0]
      peer = f.clients[1]
      sources = @["", "", readFile("games/light_vs_dark/players/base.bas")]
    var
      hostPrepared = host.manualReady(sources)
      peerPrepared = peer.manualReady(["", "", ""])
      hostRevision = hostPrepared.revision
      peerRevision = peerPrepared.revision
      hostRefresh, peerRefresh: ReadyRefresh
    f.exchange()
    host.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Renamed bot"))
    f.exchange()
    check hostRefresh.refreshRetainedReady(host, sources, hostPrepared, hostRevision)
    f.exchange()
    host.send(RoomMessage(kind: StartMatch))
    f.exchange()
    check host.snapshot.phase == Lobby
    check host.error == ""
    check peerRefresh.refreshRetainedReady(peer, [], peerPrepared, peerRevision)
    f.exchange()
    check hostPrepared.game.networkHash() == peerPrepared.game.networkHash()
    check host.error == ""
    check host.snapshot.phase == Playing

  test "configuration edits automatically confirm a newly prepared current hash":
    let
      f = lobby()
      host = f.clients[0]
      sources = @["", "", readFile("games/light_vs_dark/players/base.bas")]
    var
      prepared = host.manualReady(sources)
      revision = prepared.revision
      refresh: ReadyRefresh
    discard f.clients[1].manualReady(["", "", ""])
    f.exchange()
    inc f.config.seed
    host.send(RoomMessage(kind: ConfigureRoom, name: host.snapshot.name,
      number: 3, tickRate: uint32(TickRate), payload: f.config.toJson()))
    f.exchange()
    check not f.relay.guest(host.participant).ready
    check refresh.refreshRetainedReady(host, sources, prepared, revision)
    for frame in 0 ..< 5:
      check not refresh.refreshRetainedReady(host, sources, prepared, revision)
    check host.outgoing.len == 1
    check revision == host.snapshot.revision
    discard f.clients[1].manualReady(["", "", ""])
    f.exchange()
    host.send(RoomMessage(kind: StartMatch))
    f.exchange()
    check host.snapshot.phase == Playing

  test "missing private sources wait and failed preparation is bounded per revision":
    let
      f = lobby()
      host = f.clients[0]
      bot = readFile("games/light_vs_dark/players/base.bas")
    var
      prepared = host.manualReady(["", "", bot])
      revision = prepared.revision
      refresh: ReadyRefresh
    f.exchange()
    host.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Renamed bot"))
    f.exchange()
    check not refresh.refreshRetainedReady(host, ["", "", ""], prepared, revision)
    check host.outgoing.len == 0
    check refresh.refreshRetainedReady(host, ["", "", bot], prepared, revision)
    f.exchange()
    host.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Broken private bot"))
    f.exchange()
    let goodRevision = revision
    var failures = 0
    for frame in 0 ..< 5:
      try:
        discard refresh.refreshRetainedReady(host, ["", "", "this is not BASIC !!!"],
          prepared, revision)
      except CatchableError:
        inc failures
    check failures == 1
    check revision == goodRevision
    check host.outgoing.len == 0
    # A new roster revision can retry; a successful attempt cannot send twice.
    host.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Repaired bot"))
    f.exchange()
    check refresh.refreshRetainedReady(host, ["", "", bot], prepared, revision)
    check not refresh.refreshRetainedReady(host, ["", "", bot], prepared, revision)

  test "exit resets preparation and room-scoped retry latch":
    let
      f = lobby()
      host = f.clients[0]
      bot = readFile("games/light_vs_dark/players/base.bas")
    var
      prepared = host.manualReady(["", "", bot])
      revision = prepared.revision
      refresh: ReadyRefresh
    f.exchange()
    host.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Renamed bot"))
    f.exchange()
    check refresh.refreshRetainedReady(host, ["", "", bot], prepared, revision)
    f.exchange()
    host.send(RoomMessage(kind: LeaveRoom))
    f.exchange()
    check not refresh.refreshRetainedReady(host, [], prepared, revision)
    check prepared == nil
    check revision == 0

  test "room changes cannot reuse a matching numeric prepared revision":
    let
      f = lobby()
      host = f.clients[0]
      bot = readFile("games/light_vs_dark/players/base.bas")
    var
      prepared = host.manualReady(["", "", bot])
      revision = prepared.revision
      refresh: ReadyRefresh
    f.exchange()
    check not refresh.refreshRetainedReady(host, ["", "", bot], prepared, revision)
    # Emulate consecutive snapshots coalesced by a transport pump: no empty
    # room frame between exiting and joining a different lobby.
    host.snapshot.room = "different-room"
    check refresh.refreshRetainedReady(host, ["", "", bot], prepared, revision)
    check host.outgoing.len == 1
