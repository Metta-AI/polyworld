import std/strutils
let frontend = readFile("games/gods_of_the_arena/frontend.nim")
doAssert "window.buttonPressed[MouseRight]" in frontend
doAssert "lobbySeatBounds(layout, i)" in frontend
doAssert "kickMenu.openSeatContext(snapshot, client.participant, i," in frontend
doAssert "kickMenu.openLocalBot(i, not empty and not human," in frontend
doAssert "kickMenu.contextLabel" in frontend
doAssert "kickMenu.contextCommand(snapshot, client.participant)" in frontend
doAssert "localPolicies[kickMenu.botSeat] = LocalPolicy()" in frontend
doAssert "kickMenu.dismissKick" in frontend
doAssert "not modal and not contextBlocked" in frontend
doAssert "if lobbyUi.selectedSeat >= 0: sk.seatPicker" in frontend
doAssert "Participants" notin frontend and "PARTICIPANTS" notin frontend
doAssert "selectedSeat == -2" notin frontend
doAssert "participantPage" notin frontend
doAssert "kind: KickParticipant" notin frontend,
  "Only the validated context command may kick a participant"
echo "Right-click-only kick/removal routes and no participant modal passed"
