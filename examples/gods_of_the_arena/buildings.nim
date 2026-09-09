import
  std/math,
  vmath,
  polyworld/[common, pathing],
  maps

const
  GodModels* = [
    DataRoot & "/characters/mini_legion/human/footman.glb",
    DataRoot & "/characters/mini_legion/undead/skeleton_warrior.glb"
  ]
  TowerModels* = [
    "tower_square_small1", "tower_square_tall1", "tower_square_tall2"
  ]
  TowerScales* = [3.5'f, 4.5'f, 6.0'f]

proc buildingPosition*(building: MapBuilding): Vec3 =
  ## Places a structure at the center of its chosen terrain tile.
  let stop = building.buildingStop()
  tileCenter(stop.layer, stop.x, stop.z)

proc buildingRotation*(building: MapBuilding): float32 =
  ## Converts the saved clockwise angle into the renderer's radians.
  building.rotation.float32 * PI.float32 / 180

proc buildingModel*(building: MapBuilding): string =
  ## Chooses the same structure asset for the editor and game.
  case building.kind
  of TowerBuilding:
    TowerModels[building.tier]
  of BarracksBuilding:
    "building2"
  of GodBuilding:
    "magiccrystal1"

proc buildingScale*(building: MapBuilding): float32 =
  ## Returns the shared model scale for a placed structure.
  case building.kind
  of TowerBuilding:
    TowerScales[building.tier]
  of BarracksBuilding:
    2.25'f
  of GodBuilding:
    3.375'f

proc buildingLayerAt*(x, z: int): int =
  ## Chooses the highest existing surface beneath a building placement.
  var highest = int.low
  for i, layer in layers:
    if layer.water or layer.blocking:
      continue
    let
      localX = x - layer.originX
      localZ = z - layer.originZ
    if localX < 0 or localZ < 0 or localX >= layer.width or
      localZ >= layer.depth:
        continue
    let tile = layer.tiles[localZ * layer.width + localX]
    if tile.exists and tile.tops[0].int > highest:
      highest = tile.tops[0].int
      result = i
