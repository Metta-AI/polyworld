import std/strutils
import polyworld/[rooms, relays]

let frontend = readFile("games/light_vs_dark/frontend.nim")
doAssert "humanSeat = -1" in frontend
doAssert "for policy in localPolicies.mitems:" notin frontend
doAssert "localPolicies[i] = base" notin frontend
doAssert "localPolicies.add base" notin frontend
# Creating a room has no implicit player/bot assignment, independent of local setup.
let relay = Relay()
relay.receive(1, RoomMessage(kind: Hello, name: "空 白 :)",
  identity: GameIdentity(game: "lvd-defaults", gameplay: 1, protocol: 1)), 0)
relay.receive(1, RoomMessage(kind: CreateRoom, name: "空 白 :)'s game",
  number: 4, tickRate: 24), 0)
for seat in relay.rooms[0].seats:
  doAssert seat.owner == 0
let createRoute = frontend[frontend.find("kind: CreateRoom") .. frontend.find("of SingleMenu, LobbyMenu:")]
doAssert "ClaimSeat" notin createRoute
echo "LvD empty lobby defaults passed"
