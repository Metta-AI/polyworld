## Ready packets confirm preparation, independently of the cosmetic UI toggle.
import polyworld/[rooms, roomclients], multiplayer

type ReadyRefresh* = object
  room: string
  attemptedRevision: uint32
  cosmeticReady*: bool

proc toggleCosmeticReady*(state: var ReadyRefresh) =
  ## Presentation only: never invalidates a preparation or sends Ready/Unready.
  state.cosmeticReady = not state.cosmeticReady

proc refreshRetainedReady*(state: var ReadyRefresh, client: RoomClient,
    sources: openArray[string], prepared: var NetworkMatch,
    preparedRevision: var uint32): bool =
  ## Pump once after accepting the latest snapshot. Missing private sources
  ## wait without consuming an attempt; preparation errors surface once per
  ## revision. Every occupied controller prepares without a user Ready click.
  if client == nil or client.snapshot.room.len == 0:
    state = ReadyRefresh()
    prepared = nil
    preparedRevision = 0
    return
  let snapshot = client.snapshot
  if state.room != snapshot.room:
    if state.room.len > 0:
      prepared = nil
      preparedRevision = 0
    state = ReadyRefresh(room: snapshot.room)
  if snapshot.phase == Lobby and prepared != nil and prepared.started:
    # A preparation is single-use. Retire it before attempting the rematch,
    # including failures, without clearing room assignments or private sources.
    prepared = nil
    preparedRevision = 0
    state.attemptedRevision = 0
  if not client.connected or not client.welcomed or snapshot.phase != Lobby or
      snapshot.revision == preparedRevision or
      snapshot.revision == state.attemptedRevision:
    return
  var ownsSeat: bool
  if snapshot.seats.len == 0: return
  for i, seat in snapshot.seats:
    if seat.owner == client.participant:
      ownsSeat = true
      if seat.name != "Human" and (i >= sources.len or sources[i].len == 0):
        return
  if not ownsSeat: return
  state.attemptedRevision = snapshot.revision
  let refreshed = prepareNetworkMatch(client, sources)
  client.send(RoomMessage(kind: Ready, revision: snapshot.revision,
    hash: refreshed.game.networkHash()))
  prepared = refreshed
  preparedRevision = snapshot.revision
  result = true
