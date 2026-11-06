## Packet archive and local replay cursor for seatless network viewers.
## RoomClient.applied is the durable received cursor here, never the playhead.
import polyworld/[rooms, roomclients, mailboxes]
import multiplayer, sim

const SpectatorCheckpointTicks* = 24 * 10

type
  SpectatorCheckpoint = object
    world: World
    inboxes: seq[Mailbox]
  SpectatorStream* = ref object
    session*: NetworkMatch
    packets: seq[RoomMessage]
    checkpoints: seq[SpectatorCheckpoint]

proc capture(stream: SpectatorStream): SpectatorCheckpoint =
  result.world = stream.session.game.world.clone()
  for inbox in stream.session.game.inboxes:
    var copy = Mailbox()
    copy[] = inbox[]
    result.inboxes.add copy

proc newSpectatorStream*(session: NetworkMatch): SpectatorStream =
  if not session.isSpectator or session.game.world.tick != 0:
    reject("Spectator stream requires a seatless initial world")
  result = SpectatorStream(session: session)
  result.checkpoints.add result.capture()

proc receivedEnd*(stream: SpectatorStream): int32 =
  int32(stream.packets.len)

proc receive*(stream: SpectatorStream) =
  ## Drain the bounded network queue even while paused. Only archive ACKs;
  ## no hashes or finish messages may describe an unplayed state.
  var packet: RoomMessage
  while stream.session.client.takeTick(packet):
    if packet.tick != uint32(stream.packets.len + 1):
      reject("Spectator archive received a nonconsecutive tick")
    stream.packets.add packet
    stream.session.client.appliedTick(packet.tick)

proc advance*(stream: SpectatorStream) =
  let game = stream.session.game
  if game.world.tick >= stream.receivedEnd:
    reject("Spectator has no received tick to play")
  stream.session.applyPacket(stream.packets[int(game.world.tick)], localPlayback = true)
  if game.world.tick mod SpectatorCheckpointTicks == 0 and
    stream.checkpoints[^1].world.tick < game.world.tick:
      stream.checkpoints.add stream.capture()

proc restoreTo*(stream: SpectatorStream, target: int32) =
  ## Restore before the target; caller's normal seek loop replays to its target.
  if target < 0 or target > stream.receivedEnd:
    reject("Spectator seek exceeds received history")
  var index = 0
  for i, checkpoint in stream.checkpoints:
    if checkpoint.world.tick > target: break
    index = i
  let game = stream.session.game
  game.world.restore(stream.checkpoints[index].world)
  for i, inbox in stream.checkpoints[index].inboxes:
    game.inboxes[i][] = inbox[]
  game.networkActions.setLen(0)
  game.actionResults.setLen(0)
