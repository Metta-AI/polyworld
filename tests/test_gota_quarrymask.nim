import ../examples/gods_of_the_arena/[maps, quarrymask]

proc coverage(mask: seq[uint8], x, z: int): (uint8, uint8) =
  let index = (z * QuarryMaskSize + x) * QuarryMaskChannels
  (mask[index], mask[index + 1])

proc tileCenter(mask: seq[uint8], x, z: int): (uint8, uint8) =
  coverage(
    mask,
    x * QuarryMaskTexelsPerTile + QuarryMaskTexelsPerTile div 2,
    z * QuarryMaskTexelsPerTile + QuarryMaskTexelsPerTile div 2
  )

echo "Testing smooth sub-tile quarry paint"
block:
  let mask = buildQuarryGroundMask()
  doAssert mask.len == QuarryMaskSize * QuarryMaskSize * QuarryMaskChannels
  for site in QuarrySites:
    let (gravel, dirt) = tileCenter(mask, site[0], site[1])
    doAssert gravel == 255 and dirt == 255
  doAssert tileCenter(mask, 0, 0) == (0'u8, 0'u8)

  var feathered = 0
  for z in 0 ..< QuarryMaskSize:
    for x in 0 ..< QuarryMaskSize:
      let (_, dirt) = coverage(mask, x, z)
      if dirt > 0 and dirt < 255:
        inc feathered
  doAssert feathered > 200,
    "quarry earth needs a substantial antialiased transition band"

echo "GOTA quarry mask tests passed"
