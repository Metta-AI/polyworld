## Human target intents traverse controls -> wire -> peers -> recorded replay.
import jsony, polyworld/[rooms, roomclients, tapes]
import ../games/light_vs_dark/[multiplayer, presets, sim, replays, content, controls, attackorders]

const Duration = TickRate * 8
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

proc combatFixture(w: World): tuple[selected: seq[int32], enemy: int32] =
  w.diplomacy.pairs[w.diplomacy.pairIndex(0, 1)].state = AtWar
  result.selected = @[w.spawnUnit(0, SoldierUnit, tile2(42, 45)),
    w.spawnUnit(0, PeonUnit, tile2(42, 46))]
  result.enemy = w.spawnUnit(1, PeonUnit, tile2(44, 45))
  w.rebuildVision()

let a = prepareNetworkMatch(clientFor(1), ["", ""])
let b = prepareNetworkMatch(clientFor(2), ["", ""])
let fixture = combatFixture(a.game.world)
doAssert combatFixture(b.game.world) == fixture
let event = RoomMessage(kind: BeginMatch, revision: 2, match: 1,
  hash: a.game.networkHash())
a.start(event)
b.start(event)
let hpBefore = a.game.world.units[a.game.world.unitIndex(fixture.enemy)].hp
var attackActions, stopActions: int
for tick in 1'u32 .. uint32(Duration):
  a.client.outgoing.setLen(0)
  let baseline = a.game.stateHash()
  if tick == 1:
    for id in fixture.selected: queueMove(0, id, 40, 45)
    doAssert a.game.world.queueSelectedAttack(0, fixture.selected, fixture.enemy, append = true)
  elif tick == 2:
    for id in fixture.selected: queueCancel(0, id)
  elif tick == 3:
    doAssert a.game.world.queueSelectedAttack(0, fixture.selected, fixture.enemy)
  a.flushSubmissions()
  doAssert a.game.stateHash() == baseline, "Submission must not mutate authority"
  var commands: seq[Command]
  for bytes in a.client.outgoing:
    let message = decode(bytes)
    if message.kind == SubmitCommand:
      let action = decodeSubmission(message.payload)
      if action.kind == ActionAttack:
        inc attackActions
        doAssert action.first == fixture.enemy
        doAssert action.append == (tick == 1)
      elif action.kind == ActionCancel: inc stopActions
      commands.add Command(participant: 1, seat: message.seat,
        sequence: message.sequence, payload: message.payload)
  let packet = RoomMessage(kind: TickPacket, match: 1, tick: tick, commands: commands)
  a.applyPacket(packet)
  b.applyPacket(packet)
  doAssert a.game.stateHash() == b.game.stateHash()
  if tick == 1:
    for id in fixture.selected:
      let unit = a.game.world.units[a.game.world.unitIndex(id)]
      doAssert unit.orderQueue.len == 1 and unit.orderQueue[0].kind == ActionAttack
  elif tick == 2:
    for id in fixture.selected:
      let unit = a.game.world.units[a.game.world.unitIndex(id)]
      doAssert unit.state == UnitIdle and unit.orderQueue.len == 0
  elif tick == 3:
    for id in fixture.selected:
      doAssert a.game.world.units[a.game.world.unitIndex(id)].targetId == fixture.enemy

doAssert attackActions == 4 and stopActions == 2
doAssert not a.game.world.entityAlive(fixture.enemy) or
  a.game.world.units[a.game.world.unitIndex(fixture.enemy)].hp < hpBefore
let data = decodeReplay(encodeReplay(a.game.recorder.data))
doAssert data.actions.len == 8
let playback = newGame(a.game.world.map, Duration, data.header.setup.diplomacySettings)
doAssert combatFixture(playback.world) == fixture
let cursor = initReplayPlayer(data)
proc replay(w: World) =
  var action: ReplayAction
  while cursor.takeActionAt(uint32(w.tick), action): doAssert w.applyReplayAction(action)
for tick in 0 ..< data.hashes.len:
  playback.world.tickWorld(replay)
  doAssert playback.stateHash() == data.hashes[tick]
echo "LvD explicit attacks and Stop: wire, peer agreement, damage and replay passed"
