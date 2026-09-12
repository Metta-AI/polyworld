import ../examples/gods_of_the_arena/[groundmask, maps]

proc coverage(mask: seq[uint8], x, z: int): (uint8, uint8) =
  let index = (z * GroundMaskSize + x) * GroundMaskChannels
  (mask[index], mask[index + 1])

proc tileCenter(mask: seq[uint8], x, z: int): (uint8, uint8) =
  coverage(
    mask,
    x * GroundMaskTexelsPerTile + GroundMaskTexelsPerTile div 2,
    z * GroundMaskTexelsPerTile + GroundMaskTexelsPerTile div 2
  )

echo "Testing smooth sub-tile road and quarry paint"
block:
  let mask = buildArenaGroundMask()
  doAssert mask.len == GroundMaskSize * GroundMaskSize * GroundMaskChannels
  for site in QuarrySites:
    let (gravel, dirt) = tileCenter(mask, site[0], site[1])
    doAssert gravel == 255 and dirt == 255
  doAssert tileCenter(mask, 0, 0) == (0'u8, 0'u8)

  let
    (coreGravel, coreDirt) = tileCenter(mask, 62, 18)
  doAssert coreDirt == 255 and coreGravel < 16,
    "the lane core should remain exposed dirt"
  var shoulderGravel = 0'u8
  for z in 20 .. 21:
    shoulderGravel = max(shoulderGravel, tileCenter(mask, 62, z)[0])
  doAssert shoulderGravel > 150,
    "the lane needs its gravel shoulder"
  doAssert tileCenter(mask, 62, 24) == (0'u8, 0'u8),
    "the visual road should not sprawl far beyond the clear lane"

  var
    dirtFeather = 0
    gravelFeather = 0
  for z in 0 ..< GroundMaskSize:
    for x in 0 ..< GroundMaskSize:
      let (gravel, dirt) = coverage(mask, x, z)
      if dirt > 0 and dirt < 255:
        inc dirtFeather
      if gravel > 0 and gravel < 255:
        inc gravelFeather
  doAssert dirtFeather > 1_000,
    "roads and quarries need substantial antialiased dirt borders"
  doAssert gravelFeather > 1_000,
    "gravel edges need substantial height-shaped transition bands"

echo "GOTA ground mask tests passed"
