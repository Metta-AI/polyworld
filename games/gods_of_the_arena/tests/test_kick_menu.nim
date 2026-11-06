import vmath
import polyworld/rooms
import ../lobbies
var snapshot = RoomMessage(room: "room-a", phase: Lobby, participant: 1,
  seats: @[Seat(owner: 2, name: "Human"), Seat(owner: 1, name: "Human"),
    Seat(owner: 2, name: "Base bot"), Seat(owner: 1, name: "Base bot"), Seat()],
  participants: @[Participant(id: 1), Participant(id: 2), Participant(id: 3)])
var menu: KickMenu
doAssert menu.openSeatContext(snapshot, 1, 0, vec2(40, 50))
doAssert menu.contextLabel == "Kick player"
doAssert menu.contextCommand(snapshot, 1).kind == KickParticipant
doAssert menu.contextCommand(snapshot, 1).participant == 2
menu.dismissKick(vec2(45, 55), false, true)
doAssert menu.target == 2
menu.dismissKick(vec2(800, 800), false, true)
doAssert menu.target == 0
doAssert not menu.openSeatContext(snapshot, 2, 1, vec2(0))
doAssert not menu.openSeatContext(snapshot, 1, 1, vec2(0))
doAssert not menu.openSeatContext(snapshot, 1, 4, vec2(0))
# Host clears just the selected guest bot, retaining owner identity validation.
doAssert menu.openSeatContext(snapshot, 1, 2, vec2(0))
doAssert menu.contextLabel == "Remove bot"
let command = menu.contextCommand(snapshot, 1)
doAssert command.kind == ReleaseSeat and command.seat == 2
doAssert command.participant == 0
doAssert not menu.canUseContext(snapshot, 3)
var changed = snapshot
changed.seats[2].owner = 3
doAssert not menu.canUseContext(changed, 1)
changed = snapshot
changed.seats[2].name = "Human"
doAssert not menu.canUseContext(changed, 1)
changed = snapshot
changed.room = "room-b"
doAssert not menu.canUseContext(changed, 1)
# Only the host may open a removal context, even for a guest's own bot.
doAssert not menu.openSeatContext(snapshot, 2, 2, vec2(0))
doAssert menu.target == 0
doAssert not menu.openSeatContext(snapshot, 3, 2, vec2(0))
# A stale host menu cannot issue a command after ownership changes.
doAssert menu.openSeatContext(snapshot, 1, 2, vec2(0))
changed = snapshot
changed.participant = 3
doAssert not menu.canUseContext(changed, 1)
var rejected = false
try:
  discard menu.contextCommand(changed, 1)
except AssertionDefect:
  rejected = true
doAssert rejected, "Unauthorized removal must not produce a relay command"
doAssert menu.openSeatContext(snapshot, 1, 3, vec2(0))
menu.dismissKick(vec2(0), true, false)
doAssert menu.target == 0
snapshot.phase = Playing
doAssert not menu.openSeatContext(snapshot, 1, 2, vec2(0))
doAssert menu.openLocalBot(3, true, vec2(0))
doAssert menu.local and menu.botSeat == 3 and menu.contextLabel == "Remove bot"
doAssert not menu.openLocalBot(3, false, vec2(0))
echo "Human kick and single-bot context actions passed"
