import polyworld/[rooms, roomclients, relays]
import ../games/light_vs_dark/participantcontext
import vmath

proc fixture(): RoomClient =
  RoomClient(participant: 11, connected: true, welcomed: true,
    snapshot: RoomMessage(kind: RoomState, room: "room-a", participant: 11,
      phase: Lobby, participants: @[
        Participant(id: 11, name: "Host"), Participant(id: 42, name: "Guest")],
      seats: @[Seat(owner: 11, name: "Human"),
        Seat(owner: 42, name: "Human"), Seat(owner: 42, name: "Base bot")]))

block:
  let client = fixture()
  var menu: ParticipantContext
  menu.openSeat(client, 2, vec2(100, 100))
  doAssert menu.target == 42
  doAssert menu.label(client) == "Remove bot"
  doAssert menu.warning(client) == "Clears only this bot slot; its owner stays in the room."
  doAssert client.outgoing.len == 0 # Right-press only opens, never kicks.
  let item = menu.itemRect(vec2(800, 600))
  let mouse = vec2(item.x + 10, item.y + 10)
  menu.update(client, mouse, vec2(800, 600), leftReleased = true)
  doAssert client.outgoing.len == 0 # A stray release cannot activate.
  menu.update(client, mouse, vec2(800, 600), leftPressed = true)
  menu.update(client, mouse, vec2(800, 600), leftReleased = true)
  doAssert client.outgoing.len == 1
  let packet = decode(client.outgoing[0])
  doAssert packet.kind == ReleaseSeat
  doAssert packet.seat == 2
  doAssert not menu.isOpen

block:
  let client = fixture()
  var menu: ParticipantContext
  for target in [0'u32, 11'u32, 999'u32]:
    menu.openParticipant(client, target, vec2(0))
    doAssert not menu.isOpen
  menu.openSeat(client, 0, vec2(0)) # Self-owned human or bot.
  doAssert not menu.isOpen
  client.snapshot.seats[0].name = "Base bot"
  menu.openSeat(client, 0, vec2(0))
  doAssert menu.isOpen # Host can remove their own bot, but never kick themselves.
  client.snapshot.seats.add Seat()
  menu.openSeat(client, 3, vec2(0))
  doAssert not menu.isOpen
  for seat in [-1, 100]:
    menu.openSeat(client, seat, vec2(0))
    doAssert not menu.isOpen
  client.participant = 42
  menu.openSeat(client, 2, vec2(0))
  doAssert not menu.isOpen # Guests cannot remove even their own bot by context menu.
  menu.openParticipant(client, 11, vec2(0))
  doAssert not menu.isOpen
  client.participant = 11
  for phase in [Playing, Waiting, Ended, Desynced]:
    client.snapshot.phase = phase
    menu.openParticipant(client, 42, vec2(0))
    doAssert not menu.isOpen
  client.snapshot.phase = Lobby
  client.connected = false
  menu.openParticipant(client, 42, vec2(0))
  doAssert not menu.isOpen
  menu.openParticipant(nil, 42, vec2(0))
  doAssert not menu.isOpen
  doAssert client.outgoing.len == 0

block:
  for reason in 0 .. 7:
    let client = fixture()
    var menu: ParticipantContext
    menu.openParticipant(client, 42, vec2(790, 590))
    let item = menu.itemRect(vec2(800, 600))
    let mouse = vec2(item.x + 10, item.y + 10)
    menu.update(client, mouse, vec2(800, 600), leftPressed = true)
    case reason
    of 0: client.snapshot.participants.setLen(1) # Departed.
    of 1: client.snapshot.participant = 42 # Host changed.
    of 2: client.snapshot.phase = Playing
    of 3: client.snapshot.room = "another-room"
    of 4: client.connected = false
    of 5: menu.update(client, mouse, vec2(800, 600), escape = true)
    of 6: menu.update(client, vec2(0), vec2(800, 600), leftPressed = true)
    else: menu.update(client, vec2(0), vec2(800, 600), rightPressed = true)
    menu.update(client, mouse, vec2(800, 600), leftReleased = true)
    doAssert not menu.isOpen
    doAssert client.outgoing.len == 0

block:
  let client = fixture()
  var menu: ParticipantContext
  for point in [vec2(-10), vec2(790, 590)]:
    menu.openParticipant(client, 42, point)
    let panel = menu.bounds(vec2(800, 600))
    doAssert panel.x >= 0 and panel.y >= 0
    doAssert panel.x + panel.w <= 800 and panel.y + panel.h <= 600
  # Reordering seats after opening must not silently retarget another player.
  menu.openSeat(client, 2, vec2(0))
  client.snapshot.seats[2].owner = 11
  let item = menu.itemRect(vec2(800, 600))
  let mouse = vec2(item.x + 10, item.y + 10)
  menu.update(client, mouse, vec2(800, 600), leftPressed = true)
  menu.update(client, mouse, vec2(800, 600), leftReleased = true)
  doAssert client.outgoing.len == 0 # Changed ownership invalidates the target.

block:
  for reason in 0 .. 4:
    let client = fixture()
    var menu: ParticipantContext
    menu.openSeat(client, 2, vec2(0))
    menu.update(client, vec2(20), vec2(800, 600), leftPressed = true)
    case reason
    of 0: client.snapshot.seats.setLen(2)
    of 1: client.snapshot.seats[2].name = "Human"
    of 2: client.snapshot.seats[2].name = "Replacement bot"
    of 3: client.snapshot.seats[2].owner = 0
    else: client.welcomed = false
    menu.update(client, vec2(20), vec2(800, 600), leftReleased = true)
    doAssert not menu.isOpen and client.outgoing.len == 0

block:
  # Exercise the real encoded UI command against an isolated relay, not users.
  let relay = Relay()
  for connection in [1, 2, 3]:
    relay.receive(connection, RoomMessage(kind: Hello,
      identity: GameIdentity(game: "light_vs_dark", gameplay: 1, protocol: 1),
      name: "Player " & $connection), 0)
  let host = relay.guests[0].id
  let target = relay.guests[1].id
  let bystander = relay.guests[2].id
  relay.receive(1, RoomMessage(kind: CreateRoom, name: "Test", number: 4,
    tickRate: 24), 0)
  let room = relay.rooms[0]
  for connection in [2, 3]:
    relay.receive(connection, RoomMessage(kind: JoinRoom, room: room.id), 0)
  for seat in 0 .. 3:
    relay.receive(if seat == 0: 1 elif seat == 3: 3 else: 2,
      RoomMessage(kind: ClaimSeat, seat: uint32(seat),
        name: if seat == 2: "Base bot" else: "Human"), 0)
  let client = RoomClient(participant: host, connected: true, welcomed: true)
  for output in relay.outgoing:
    let packet = decode(output.bytes)
    if output.connection == 1 and packet.kind == RoomState:
      client.snapshot = packet
  var menu: ParticipantContext
  menu.openSeat(client, 2, vec2(0))
  doAssert menu.target == target
  menu.update(client, vec2(20), vec2(800, 600), leftPressed = true)
  menu.update(client, vec2(20), vec2(800, 600), leftReleased = true)
  doAssert client.outgoing.len == 1
  relay.receive(1, decode(client.outgoing[0]), 0)
  doAssert target in room.participants
  doAssert room.seats[1].owner == target and room.seats[2].owner == 0
  doAssert room.seats[0].owner == host and room.seats[3].owner == bystander
  doAssert relay.guest(target).room == room.id
  client.outgoing.setLen(0)
  menu.openSeat(client, 1, vec2(0))
  doAssert menu.label(client) == "Kick player"
  menu.update(client, vec2(20), vec2(800, 600), leftPressed = true)
  menu.update(client, vec2(20), vec2(800, 600), leftReleased = true)
  relay.receive(1, decode(client.outgoing[0]), 0)
  doAssert target notin room.participants
  doAssert room.seats[1].owner == 0

echo "LvD participant context tests passed"
