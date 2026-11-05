## Ownership-checked human attack-move intents, independent of graphics.
import content, controls, maps, sim

proc canAttackMove(world: World, player, id: int32): bool =
  if world == nil or player < 0 or player >= world.players.len:
    return false
  let index = world.unitIndex(id)
  if index < 0:
    return false
  let unit = world.units[index]
  let stats = unitOf(player, unit.kind)
  unit.owner == player and (stats.basic > 0 or stats.piercing > 0) and unit.hp > 0 and
    unit.state notin {UnitDying, UnitInMine}

proc hasSelectedMilitary*(world: World, player: int32,
    selected: openArray[int32]): bool =
  ## Historical API name: workers with combat stats are eligible too.
  for id in selected:
    if world.canAttackMove(player, id):
      return true

proc queueSelectedAttackMove*(world: World, player: int32,
    selected: openArray[int32], x, y: int32, append = false): bool =
  ## Queues combat-capable units without changing selection or immediate sim state.
  ## The normal command flush applies/records them, or submits them online.
  ## Returns false for invalid terrain or a selection without eligible units.
  if world == nil or not world.map.inGrid(x, y) or not world.terrainOpen(x, y):
    return false
  for id in selected:
    if world.canAttackMove(player, id):
      queueAttackMove(player, id, x, y, append = append)
      result = true

proc armSelectedAttackMove*(world: World, player: int32,
    selected: openArray[int32]): bool =
  ## A arms an eligible selection and replaces a pending build placement.
  attackMoveArmed = world.hasSelectedMilitary(player, selected)
  if attackMoveArmed:
    pendingBuild = -1
  attackMoveArmed

proc queueSelectedAttack*(world: World, player: int32,
    selected: openArray[int32], target: int32, append = false): bool =
  ## Armed primary and contextual clicks share ownership/visibility/war rules.
  ## Simulation validates again when the command is committed.
  if world == nil or player < 0 or player >= world.players.len or
      not world.entityAlive(target):
    return false
  if target.isUnitId:
    let index = world.unitIndex(target)
    if world.units[index].hp <= 0 or
        not world.atWar(player, world.units[index].owner) or
        not world.unitVisible(player, index): return false
  elif target.isBuildingId:
    let structure = world.buildings[world.buildingIndex(target)]
    if structure.hp <= 0 or not world.atWar(player, structure.owner) or
        not world.buildingVisible(player, structure): return false
  else:
    return false
  for id in selected:
    if world.canAttackMove(player, id):
      queueAttack(player, id, target, append = append)
      result = true

proc queueArmedAttackMove*(world: World, player: int32,
    selected: openArray[int32], x, y: int32, append = false): bool =
  ## Invalid destinations keep targeting armed; accepted orders consume it.
  if attackMoveArmed and world.queueSelectedAttackMove(player, selected, x, y, append = append):
    attackMoveArmed = false
    result = true
