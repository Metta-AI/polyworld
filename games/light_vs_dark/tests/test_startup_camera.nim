## Startup framing must reveal the human's spawn without enabling follow mode.
import std/unittest
import fixxy, vmath
import polyworld/pathing
import ../[content, maps, sim, graphics]

suite "LvD startup camera":
  test "a noncentral human selection starts in view":
    let world = newWorld(generateMap(47, 3), 100)
    var selected: Unit
    for unit in world.units:
      if unit.owner == 1:
        selected = unit
        break
    let
      half = world.map.side.float32 / 2
      x = toFloat32(selected.body.pos.x) - half
      z = toFloat32(selected.body.pos.y) - half
      expected = vec3(x, surfaceHeight(x, z), z)
    check abs(x) + abs(z) > 10
    check initialCameraTarget(world, 2, selected.id) == expected
    check not followSelection

  test "a human without a valid selection starts at their town hall":
    let world = newWorld(generateMap(47, 3), 100)
    for hall in world.buildings:
      if hall.owner != 1 or hall.kind != TownHallBuilding:
        continue
      let
        half = world.map.side.float32 / 2
        x = hall.origin.x.float32 + hall.footprint.width.float32 / 2 - half
        z = hall.origin.y.float32 + hall.footprint.depth.float32 / 2 - half
        expected = vec3(x, surfaceHeight(x, z), z)
      check initialCameraTarget(world, 2, NoEntity) == expected
      check initialCameraTarget(world, 2, hall.id) == expected

  test "spectators start at terrain height in the map centre":
    let world = newWorld(generateMap(47, 3), 100)
    check initialCameraTarget(world, 0, world.units[0].id) ==
      vec3(0, surfaceHeight(0, 0), 0)
