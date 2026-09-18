## Writes a renderer-independent top-down preview of the Gota map blueprint.
## Useful when iterating terrain masks without the native asset checkout.

import
  std/[os, strformat, strutils],
  chroma, pixie,
  polyworld/pathing,
  ../examples/gods_of_the_arena/maps

const PixelScale = 5

proc paintTile(image: Image, x, z: int, color: ColorRGBX) =
  ## Fills one generated map tile at the preview scale.
  for py in z * PixelScale ..< (z + 1) * PixelScale:
    for px in x * PixelScale ..< (x + 1) * PixelScale:
      image.data[py * image.width + px] = color

proc paintDisc(image: Image, x, z, radius: int, color: ColorRGBX) =
  ## Marks a generated structure without changing the terrain image.
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

proc main() =
  ## Saves the current generated map and its actual structure positions.
  let
    seed =
      if paramCount() >= 1:
        int32(parseInt(paramStr(1)))
      else:
        2026'i32
    output =
      if paramCount() >= 2:
        paramStr(2)
      else:
        "tmp/gota_map_layout.png"
    map = generateMap(seed)
    image = newImage(map.resolution * PixelScale, map.resolution * PixelScale)
  for z in 0 ..< map.resolution:
    for x in 0 ..< map.resolution:
      let color = map.minimap[z * map.resolution + x]
      image.paintTile(x, z, rgbx(
        uint8(color shr 16 and 0xff),
        uint8(color shr 8 and 0xff),
        uint8(color and 0xff),
        255
      ))
  proc mark(point: PathPoint, team, radius: int) =
    ## Converts a generated world position to preview coordinates.
    let
      x = int(point.x div PathUnitsPerTile) + map.resolution div 2
      z = int(point.z div PathUnitsPerTile) + map.resolution div 2
      color =
        if team == 0:
          rgbx(244, 92, 72, 255)
        else:
          rgbx(87, 151, 255, 255)
    image.paintDisc(x, z, radius, color)
  for lane in map.layout.towers:
    for team, towers in lane:
      for site in towers:
        mark(site.position, team, 1)
  for team, point in map.layout.forts:
    mark(point, team, 2)
  createDir(output.parentDir)
  image.writeFile(output)
  echo &"wrote {output} for seed {seed}"

main()
