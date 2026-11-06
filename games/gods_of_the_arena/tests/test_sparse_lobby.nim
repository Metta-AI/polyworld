import polyworld/[rooms, roomclients, menus]
import ../multiplayer

var policies: array[10, LocalPolicy]
let seats = localActiveSeats(policies, 3)
doAssert seats == @[3], "Default local slots are empty, preserving assigned human"
policies[8] = LocalPolicy(name: "Bot", bytes: "END")
doAssert localActiveSeats(policies, 3) == @[3, 8]
doAssert localActiveSeats(policies, -1) == @[8]
var snapshot = RoomMessage(revision: 2, phase: Lobby, participant: 1,
  seats: newSeq[Seat](10), participants: @[
    Participant(id: 1, ready: true, connected: true),
    Participant(id: 2, connected: true)])
snapshot.seats[3] = Seat(owner: 1, name: "Human")
let client = RoomClient(participant: 1, snapshot: snapshot)
doAssert client.snapshot.controllersReady()
doAssert client.needsReadyRefresh(1)
doAssert not client.needsReadyRefresh(2)
snapshot.seats[8] = Seat(owner: 2, name: "Human")
doAssert not snapshot.controllersReady(), "New nonready controller blocks start"
client.snapshot = snapshot
client.participant = 2
doAssert not client.needsReadyRefresh(1), "Consent must never be automatic"
client.participant = 3
doAssert not client.needsReadyRefresh(1), "Spectators never ready"
echo "Sparse lobby readiness and local defaults passed"
