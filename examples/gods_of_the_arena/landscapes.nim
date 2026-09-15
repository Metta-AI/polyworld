import
  polyworld/[pathing, terrainreliefs],
  arenas

type Landscape* = object
  relief*: TerrainRelief
  materials*: seq[int]

proc buildLandscape*(
    ground: QuadLayer,
    mainRoads: openArray[bool],
    seed, mainMaterial, trailMaterial: int
): Landscape {.raises: [].} =
  ## Builds gentle natural relief and distinct dark lane and trail surfaces.
  doAssert mainRoads.len == ground.tiles.len
  var natural = newSeq[bool](ground.tiles.len)
  result.materials.setLen(ground.tiles.len)
  for i, tile in ground.tiles:
    result.materials[i] = -1
    natural[i] = arenaKind(tile.kind) in [GrassTile, TreeTile, RockTile] or
      tile.kind in ArenaWallKinds
    if tile.kind >= ArenaKindBase + ArenaKindStride and
      tile.kind < ArenaRockKind:
        let kind = (tile.kind - ArenaKindBase) mod ArenaKindStride
        if kind in [5'u32, 6'u32, 7'u32]:
          result.materials[i] =
            if mainRoads[i]:
              mainMaterial
            else:
              trailMaterial
  result.relief = buildRelief(ground, natural, seed)
