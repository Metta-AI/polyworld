import
  benchy,
  ../maps, ../meshes, ../tiles

proc benchmark() =
  ## Measures the work performed when a control changes.
  let
    config = defaultConfig()
    map = generateMap(config)
  timeIt "Generate layout", 100:
    let generated = generateMap(config)
    doAssert generated.camps.len == 14
  timeIt "Build cached geometry", 100:
    let mesh = buildMesh(map)
    doAssert mesh.len > 1000
  timeIt "Generate terrain tiles", 100:
    let grid = buildTiles(map)
    doAssert grid.cells.len == TileCount * TileCount
  let grid = buildTiles(map)
  timeIt "Color tile texture", 100:
    let pixels = grid.colors()
    doAssert pixels.len == TileCount * TileCount
  echo "Map triangles: ", buildMesh(map).len

benchmark()
