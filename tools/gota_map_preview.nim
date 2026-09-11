## Writes a renderer-independent top-down preview of the Gota map blueprint.
## Useful when iterating terrain masks without the native asset checkout.

import
  std/[os, strformat, strutils],
  chroma, pixie,
  polyworld/pathing,
  ../examples/gods_of_the_arena/maps

const PixelScale = 5

proc colorFor(kind: uint32): ColorRGBX =
  case kind
  of GrassTile: rgbx(85, 128, 69, 255)
  of RoadTile: rgbx(153, 126, 83, 255)
  of RockTile: rgbx(103, 108, 96, 255)
  of MarshTile: rgbx(67, 105, 81, 255)
  of StoneTile: rgbx(150, 151, 141, 255)
  of TreeTile: rgbx(31, 70, 43, 255)
  of RedFortKind: rgbx(157, 89, 69, 255)
  of BlueFortKind: rgbx(80, 100, 151, 255)
  of LaneShoulderKind: rgbx(132, 125, 101, 255)
  of WetBankKind: rgbx(85, 119, 86, 255)
  of TowerCourtKind: rgbx(166, 153, 122, 255)
  of LandmarkHillKind: rgbx(120, 118, 91, 255)
  of QuarryFloorKind: rgbx(87, 91, 88, 255)
  of QuarryRimKind: rgbx(128, 124, 111, 255)
  of HillRockKind: rgbx(92, 95, 88, 255)
  else: rgbx(255, 0, 255, 255)

proc paintTile(image: Image, x, z: int, color: ColorRGBX) =
  for py in z * PixelScale ..< (z + 1) * PixelScale:
    for px in x * PixelScale ..< (x + 1) * PixelScale:
      image.data[py * image.width + px] = color

proc paintDisc(image: Image, x, z, radius: int, color: ColorRGBX) =
  let
    cx = x * PixelScale + PixelScale div 2
    cz = z * PixelScale + PixelScale div 2
    pixelRadius = radius * PixelScale
  for py in max(cz - pixelRadius, 0) .. min(cz + pixelRadius, image.height - 1):
    for px in max(cx - pixelRadius, 0) .. min(cx + pixelRadius, image.width - 1):
      let
        dx = px - cx
        dz = py - cz
      if dx * dx + dz * dz <= pixelRadius * pixelRadius:
        image.data[py * image.width + px] = color

let
  seed =
    if paramCount() >= 1: int32(parseInt(paramStr(1)))
    else: 2026'i32
  output =
    if paramCount() >= 2: paramStr(2)
    else: "tmp/gota_map_layout.png"
discard generateMap(seed)
let image = newImage(GridTiles * PixelScale, GridTiles * PixelScale)
for z in 0 ..< GridTiles:
  for x in 0 ..< GridTiles:
    let
      tile = layers[GroundLayer].tiles[z * GridTiles + x]
      water = layers[WaterLayer].tiles[z * GridTiles + x]
      color =
        if water.exists: rgbx(55, 112, 142, 255)
        else: colorFor(tile.kind)
    image.paintTile(x, z, color)
for lane in 0 .. 2:
  for team in 0 .. 1:
    for tier in 0 .. 2:
      let site = TowerSites[lane][team][tier]
      image.paintDisc(
        site.x, site.z, 1,
        if team == 0: rgbx(244, 92, 72, 255)
        else: rgbx(87, 151, 255, 255)
      )
image.paintDisc(RedFortTile, RedFortTile, 2, rgbx(255, 63, 48, 255))
image.paintDisc(BlueFortTile, BlueFortTile, 2, rgbx(55, 120, 255, 255))
createDir(output.parentDir)
image.writeFile(output)
echo &"wrote {output} for seed {seed}"
