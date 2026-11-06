import std/strutils

import ../lobbies
let source = readFile("games/light_vs_dark/lobbies.nim")
doAssert "seatWellTint(empty, tint)" in source
when declared(seatWellTint):
  for seed in [1'i32, 2026'i32]:
    for seat in 0 ..< 8:
      let faction = rosterColor(seed, seat)
      let empty = seatWellTint(true, faction)
      doAssert empty.r == empty.g and empty.g == empty.b
      doAssert seatWellTint(false, faction) == faction
else:
  doAssert false, "Empty wells need a neutral tint helper"
echo "LvD empty card style passed"
