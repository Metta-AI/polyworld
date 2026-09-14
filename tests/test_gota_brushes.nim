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
    int(brush.darkRocks[i])
  if tile.exists and tile.impassable and
    (tile.kind == TreeTile or tile.kind == ArenaRockKind):
      doAssert props == 1, "Each brush tile needs exactly one visible blocker."
      if tile.kind == TreeTile:
        inc lightCount
        lightRocks += int(brush.lightRocks[i])
        doAssert not brush.darkRocks[i]
        doAssert brush.trees[i] in [0'f, 1'f]
        doAssert brush.lightRocks[i] ==
          (brush.trees[ground.tiles.high - i] > 0),
          "Brush replacements must be rotationally paired."
      else:
        inc darkCount
        darkTrees += int(brush.trees[i] > 0)
        doAssert not brush.lightRocks[i]
        if brush.trees[i] > 0:
          doAssert brush.trees[i] < 1, "Dark trees must have a darker tint."
  else:
    doAssert props == 0, "Brush must not appear on roads or clearings."
doAssert lightCount > 0 and darkCount == lightCount
doAssert lightRocks == (lightCount + 2) div 5
doAssert darkTrees == lightRocks
echo "Replaced ", lightRocks, " of ", lightCount, " brush tiles on each side."
