## Native simulation transitions, no display/server/browser required.
import std/[monotimes, times]
import vmath
import ../[content, maps, sim, harvestpresentation]

let map = generateMap(DefaultSeed)
let game = newGame(map, TickRate * 180)
let w = game.world
let worker = w.units[0]
var mine = -1
var best = int32.high
for i, building in w.buildings:
  if building.kind == GoldMineBuilding:
    let distance = tileDistance(worker.tile, building.origin)
    if distance < best:
      best = distance
      mine = i
var fx: HarvestPresentation
fx.updateHarvest(w, 0.1, -1)
doAssert fx.siteCount == 0 and fx.particleCount == 0
doAssert w.applyHarvest(worker.owner, worker.id, w.buildings[mine].id, 0)
fx.updateHarvest(w, 0.1, -1)
doAssert worker.state == UnitToMine
doAssert fx.particleCount == 0, "walking to a mine must not emit"
for _ in 0 ..< TickRate * 60:
  w.tickWorld(nil)
  if worker.state == UnitInMine: break
doAssert worker.state == UnitInMine and worker.stateTicks > 0
let before = game.stateHash()
fx.updateHarvest(w, 0.1, -1)
doAssert fx.siteCount == 1 and fx.particleCount > 0,
  "real active mining must emit warm sparks"
doAssert fx.sites[0].kind == MineSparks
doAssert game.stateHash() == before
block nonWorkingMine:
  let saved = worker.stateTicks
  worker.stateTicks = 0
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.particleCount == 0, "waiting to exit is not mining"
  worker.stateTicks = saved
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.particleCount > 0
  let gold = w.buildings[mine].goldLeft
  w.buildings[mine].goldLeft = 0
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.particleCount == 0, "depleted mine emits nothing"
  w.buildings[mine].goldLeft = gold
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.particleCount > 0
  w.buildings[mine].state = BuildingDying
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.particleCount == 0, "destroyed mine emits nothing"
  w.buildings[mine].state = BuildingComplete
for _ in 0 ..< MineTicks + 5:
  w.tickWorld(nil)
  if worker.state != UnitInMine: break
fx.updateHarvest(w, 0.1, -1)
doAssert worker.state != UnitInMine
doAssert fx.particleCount == 0, "last miner exiting must retire every spark"
echo "PASS actual mine walking/working/exiting transitions + state hash"

block wood:
  let game = newGame(map, TickRate * 180)
  let w = game.world
  let worker = w.units[0]
  var tree = -1'i32
  var best = int32.high
  for i, wood in w.treeWood:
    if wood > 0:
      let distance = tileDistance(worker.tile,
        tile2(i.int32 mod map.side, i.int32 div map.side))
      if distance < best:
        tree = i.int32
        best = distance
  var fx: HarvestPresentation
  doAssert w.applyHarvest(worker.owner, worker.id, tree, 1)
  fx.updateHarvest(w, 0.1, -1)
  doAssert worker.state == UnitToTree and fx.particleCount == 0
  for _ in 0 ..< TickRate * 60:
    w.tickWorld(nil)
    if worker.state == UnitChopping: break
  doAssert worker.state == UnitChopping
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.siteCount == 1 and fx.particleCount > 0,
    "real chopping must emit leaves at the tree"
  doAssert fx.sites[0].kind == ChopLeaves
  doAssert fx.sites[0].id == tree
  let before = game.stateHash()
  let frozen = fx
  for _ in 0 ..< 20: fx.updateHarvest(w, 0.1, -1, paused = true)
  doAssert fx.particles == frozen.particles, "pause freezes particles"
  doAssert game.stateHash() == before
  doAssert w.applyCancel(worker.owner, worker.id)
  fx.updateHarvest(w, 0.1, -1, paused = true)
  doAssert fx.particleCount == 0, "stop retires leaves, even paused"
  echo "PASS actual wood walking/chopping/stop + pause + state hash"

block boundedAndFog:
  let game = newGame(map, TickRate * 180)
  let w = game.world
  # Synthetic stress isolates presentation capacity; actual lifecycles above.
  w.units.setLen(0)
  var treeIds: seq[int32]
  for i, wood in w.treeWood:
    if wood > 0:
      treeIds.add i.int32
      if treeIds.len == MaxHarvestSites + 10: break
  for i in 0 ..< 4000:
    let tree = treeIds[i mod treeIds.len]
    let tile = tile2(tree mod map.side, tree div map.side)
    w.units.add Unit(id: (i + 1).int32, owner: 0, hp: 30, kind: PeonUnit,
      state: UnitChopping, stateTicks: ChopTicks, targetTile: tile, tile: tile)
  var fx, repeat: HarvestPresentation
  let hash = game.stateHash()
  let start = getMonoTime()
  for _ in 0 ..< 200:
    fx.updateHarvest(w, 0.016, -1)
    doAssert fx.siteCount == MaxHarvestSites
    doAssert fx.particleCount <= MaxHarvestSites * 5
  let elapsed = (getMonoTime() - start).inMicroseconds
  for _ in 0 ..< 200: repeat.updateHarvest(w, 0.016, -1)
  doAssert repeat.sites == fx.sites and repeat.particles == fx.particles
  doAssert game.stateHash() == hash
  # All workers targeting the same tree share just one pulse/pool.
  for unit in w.units.mitems:
    unit.targetTile = w.units[0].targetTile
    unit.tile = unit.targetTile
  fx.clearHarvest()
  fx.updateHarvest(w, 0.016, -1)
  doAssert fx.siteCount == 1 and fx.particleCount == 5
  var left, right: bool
  for particle in fx.particles:
    if particle.active:
      left = left or particle.velocity.x < 0
      right = right or particle.velocity.x > 0
  doAssert left and right, "leaves scatter in multiple directions"
  let source = fx.sites[0].tilePoint
  # Only the source tile is visible, with explored terrain everywhere else.
  for stamp in w.visibleStamp[0].mitems: stamp = 0
  for explored in w.explored[0].mitems: explored = 1
  let index = w.map.tileIndex(source.x.int32, source.y.int32)
  w.visibleStamp[0][index] = w.visionGeneration[0]
  doAssert w.pointVisible(0, source)
  fx.particles[0].offset.x = 1.1
  fx.updateHarvest(w, 0, 0, paused = true)
  doAssert not fx.particles[0].active, "drifting into fog retires a particle"
  w.visibleStamp[0][index] = 0
  fx.updateHarvest(w, 0, 0, paused = true)
  doAssert fx.siteCount == 0 and fx.particleCount == 0
  fx.updateHarvest(w, 0.1, 0)
  doAssert fx.particleCount == 0, "explored memory must never emit"
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.particleCount == 5, "explicit spectator bypass is separate"
  fx.clearHarvest()
  fx.updateHarvest(w, 0.1, -1, paused = true)
  doAssert fx.particleCount == 0, "paused startup must not spawn"
  echo "PASS fog loss/drift + deterministic pool: 4000 workers, 64 sites, <=320 live; 200 frames us=", elapsed
