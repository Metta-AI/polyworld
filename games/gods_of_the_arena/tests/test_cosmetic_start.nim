import std/[unittest, strutils, os]
import jsony
import polyworld/[rooms, roomclients, relays]
import ../[multiplayer, replays]

proc send(relay: Relay, connection: int, message: RoomMessage) =
  relay.receive(connection, decode(message.encode()), 0)

proc lobby(game = "gods_of_the_arena"): Relay =
  result = Relay()
  for i in 1 .. 2:
    result.send(i, RoomMessage(kind: Hello, name: "Human " & $i,
      identity: GameIdentity(game: game, gameplay: 1, protocol: 1)))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Cosmetic ready", number: 10,
    tickRate: 24, payload: parseConfig("{}").toJson()))
  result.send(2, RoomMessage(kind: JoinRoom, room: result.rooms[0].id))
  result.send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
  result.send(2, RoomMessage(kind: ClaimSeat, seat: 8, name: "Human"))

suite "GotA cosmetic ready and authoritative startup":
  test "ready status toggles do not require setup or bless stale preparation":
    let relay = lobby()
    let room = relay.rooms[0]
    for status in [true, false, true, false]:
      relay.send(2, RoomMessage(kind: ReadyStatus, flag: status))
      check relay.guest(2).ready == status
      check room.phase == Lobby
    relay.send(1, RoomMessage(kind: StartMatch, revision: room.revision, hash: 42))
    check room.phase == Playing

  test "only owner can start and stale roster and configuration are rejected":
    let relay = lobby()
    let room = relay.rooms[0]
    expect RoomsError:
      relay.send(2, RoomMessage(kind: StartMatch, revision: room.revision, hash: 42))
    let oldRevision = room.revision
    relay.send(2, RoomMessage(kind: ReleaseSeat, seat: 8))
    expect RoomsError:
      relay.send(1, RoomMessage(kind: StartMatch, revision: oldRevision, hash: 42))
    let rosterRevision = room.revision
    relay.send(1, RoomMessage(kind: ConfigureRoom, name: room.name, number: 10,
      tickRate: 24, payload: "changed"))
    expect RoomsError:
      relay.send(1, RoomMessage(kind: StartMatch, revision: rosterRevision, hash: 42))
    check room.phase == Lobby

  test "zero controllers cannot start":
    let relay = lobby()
    let room = relay.rooms[0]
    relay.send(1, RoomMessage(kind: ReleaseSeat, seat: 1))
    relay.send(2, RoomMessage(kind: ReleaseSeat, seat: 8))
    expect RoomsError:
      relay.send(1, RoomMessage(kind: StartMatch, revision: room.revision, hash: 42))
    check room.phase == Lobby

  test "tick zero mismatch still stops the relay":
    let relay = lobby()
    let room = relay.rooms[0]
    relay.send(1, RoomMessage(kind: StartMatch, revision: room.revision, hash: 42))
    relay.send(2, RoomMessage(kind: ReportHash, match: room.match, tick: 0, hash: 99))
    check room.phase == Desynced

  test "independent initial validation rejects wrong hashes and stale revisions":
    let relay = lobby()
    let room = relay.rooms[0]
    let client = RoomClient(participant: 2, snapshot: relay.state(room))
    for stale in [false, true]:
      let session = prepareNetworkMatch(client, [])
      var begin = RoomMessage(kind: BeginMatch, revision: room.revision,
        hash: session.game.networkHash(), match: 1)
      if stale: dec begin.revision
      else: begin.hash = begin.hash xor 1
      expect RoomsError:
        session.start(begin)
      check not session.started
      check session.game.world.tick == 0
    client.snapshot.payload = "not a config"
    expect CatchableError:
      discard prepareNetworkMatch(client, [])

  test "Generic games and LvD retain their existing ready gate":
    for game in ["generic-ready-test", "light_vs_dark"]:
      let relay = lobby(game)
      expect RoomsError:
        relay.send(1, RoomMessage(kind: StartMatch, revision: relay.rooms[0].revision, hash: 42))
      check relay.rooms[0].phase == Lobby

  test "host frontend startup prepares exact current snapshot without Ready":
    let relay = lobby()
    let room = relay.rooms[0]
    let client = RoomClient(participant: 1, snapshot: relay.state(room))
    let session = client.requestStart([])
    check session.revision == room.revision
    check client.outgoing.len == 1
    let message = decode(client.outgoing[0])
    check message.kind == StartMatch
    check message.revision == room.revision
    check message.hash == session.game.networkHash()
    relay.send(1, message)
    check room.phase == Playing
    let guest = RoomClient(participant: 2, snapshot: relay.state(room))
    expect RoomsError:
      discard guest.requestStart([])

  test "frontend never gates Start or prepares on cosmetic Ready":
    let source = readFile(currentSourcePath().parentDir / "../frontend.nim")
    check "readyToStart" notin source
    check "kind: ReadyStatus, flag: not selfReady" in source
    check "client.requestStart(sources)" in source
    check "client.needsReadyRefresh" notin source
