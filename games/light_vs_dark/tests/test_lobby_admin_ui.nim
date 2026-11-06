import std/strutils
let frontend = readFile("games/light_vs_dark/frontend.nim")
let lobbies = readFile("games/light_vs_dark/lobbies.nim")
doAssert "Participants" notin frontend and "PARTICIPANTS" notin frontend
doAssert "selectedSeat == -2" notin frontend
proc indentation(line: string): int = line.len - line.strip(leading = true, trailing = false).len
proc guarded(text, marker, guard: string): bool =
  let lines = text.splitLines()
  for i, line in lines:
    if marker in line:
      var level = indentation(line)
      for j in countdown(i - 1, 0):
        if lines[j].strip.len == 0: continue
        if indentation(lines[j]) < level:
          if guard in lines[j]: return true
          level = indentation(lines[j])
      return false
for marker in ["\"Add player\", rosterAt", "\"Remove last\"", "\"Fill empty slots\"", "\"Shuffle players\""]:
  doAssert frontend.guarded(marker, "if owner:")
doAssert "Shuffle mine" notin frontend
doAssert "Host-owned slots only" in frontend
let onlineStart = frontend[frontend.find("if roster.dirty and owner") .. frontend.find("if sk.lobbyButton(\n              if owner")]
doAssert "elif owner:" in onlineStart
doAssert "showControls = owner" in frontend
doAssert "if showControls:" in lobbies
doAssert "participantMenu.openSeat(client, i, sk.mousePos)" in frontend
doAssert "rosterCardHit(layout, i, rosterScroll.scrollPos.y, sk.mousePos)" in frontend
doAssert "leftPressed = window.buttonPressed[MouseLeft]" in frontend
doAssert "leftReleased = window.buttonReleased[MouseLeft]" in frontend
doAssert "contextDismissGuard = contextBlocked and window.buttonDown[MouseLeft]" in frontend
doAssert frontend.find("sk.popClipRect()", frontend.find("of SingleMenu, LobbyMenu:")) < frontend.find("if participantMenu.isOpen:")
echo "LvD host controls and removed modal route guards passed"
