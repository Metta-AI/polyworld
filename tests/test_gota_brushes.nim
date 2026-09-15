import
  polyworld/pathing,
  ../examples/gods_of_the_arena/[arenas, brushes]

echo "Testing paired brush replacements preserve blocked terrain"
let
  arena = buildArena(defaultConfig())
  ground = arena.layers[0]
  before = ground.tiles
  brush = mixBrush(ground, 54)
doAssert brush == mixBrush(ground, 54)
doAssert brush != mixBrush(ground, 55)
doAssert ground.tiles == before
var
  lightCount, darkCount, lightRocks, darkTrees: int
for i, tile in ground.tiles:
  let props = int(brush.trees[i] > 0) + int(brush.lightRocks[i]) +
    int(brush.darkRocks[i]) + int(brush.darkTrees[i])
  if tile.exists and tile.impassable and
    (tile.kind == TreeTile or tile.kind == ArenaRockKind):
      doAssert props == 1, "Each brush tile needs exactly one visible blocker."
      if tile.kind == TreeTile:
        inc lightCount
        lightRocks += int(brush.lightRocks[i])
        doAssert not brush.darkRocks[i] and not brush.darkTrees[i]
        doAssert brush.trees[i] in [0'f, 1'f]
        doAssert brush.lightRocks[i] ==
          brush.darkTrees[ground.tiles.high - i],
          "Brush replacements must be rotationally paired."
      else:
        inc darkCount
        darkTrees += int(brush.darkTrees[i])
        doAssert not brush.lightRocks[i]
        doAssert brush.trees[i] == 0,
          "Dark brush uses authored tree models instead of light-side trees."
  else:
    doAssert props == 0, "Brush must not appear on roads or clearings."
doAssert lightCount > 0 and darkCount == lightCount
doAssert lightRocks == (lightCount + 2) div 5
doAssert darkTrees == lightRocks
echo "Replaced ", lightRocks, " of ", lightCount, " brush tiles on each side."
