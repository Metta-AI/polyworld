## Short-lived, game-owned target feedback. Never changes authoritative state.
import vmath
import polyworld/clickmarks
import content, sim, controls, attackorders, orderfeedback

type
  TargetFlashKind* = enum
    NoTargetFlash, HarvestTreeFlash, HarvestEntityFlash, AttackEntityFlash
  TargetFeedback* = object
    kind*: TargetFlashKind
    target*, player*: int32
    remaining*: float32

proc flashTarget*(feedback: var TargetFeedback, kind: TargetFlashKind,
    target, player: int32) =
  feedback = TargetFeedback(kind: kind, target: target, player: player,
    remaining: ClickMarkDuration)

proc advanceTargetFeedback*(feedback: var TargetFeedback, dt: float32) =
  feedback.remaining = max(0'f32, feedback.remaining - max(0'f32, dt))
  if feedback.remaining <= 0: feedback = TargetFeedback()

proc targetFlashVisible*(feedback: TargetFeedback, world: World): bool =
  ## Keeps resource orders visible; enemy targets still require current sight.
  if world == nil or feedback.kind == NoTargetFlash or feedback.remaining <= 0:
    return false
  let target = feedback.target
  if feedback.kind == HarvestTreeFlash:
    return target >= 0 and target < world.treeWood.len and
      world.treeWood[target] > 0
  if world.hasUnit(target):
    let unit = world.units[world.unitIndex(target)]
    return unit.hp > 0 and unit.state notin {UnitDying, UnitInMine} and
      world.unitVisible(feedback.player, unit)
  if world.hasBuilding(target):
    let structure = world.buildings[world.buildingIndex(target)]
    return structure.hp > 0 and structure.state != BuildingDying and
      (structure.kind == GoldMineBuilding or
        world.buildingVisible(feedback.player, structure)) and
      (feedback.kind != HarvestEntityFlash or structure.kind != GoldMineBuilding or structure.goldLeft > 0)

proc targetFlashColor*(feedback: TargetFeedback): Vec3 =
  let color = orderFeedbackColor(feedback.kind == AttackEntityFlash)
  vec3(color.r.float32, color.g.float32, color.b.float32) / 255'f32

proc targetOrderUnits(world: World, player: int32, selected: openArray[int32],
    append: bool): seq[int32] =
  for id in selected:
    if not world.hasUnit(id): continue
    let unit = world.units[world.unitIndex(id)]
    if unit.owner != player or unit.hp <= 0 or unit.state == UnitDying or
        (not append and unit.state == UnitInMine) or
        (append and unit.orderQueue.len >= MaxUnitOrders): continue
    result.add id

proc queueFeedbackAttack*(world: World, player: int32, selected: openArray[int32],
    target: int32, append = false): bool =
  ## Existing attack validator and ordinary command queue, plus FIFO capacity.
  world.queueSelectedAttack(player, world.targetOrderUnits(player, selected, append),
    target, append)

proc queueFeedbackHarvest*(world: World, player: int32, selected: openArray[int32],
    target: int32, tree: bool, append = false): bool =
  let candidate = TargetFeedback(kind: (if tree: HarvestTreeFlash else: HarvestEntityFlash),
    target: target, player: player, remaining: ClickMarkDuration)
  if not candidate.targetFlashVisible(world): return false
  for id in world.targetOrderUnits(player, selected, append):
    if world.units[world.unitIndex(id)].kind == PeonUnit:
      queueHarvest(player, id, target, tree.int32, append = append)
      result = true
