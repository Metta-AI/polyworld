import
  std/math,
  pathing, rngs

type TerrainRelief* = seq[array[4, float32]]

proc fade(value: float32): float32 {.raises: [].} =
  ## Eases Perlin interpolation with zero first and second endpoint slopes.
  value * value * value * (value * (value * 6 - 15) + 10)

proc gradient(seed, x, z: int, dx, dz: float32): float32 {.raises: [].} =
  ## Projects an offset onto a seeded lattice gradient.
  var rng = Rng(state: cast[uint64](seed.int64) xor
    cast[uint64](x.int64) * 0x632BE59BD9B4E019'u64 xor
    cast[uint64](z.int64) * 0x1C69B3F74AC4AE35'u64)
  case int(rng.next() and 7)
  of 0: dx
  of 1: -dx
  of 2: dz
  of 3: -dz
  of 4: (dx + dz) * 0.70710678'f
  of 5: (dx - dz) * 0.70710678'f
  of 6: (-dx + dz) * 0.70710678'f
  else: (-dx - dz) * 0.70710678'f

proc perlin(seed: int, x, z: float32): float32 {.raises: [].} =
  ## Samples smooth two-dimensional gradient noise.
  let
    ix = floor(x).int
    iz = floor(z).int
    dx = x - ix.float32
    dz = z - iz.float32
    a = gradient(seed, ix, iz, dx, dz)
    b = gradient(seed, ix + 1, iz, dx - 1, dz)
    c = gradient(seed, ix, iz + 1, dx, dz - 1)
    d = gradient(seed, ix + 1, iz + 1, dx - 1, dz - 1)
    north = a + (b - a) * fade(dx)
    south = c + (d - c) * fade(dx)
  (north + (south - north) * fade(dz)) * 1.41421356'f

proc buildRelief*(
    ground: QuadLayer,
    natural: openArray[bool],
    seed: int,
    height = 0.2'f,
    spacing = 3.0'f
): TerrainRelief {.raises: [].} =
  ## Adds mirrored Perlin relief, fading to zero beside protected tiles.
  doAssert natural.len == ground.tiles.len
  doAssert height >= 0 and spacing > 0
  let width = ground.width + 1
  var corners = newSeq[float32](width * (ground.depth + 1))
  for z in 0 .. ground.depth:
    for x in 0 .. ground.width:
      var distance = 2.0'f
      for tz in max(0, z - 3) .. min(ground.depth - 1, z + 2):
        for tx in max(0, x - 3) .. min(ground.width - 1, x + 2):
          let index = tz * ground.width + tx
          if natural[index] and ground.tiles[index].exists:
            continue
          let
            dx = max(max(tx - x, x - tx - 1), 0).float32
            dz = max(max(tz - z, z - tz - 1), 0).float32
          distance = min(distance, sqrt(dx * dx + dz * dz))
      let
        first = perlin(seed, x.float32 / spacing + 0.37'f,
          z.float32 / spacing + 0.61'f)
        opposite = perlin(seed,
          (ground.width - x).float32 / spacing + 0.37'f,
          (ground.depth - z).float32 / spacing + 0.61'f)
      corners[z * width + x] = height * fade(distance / 2) *
        clamp((first + opposite) * 0.70710678'f, -1'f, 1'f)
  result.setLen(ground.tiles.len)
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      for corner in 0 .. 3:
        result[z * ground.width + x][corner] =
          corners[(z + corner div 2) * width + x + corner mod 2]

proc reliefHeight*(
    relief: TerrainRelief,
    ground: QuadLayer,
    worldX, worldZ: float32
): float32 {.raises: [].} =
  ## Samples relief on the same triangles used by the rendered ground.
  if relief.len == 0:
    return 0
  let
    localX = worldX + HalfGrid - ground.originX.float32
    localZ = worldZ + HalfGrid - ground.originZ.float32
    x = floor(localX).int
    z = floor(localZ).int
  if x < 0 or x >= ground.width or z < 0 or z >= ground.depth:
    return 0
  let index = z * ground.width + x
  if not ground.tiles[index].exists:
    return 0
  let
    h = relief[index]
    dx = localX - x.float32
    dz = localZ - z.float32
  if dx + dz <= 1:
    h[0] + (h[1] - h[0]) * dx + (h[2] - h[0]) * dz
  else:
    h[1] * (1 - dz) + h[2] * (1 - dx) + h[3] * (dx + dz - 1)
