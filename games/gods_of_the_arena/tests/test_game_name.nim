import std/strutils
import polyworld/rooms
import ../lobbies
doAssert defaultGameName("mason :)") == "mason :)'s game"
doAssert defaultGameName("空 白 🙂") == "空 白 🙂's game"
var snapshot = RoomMessage(kind: RoomState, phase: Lobby, participant: 1,
  name: "mason :)'s game")
doAssert snapshot.canEditGameName(1)
doAssert not snapshot.canEditGameName(2)
doAssert decode(snapshot.encode()).name == "mason :)'s game"
snapshot.phase = Playing
doAssert not snapshot.canEditGameName(1)
let frontend = readFile("games/gods_of_the_arena/frontend.nim")
doAssert "roomName = defaultGameName(preferences.name)" in frontend
doAssert "kind: ConfigureRoom, name: matchName" in frontend
doAssert "gameName = if online: addr matchName else: nil" in frontend
doAssert "client.snapshot.name == matchName" in frontend
echo "Game name defaults, owner editing and wire roundtrip passed"
