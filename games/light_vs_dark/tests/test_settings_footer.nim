import std/strutils
import vmath
import ../lobbies
let source = readFile("games/light_vs_dark/lobbies.nim")
doAssert "settingsFooter(at, height)" in source
when declared(settingsFooter):
  for origin in [vec2(982, 150), vec2(32, 950), vec2(32, -400)]:
    for height in [740'f, 820'f, 1100'f]:
      let footer = settingsFooter(origin, height)
      for point in [footer.map, footer.advanced]:
        doAssert point.y >= origin.y
        doAssert point.y + 44 <= origin.y + height
else:
  doAssert false, "Missing panel-anchored settings footer"
doAssert "\"Map generation\"" in source
doAssert "\"Advanced settings\"" in source
echo "LvD settings footer stays within panel bounds"
