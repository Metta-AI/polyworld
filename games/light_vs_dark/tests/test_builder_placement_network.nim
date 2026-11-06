## Real queued submission -> authoritative packets -> two worlds -> saved replay.
## In-process transport, not a live socket/browser acceptance test.
import jsony, polyworld/[rooms, roomclients, tapes]
import ../[multiplayer, presets, sim, replays, content, controls]

const Duration = TickRate * 30
proc clientFor(id: uint32): RoomClient =
  var config = defaultConfig(2)
  config.maxTicks = Duration
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  result = RoomClient(identity: lvdIdentity(), participant: id, match: 1,
    began: true, welcomed: true)
  result.snapshot = RoomMessage(kind: RoomState, revision: 2, phase: Playing,
    tickRate: uint32(TickRate), payload: config.toJson(), seats: @[
      Seat(owner: 1, name: "Human"), Seat(owner: 2, name: "Human")], participants: @[
      Participant(id: 1, name: "Alice"), Participant(id: 2, name: "Bob")])

clearPlayerCommands()
let a = prepareNetworkMatch(clientFor(1), ["", ""])
let b = prepareNetworkMatch(clientFor(2), ["", ""])
let event = RoomMessage(kind: BeginMatch, revision: 2, match: 1,
  hash: a.game.networkHash())
a.start(event)
b.start(event)
let w = a.game.world
var worker: Unit
var origin = NoTile
let size = BuildingTable[FarmBuilding].footprint
for unit in w.units:
  if unit.owner != 0: continue
  for y in unit.tile.y.int32 - size.depth + 1 .. unit.tile.y.int32:
    for x in unit.tile.x.int32 - size.width + 1 .. unit.tile.x.int32:
      if w.canPlace(0, FarmBuilding, x, y, unit.id):
        worker = unit
        origin = tile2(x, y)
        break
    if worker != nil: break
  if worker != nil: break
doAssert worker != nil, "Fresh generated map must offer a farm over an opening peon"
doAssert w.canBuild(0, FarmBuilding)
doAssert not w.canPlace(FarmBuilding, origin.x.int32, origin.y.int32)
let baseline = a.game.stateHash()
queueBuild(0, worker.id, FarmBuilding.ord.int32, origin.x.int32, origin.y.int32)
a.flushSubmissions()
doAssert a.game.stateHash() == baseline, "Submission cannot mutate local authority"
var commands: seq[Command]
for bytes in a.client.outgoing:
  let message = decode(bytes)
  if message.kind == SubmitCommand:
    commands.add Command(participant: 1, seat: message.seat,
      sequence: message.sequence, payload: message.payload)
doAssert commands.len == 1
var siteId = NoEntity
var snapshot: World
for tick in 1'u32 .. uint32(Duration):
  let packet = RoomMessage(kind: TickPacket, match: 1, tick: tick,
    commands: (if tick == 1: commands else: @[]))
  a.applyPacket(packet)
  b.applyPacket(packet)
  doAssert a.game.stateHash() == b.game.stateHash()
  if tick == uint32(DecisionTicks):
    for site in w.buildings:
      if site.kind == FarmBuilding and site.origin == origin: siteId = site.id
    doAssert siteId != NoEntity
    doAssert worker.state == UnitBuilding
    doAssert worker.constructionSiteId == siteId
    doAssert constructionInRange(w.buildings[w.buildingIndex(siteId)], worker)
    snapshot = w.clone()
    let changed = w.clone()
    changed.units[changed.unitIndex(worker.id)].constructionSiteId = NoEntity
    doAssert Game(world: changed).stateHash() != a.game.stateHash(), "Occupant lifecycle is hashed"
  elif snapshot != nil:
    snapshot.tickWorld(nil)
    doAssert Game(world: snapshot).stateHash() == a.game.stateHash(), "Clone must retain occupant state"
doAssert w.buildings[w.buildingIndex(siteId)].state == BuildingComplete
doAssert w.tileOpen(worker.tile)
doAssert worker.constructionSiteId == NoEntity
let data = decodeReplay(encodeReplay(a.game.recorder.data))
doAssert data.actions.len == 1 and data.actions[0].kind == ActionBuild
let playback = newGame(w.map, Duration, data.header.setup.diplomacySettings)
let cursor = initReplayPlayer(data)
proc replay(world: World) =
  var action: ReplayAction
  while cursor.takeActionAt(uint32(world.tick), action):
    doAssert world.applyReplayAction(action)
for tick in 0 ..< data.hashes.len:
  playback.world.tickWorld(replay)
  doAssert playback.stateHash() == data.hashes[tick]
doAssert ReplayGameVersion >= 28
var old = data
old.header.gameVersion = 27
var refused = false
try: old.validate()
except ReplayError: refused = true
doAssert refused, "Version 27 construction requires its archived client"
echo "LvD own-builder placement: peer, clone, and serialized replay hashes matched"
