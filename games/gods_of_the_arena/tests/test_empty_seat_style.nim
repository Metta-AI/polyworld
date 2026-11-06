import polyworld/lobbies
import std/strutils
for team in [LobbyRed, LobbyBlue]:
  let empty = seatBackgroundTint(team, true)
  doAssert empty.r == empty.g and empty.g == empty.b,
    "Empty card backgrounds must be neutral gray, not team-colored"
  doAssert empty.r < 160, "Empty cards must be visibly darker"
  doAssert seatBackgroundTint(team, false) == team,
    "Occupied card colors must remain unchanged"
let source = readFile("src/polyworld/lobbies.nim")
doAssert "tint = seatBackgroundTint(tint, empty)" in source
doAssert "if empty: LobbyMuted" in source
echo "Empty seats use gray backgrounds and muted ink; occupied seats retain team colors"
