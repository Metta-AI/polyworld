## Participant-targeted lobby context action, independent of rendering.
import polyworld/[rooms, roomclients]
import bumpy, vmath

type ParticipantContext* = object
  target*: uint32
  botSeat*: int = -1
  botName: string
  room: string
  anchor: Vec2
  armed: bool

proc isOpen*(menu: ParticipantContext): bool = menu.target != 0

proc dismiss*(menu: var ParticipantContext) =
  menu = ParticipantContext()

proc canKick*(client: RoomClient, participant: uint32): bool =
  if client == nil or not client.connected or not client.welcomed or
      client.snapshot.room.len == 0 or client.snapshot.phase != Lobby or
      client.participant == 0 or client.snapshot.participant != client.participant or
      participant == 0 or participant == client.participant:
    return false
  for guest in client.snapshot.participants:
    if guest.id == participant: return true

proc openParticipant*(menu: var ParticipantContext, client: RoomClient,
    participant: uint32, at: Vec2) =
  menu.dismiss()
  if client.canKick(participant):
    menu = ParticipantContext(target: participant, room: client.snapshot.room,
      anchor: at)

proc openSeat*(menu: var ParticipantContext, client: RoomClient, seat: int, at: Vec2) =
  menu.dismiss()
  if client == nil or not client.connected or not client.welcomed or
      client.participant == 0 or client.snapshot.participant != client.participant or
      client.snapshot.phase != Lobby or client.snapshot.room.len == 0 or
      seat notin 0 ..< client.snapshot.seats.len:
    return
  let slot = client.snapshot.seats[seat]
  if slot.name == "Human":
    menu.openParticipant(client, slot.owner, at)
  elif slot.owner != 0:
    menu = ParticipantContext(target: slot.owner, room: client.snapshot.room,
      anchor: at, botSeat: seat, botName: slot.name)

proc valid(menu: ParticipantContext, client: RoomClient): bool =
  if client == nil or not client.connected or not client.welcomed or
      client.participant == 0 or client.snapshot.participant != client.participant or
      client.snapshot.phase != Lobby or client.snapshot.room != menu.room:
    return false
  if menu.botSeat < 0: return client.canKick(menu.target)
  if menu.botSeat >= client.snapshot.seats.len: return false
  let slot = client.snapshot.seats[menu.botSeat]
  slot.owner == menu.target and slot.owner != 0 and
    slot.name == menu.botName and slot.name != "Human"

proc label*(menu: ParticipantContext, client: RoomClient): string =
  if menu.botSeat >= 0: "Remove bot" else: "Kick player"

proc warning*(menu: ParticipantContext, client: RoomClient): string =
  if menu.botSeat >= 0:
    return "Clears only this bot slot; its owner stays in the room."
  var count = 0
  for seat in client.snapshot.seats:
    if seat.owner == menu.target: inc count
  if count > 1: "Removes all " & $count & " seats (including bots)."
  else: "Removes this participant from the room."

proc bounds*(menu: ParticipantContext, view: Vec2): Rect =
  let size = vec2(min(460.0'f, view.x), min(104.0'f, view.y))
  rect(vec2(clamp(menu.anchor.x, 0.0'f, view.x - size.x),
    clamp(menu.anchor.y, 0.0'f, view.y - size.y)), size)

proc itemRect*(menu: ParticipantContext, view: Vec2): Rect =
  let panel = menu.bounds(view)
  rect(panel.xy + vec2(12), vec2(panel.w - 24, 44))

proc update*(menu: var ParticipantContext, client: RoomClient, mouse, view: Vec2,
    leftPressed = false, leftReleased = false, rightPressed = false,
    escape = false) =
  if not menu.isOpen: return
  if not menu.valid(client) or
      escape or rightPressed or
      (leftPressed and not overlaps(mouse, menu.bounds(view))):
    menu.dismiss()
    return
  let inside = overlaps(mouse, menu.itemRect(view))
  if leftPressed: menu.armed = inside
  if leftReleased:
    let activate = menu.armed and inside
    menu.armed = false
    if activate:
      if menu.botSeat >= 0:
        client.send(RoomMessage(kind: ReleaseSeat, seat: uint32(menu.botSeat)))
      else:
        client.send(RoomMessage(kind: KickParticipant, participant: menu.target))
      menu.dismiss()
