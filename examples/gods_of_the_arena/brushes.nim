import
  std/random,
  polyworld/pathing,
  arenas

const
  BrushReplacementPercent = 20
  DarkTreeBrightness = 0.6'f

type BrushMix* = object
  trees*: seq[float32]
  lightRocks*, darkRocks*: seq[bool]

proc mixBrush*(ground: QuadLayer, seed: int): BrushMix =
  ## Swaps twenty percent of paired brush tiles without changing game terrain.
  let count = ground.tiles.len
  result.trees = newSeq[float32](count)
  result.lightRocks = newSeq[bool](count)
  result.darkRocks = newSeq[bool](count)
  var pairs: seq[int]
  for i, tile in ground.tiles:
    if not tile.exists or not tile.impassable:
      continue
    case tile.kind
    of TreeTile:
      result.trees[i] = 1
      let opposite = ground.tiles[ground.tiles.high - i]
      if opposite.exists and opposite.impassable and
        opposite.kind == ArenaRockKind:
          pairs.add(i)
    of ArenaRockKind:
      result.darkRocks[i] = true
    else:
      discard
  var rng = initRand(seed.int64 xor 0x4252555348'i64)
  rng.shuffle(pairs)
  for i in 0 ..< (pairs.len * BrushReplacementPercent + 50) div 100:
    let
      light = pairs[i]
      dark = ground.tiles.high - light
    result.trees[light] = 0
    result.lightRocks[light] = true
    result.darkRocks[dark] = false
    result.trees[dark] = DarkTreeBrightness
