## Read-only type selection, independent of camera position and simulation writes.
import sim

proc matchingUnitIds*(world: World, clicked, owner: int32): seq[int32] =
  ## A negative owner is the existing omniscient spectator selection scope.
  ## Keep the clicked unit first so group selection preserves its primary.
  if world == nil:
    return
  let index = world.unitIndex(clicked)
  if index < 0:
    return
  let target = world.units[index]
  if target.hp <= 0 or target.state in {UnitDying, UnitInMine} or
      (owner >= 0 and target.owner != owner):
    return
  result.add clicked
  for unit in world.units:
    if unit.id != clicked and unit.kind == target.kind and unit.hp > 0 and
        unit.state notin {UnitDying, UnitInMine} and
        (owner < 0 or unit.owner == owner):
      result.add unit.id
