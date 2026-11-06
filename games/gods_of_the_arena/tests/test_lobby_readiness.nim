import silky, vmath
import ../lobbies

# Buttons accept a separate status color without changing the normal ink API.
static:
  doAssert compiles(block:
    let sk = Silky()
    discard sk.lobbyButton("Ready up", vec2(0), 190, "status",
      iconTint = readinessColor(false))
    discard sk.lobbyButton("Ready", vec2(0), 190, "status",
      enabled = false, iconTint = readinessColor(true))
    discard sk.lobbyButton("Normal", vec2(0), 190, "status")
  )

# Readiness must remain explicit rather than using the neutral icon color.
doAssert readinessColor(false) == LobbyRed
doAssert readinessColor(true) == LobbyGreen
doAssert readinessColor(false) != readinessColor(true)
echo "Lobby readiness colors passed"
