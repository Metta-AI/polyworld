import std/[unittest, strutils]
import polyworld/[rooms, roomclients]
import ../lobbyreadiness

suite "LvD cosmetic readiness":
  test "toggle never sends packets or changes deterministic preparation":
    var state: ReadyRefresh
    let client = RoomClient(participant: 1, connected: true, welcomed: true,
      snapshot: RoomMessage(room: "ROOM01", phase: Lobby, participant: 1,
        revision: 4, seats: @[Seat(owner: 1, name: "Human")]))
    check not state.cosmeticReady
    for i in 0 ..< 4:
      state.toggleCosmeticReady()
      check state.cosmeticReady == (i mod 2 == 0)
      check client.outgoing.len == 0
      check client.snapshot.revision == 4

  test "frontend starts independent of ready and uses packed human selection":
    let source = readFile("games/light_vs_dark/frontend.nim")
    check "readyRefresh.toggleCosmeticReady()" in source
    check "readyToStart" notin source
    check "prepared.humanPlayerFor(connection.client.participant)" in source
    check "client.send(RoomMessage(kind: Ready," notin source
