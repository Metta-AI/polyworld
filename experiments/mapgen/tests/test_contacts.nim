import
  vmath,
  ../maps, ../tiles

proc extraEntrances(map: MapData, grid: TileGrid): int =
  ## Counts camps that remain connected after their own stems are sealed.
  for i, camp in map.camps:
    let
      radius = map.config.campRadius + CampPadding
      outside = radius + CampForest + TileSize
      origin = (camp.position.y / TileSize).int * TileCount +
        (camp.position.x / TileSize).int
    var
      reached: array[TileCount * TileCount, bool]
      queue = @[origin]
      head = 0
      escaped = false
    reached[origin] = true
    while head < queue.len and not escaped:
      let
        index = queue[head]
        x = index mod TileCount
        y = index div TileCount
      head.inc
      for direction in Direction:
        if not grid.canStep(x, y, direction):
          continue
        let
          next = index + [-TileCount, 1, TileCount, -1][direction.ord]
          point = vec2(
            (next mod TileCount).float32 + 0.5'f,
            (next div TileCount).float32 + 0.5'f
          ) * TileSize
          distance = length(point - camp.position)
        if reached[next]:
          continue
        if distance >= radius - TileSize and
          length(map.stems[i].nearest(point) - point) <
          StemWidth / 2 + TileSize * 0.72'f:
            continue
        if distance >= outside:
          escaped = true
          break
        reached[next] = true
        queue.add(next)
    result += int(escaped)

echo "Checking camp edge contact without roads through camp centers."
var sample = MapData(
  config: defaultConfig(), camps: @[Camp(position: vec2(500, 500))]
)
sample.config.campsTouchRoads = false
let
  edge = @[vec2(430, 549), vec2(570, 549)]
  center = @[vec2(430, 500), vec2(570, 500)]
doAssert not sample.avoidsCamps(edge, TrailWidth)
sample.config.campsTouchRoads = true
doAssert sample.avoidsCamps(edge, TrailWidth)
doAssert not sample.avoidsCamps(center, TrailWidth)

for seed in [54, 55, 56]:
  for touching in [false, true]:
    var config = defaultConfig()
    config.seed = seed
    config.campsTouchRoads = touching
    let
      map = generateMap(config)
      grid = buildTiles(map)
      openings = map.extraEntrances(grid)
    doAssert map.stems.len == map.camps.len
    for camp in map.camps:
      doAssert map.levelClearing(camp.position, config.campRadius + CampPadding)
      doAssert grid.tileAt(camp.position).passable
    for road in map.roads:
      doAssert map.avoidsCamps(road, config.roadWidth)
    for road in map.trails & map.lakeRoads:
      doAssert map.avoidsCamps(road, TrailWidth)
    for i, tile in grid.cells:
      let other = grid.cells[grid.cells.high - i]
      doAssert tile.surface == other.surface
      doAssert tile.road == other.road
      for direction in Direction:
        doAssert tile.edges[direction] ==
          other.edges[Direction((direction.ord + 2) mod 4)]
    if touching:
      doAssert openings > 0, "The enabled rule must allow direct road access."
      doAssert generateMap(config) == map
    else:
      doAssert openings == 0, "The disabled rule must seal every forest ring."
    echo "Seed ", seed, ", touching ", touching, ": ", openings,
      " camps with direct access."
echo "Camp road contact checks passed."
