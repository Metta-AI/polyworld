import
  std/math,
  vmath,
  polyworld/pathing,
  ../examples/gods_of_the_arena/[arenas, walls]

proc wall(first, last: Vec2, team = 0): ArenaWall =
  ## Makes a wall fixture in the same fixed coordinates as generated walls.
  result.team = team
  for i, point in [first, last]:
    result.points[i] = PathPoint(
      x: int32(round(point.x * PathUnitsPerTile.float32)),
      z: int32(round(point.y * PathUnitsPerTile.float32))
    )

proc pillarAt(parts: seq[WallPlacement], point: Vec2, team = 0): int =
  ## Counts shared pillars at one junction.
  for part in parts:
    if part.part == WallPillar and part.team == team and
      length(part.position - point) < 0.0001'f:
        inc result

proc checkConnections(parts: seq[WallPlacement]) =
  ## Checks each panel overlaps both pillars with exactly 80% center spacing.
  for part in parts:
    if part.part != WallPanel:
      continue
    doAssert part.length > 0 and part.length <= WallSectionLength + 0.0001'f
    let
      direction = vec2(cos(part.rotation), sin(part.rotation))
      offset = direction * (part.length * WallSpacingRatio / 2)
    for point in [part.position - offset, part.position + offset]:
      doAssert parts.pillarAt(point, part.team) == 1

echo "Testing shared corners and overlapping keep/spawn boundaries"
block:
  let parts = buildWalls([
    wall(vec2(0, 0), vec2(8, 0)),
    wall(vec2(0, 0), vec2(4, 0)),
    wall(vec2(4, 0), vec2(4, 4)),
    wall(vec2(0, 0), vec2(0, 0))
  ])
  parts.checkConnections()
  doAssert parts.len == 13
  doAssert parts.pillarAt(vec2(4, 0)) == 1
  doAssert parts.pillarAt(vec2(4, 4)) == 1

echo "Testing gate openings remain separate wall runs"
block:
  let parts = buildWalls([
    wall(vec2(0, 0), vec2(6, 0)),
    wall(vec2(10, 0), vec2(16, 0))
  ])
  parts.checkConnections()
  for part in parts:
    doAssert part.position.x <= 6 or part.position.x >= 10
    if part.part == WallPanel:
      doAssert part.position.x + part.length / 2 < 7 or
        part.position.x - part.length / 2 > 9

echo "Testing generated fort walls retain 180-degree symmetry"
block:
  let
    arena = buildArena(defaultConfig())
    parts = buildWalls(arena.layout.walls)
  doAssert parts.len > 100
  parts.checkConnections()
  for part in parts:
    var mirrored = false
    for other in parts:
      if other.part == part.part and other.team != part.team and
        length(other.position + part.position) < 0.0001'f and
        abs(other.length - part.length) < 0.0001'f:
          mirrored = true
          break
    doAssert mirrored, "Each wall part needs a matching part on the other side."
  echo parts.len, " connected wall parts."

echo "GotA wall tests passed"
