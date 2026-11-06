## Woodcutting presentation follows a real worker's complete resource cycle.
import ../[content, maps, sim, woodcuttingpresentation]

let game = newGame(generateMap(DefaultSeed), TickRate * 180)
let w = game.world
let worker = w.units[0]
var tree = -1'i32
var best = int32.high
for i, wood in w.treeWood:
  if wood > 0:
    let distance = tileDistance(worker.tile,
      tile2(i.int32 mod w.map.side, i.int32 div w.map.side))
    if distance < best:
      tree = i.int32
      best = distance
let before = game.stateHash()
doAssert not worker.woodAxeVisible
doAssert game.stateHash() == before
doAssert w.applyHarvest(worker.owner, worker.id, tree, 1)
doAssert worker.state == UnitToTree
doAssert worker.woodAxeVisible
doAssert worker.woodAnimationClip("Jog_Fwd_Loop") == "Jog_Fwd_Loop"
for _ in 0 ..< TickRate * 60:
  w.tickWorld(nil)
  if worker.state == UnitChopping: break
doAssert worker.state == UnitChopping
doAssert worker.woodAxeVisible
doAssert worker.woodAnimationClip("Interact") == "Sword_Attack"
doAssert worker.woodAnimationTime(99, 0) == 0
w.tickWorld(nil)
doAssert worker.woodAnimationTime(99, 0) > 0
let hash = game.stateHash()
discard worker.woodAxeVisible
discard worker.woodAnimationTime(99, 0)
doAssert game.stateHash() == hash
for _ in 0 ..< TickRate * 60:
  w.tickWorld(nil)
  if worker.state in {UnitToDropWood, UnitDepositWood}: break
doAssert worker.state in {UnitToDropWood, UnitDepositWood}
doAssert worker.woodAxeVisible
doAssert worker.woodAnimationClip("Jog_Fwd_Loop") == "Jog_Fwd_Loop"
doAssert worker.woodAnimationTime(99, 0) == 99
for _ in 0 ..< TickRate * 60:
  w.tickWorld(nil)
  if worker.state == UnitToTree: break
doAssert worker.state == UnitToTree and worker.woodAxeVisible
doAssert w.applyCancel(worker.owner, worker.id)
doAssert not worker.woodAxeVisible
let soldier = Unit(kind: SoldierUnit, state: UnitChopping, hp: 10)
doAssert not soldier.woodAxeVisible
worker.hp = 0
doAssert not worker.woodAxeVisible
echo "PASS real wood approach/chop/deposit/return/stop"
