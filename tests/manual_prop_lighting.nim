## Requires desktop GL and polyworld_data to check building fog and lighting.

import
  std/os,
  chroma, opengl, pixie, vmath, windy,
  polyworld/[assets, common, quadterrain, shadows]

const
  MapSize = 64
  Position = vec3(-16, 0, 16)
  Rotation = 0.9'f
  Scale = 4.0'f

proc capture(
    pack: PropPack, name: string, matrix: Mat4, size: IVec2, baked = false
): Image =
  ## Reads the rendered building without a buffer swap or UI overlay.
  glViewport(0, 0, size.x, size.y)
  glDepthMask(GL_TRUE)
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  if baked:
    drawTerrain(matrix)
  else:
    pack.drawProp(name, Position, Rotation, Scale, matrix)
  result = newImage(size.x, size.y)
  glReadPixels(
    0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr
  )
  doAssert glGetError() == GL_NO_ERROR

proc brightness(image: Image): int =
  ## Sums the rendered RGB values, ignoring opaque black background pixels.
  for pixel in image.data:
    result += pixel.r.int + pixel.g.int + pixel.b.int

block:
  let window = newWindow(
    "Building lighting check", ivec2(320, 320), vsync = false
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  pollEvents()
  initTerrain(
    treeStyle = NoTrees,
    rockStyle = NoRocks,
    settings = TerrainAssets(size: 1024, materials: CartoonMaterials)
  )
  sunShadowsEnabled = false
  setEnvironmentPalette(color(1, 1, 1), color(0.15, 0.15, 0.2))
  let
    center = Position + vec3(0, 2, 0)
    matrix = ortho(-3'f, 3'f, -3'f, 3'f, 0.1'f, 100'f) *
      lookAt(center + vec3(5, 4, 8), center, vec3(0, 1, 0))
  var visibility = newSeq[uint8](MapSize * MapSize)
  for textured in [true, false]:
    for team in ["dark", "light"]:
      for name in ["tower_level1", "tower_level2", "tower_level3", "barracks"]:
        let pack = loadPropPack(
          DataRoot / "terrain/blender_forts/models" / team / (name & ".glb"),
          textured = textured,
          textureSize = 128,
          mergeNodes = true
        )
        for value in visibility.mitems:
          value = 255
        uploadTerrainVisibility(visibility, MapSize)
        let visible = capture(pack, name, matrix, window.size)
        doAssert visible.brightness > 100_000, "The building must be drawn."

        # Vision changing at the map center must not dim a distant building.
        for y in 24 ..< 40:
          for x in 24 ..< 40:
            visibility[y * MapSize + x] = 0
        uploadTerrainVisibility(visibility, MapSize)
        let distantFog = capture(pack, name, matrix, window.size)
        doAssert distantFog.data == visible.data,
          team & " " & name & " incorrectly samples fog at the map center."

        # The same rotated model must match the baked world-space lighting.
        # Baked placements use the opposite rotation convention to rotateY.
        clearProps()
        pack.placeProp(name, Position, -Rotation, Scale)
        bakeTerrain()
        let baked = capture(pack, name, matrix, window.size, baked = true)
        var difference = 0
        for i, pixel in visible.data:
          difference += abs(pixel.r.int - baked.data[i].r.int) +
            abs(pixel.g.int - baked.data[i].g.int) +
            abs(pixel.b.int - baked.data[i].b.int)
        doAssert difference.float / visible.brightness.float < 0.01,
          team & " " & name & " has inconsistent standalone lighting."

        for value in visibility.mitems:
          value = 0
        uploadTerrainVisibility(visibility, MapSize)
        let localFog = capture(pack, name, matrix, window.size)
        doAssert localFog.brightness < visible.brightness div 2,
          "Buildings must still dim when their own location is in fog."
        echo team, " ", name, " textured=", textured, ": passed"

echo "Building fog and world-space lighting passed"
