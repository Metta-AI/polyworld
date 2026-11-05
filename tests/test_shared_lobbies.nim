import silky, vmath, windy
import polyworld/[lobbies, menus]
import ../games/gods_of_the_arena/lobbies as gotaLobbies

# Another game can extend shared navigation state without importing GotA maps.
type GameLobbyUi = object of lobbies.LobbyUi
  gameSetting: int

block:
  var ui = GameLobbyUi(gameSetting: 42)
  doAssert ui.selectedSeat == -1
  doAssert ui.selectedBot == "Base bot"
  doAssert ui.scroll == 0
  doAssert not ui.roomListOverflow
  doAssert readinessColor(false) == LobbyRed
  doAssert readinessColor(true) == LobbyGreen
  doAssert gotaLobbies.readinessColor(false) == LobbyRed
  static:
    doAssert compiles(block:
      let sk = Silky()
      let window: Window = nil
      var extended = GameLobbyUi()
      let layout = sk.beginLobby(window, extended, "CUSTOM GAME", true)
      sk.rosterPanel(layout)
      discard sk.seatButton(layout, 0, "Player", "You", true, false, true)
      discard sk.seatPicker(window, extended, [LocalPolicy(name: "Bot")])
      discard sk.lobbyButton("Ready", vec2(0), 190, "status",
        iconTint = readinessColor(true))
      var gota = gotaLobbies.LobbyUi()
      discard sk.beginLobby(window, gota, "GOTA")
    )

echo "Shared lobby compatibility tests passed"
