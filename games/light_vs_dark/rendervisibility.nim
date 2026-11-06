## LvD presentation visibility keeps owned entities and map resources visible.
## View 0 is the existing designated omniscient spectator/replay view;
## positive views are one-based players. These queries never rebuild vision.
import std/math
import content, maps, sim

type RenderVisibilityMask* = enum
  CurrentSightMask, TerrainMemoryMask

proc renderTileVisible*(world: World, viewMode, x, y: int32): bool =
  world.map.inGrid(x, y) and
    (viewMode == 0 or world.visible(viewMode - 1, x, y))

proc renderAreaVisible*(world: World, viewMode: int32,
    x, y, radius: float32): bool =
  ## Conservative world-tile bounds for effect quads/cylinders.
  for row in int32(floor(y-radius)) .. int32(floor(y+radius)):
    for col in int32(floor(x-radius)) .. int32(floor(x+radius)):
      if not world.renderTileVisible(viewMode, col, row): return false
  true

proc renderUnitVisible*(world: World, viewMode: int32, unit: Unit): bool =
  ## Keeps owned units whole while hiding unseen enemy units.
  unit.state != UnitInMine and viewMode in 0 .. world.players.len.int32 and
    (viewMode == 0 or unit.owner == viewMode - 1 or
      world.renderTileVisible(viewMode, unit.tile.x.int32, unit.tile.y.int32))

proc renderBuildingVisible*(world: World, viewMode: int32,
    building: Building): bool =
  ## Reveals the whole building when any footprint tile is visible.
  if viewMode notin 0 .. world.players.len.int32:
    return false
  if building.kind == GoldMineBuilding or building.owner == viewMode - 1:
    return true
  for y in building.origin.y.int32 ..<
      building.origin.y.int32 + building.footprint.depth:
    for x in building.origin.x.int32 ..<
        building.origin.x.int32 + building.footprint.width:
      if world.renderTileVisible(viewMode, x, y): return true

proc renderVisibilityValues*(world: World, viewMode: int32,
    mode: RenderVisibilityMask): seq[uint8] =
  ## Exact row-major cells: NEVER blur CurrentSightMask or linearly sample it.
  ## Ground may blur TerrainMemoryMask separately; props/effects may not.
  result = newSeq[uint8](world.map.side * world.map.side)
  for y in 0'i32 ..< world.map.side:
    for x in 0'i32 ..< world.map.side:
      result[world.map.tileIndex(x, y)] =
        if world.renderTileVisible(viewMode, x, y): 255'u8
        elif mode == TerrainMemoryMask and world.explored(viewMode - 1, x, y): 48'u8
        else: 0'u8
