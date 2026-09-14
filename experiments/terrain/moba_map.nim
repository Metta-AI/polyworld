## Generated MOBA map on the quadterrain_aigen renderer: one ground layer,
## south base to north base. The south half is green meadow with water; the
## north half is rock and lava. Four terraces (wet ground, ground, high
## ground, base ground) step up toward each base, joined by ramps that are
## just sloped tiles inside the single layer. Three main lanes (mid plus a
## west and east ring lane whose long south and north legs meet short west
## and east legs) and jungle lanes cut through forested jungle spots; towers
## stand in mirrored spots on both halves.
## F1 toggles the panel; F12 saves a screenshot under tmp. DUMP_MAP=1
## prints the tile map as text.
## Run with nim r -d:release experiments/terrain/moba_map.nim.

import
  std/[os, strformat, strutils, heapqueue, random],
  bumpy, vmath, chroma, noisy, shady, pixie, pixie/internal, gltf,
  silky,
  polyworld/toon,
  ../../tools/terrain/common as terrainImages,
  ../../tools/terrain/heights,
  aigen_splats, aigen_surfaces, aigen_blends

const
  GridTiles = 96
  HalfGrid = GridTiles.float32 / 2.0

## Atlas

let builder = newAtlasBuilder(1024, 4)
builder.addDir("../polyworld_data/themes/main/", "../polyworld_data/themes/main/")
builder.addFont("../polyworld_data/themes/main/IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont("../polyworld_data/themes/main/IBMPlexSans-Regular.ttf", "Default", 18.0)
builder.write("tmp/editor.atlas.png")

## Window

let window = newWindow(
  "Quad Terrain AI Generated",
  ivec2(1280, 800),
  vsync = false
)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky(window, "tmp/editor.atlas.png")

## Terrain texture array
##
## One GL_TEXTURE_2D_ARRAY holds every ground material: rgb is the basecolor
## and alpha is the material's height map, so the blend shader gets both in
## a single sample. The soft palette contains four grasses and five surfaces.

const
  # The soft palette (with stamps) first, then the north half's hard
  # materials, which have tiles but no stamps and never get splats.
  TerrainMaterials = [
    "grass-1", "grass-2", "grass-3", "grass-4",
    "dirt-road-1", "cobble-road-1", "gravel-road-1",
    "forest-floor-1", "marsh-1",
    "crypt-rock-1", "crypt-rock-2", "crypt-lava-3", "crypt-lava-1",
    "crypt-stone-2"
  ]
  SplatMaterialCount = SurfaceNames.len
  RockGroundSurface = 9   # dark rock ground, the north's grass
  RubbleSurface = 10      # rock with red rubble, the north's second grass
  CinderSurface = 11      # cracked rock with lava seams: the north's wet ground
  LavaBedSurface = 12     # bed under the lava pools
  DarkStoneSurface = 13   # the north base's floor and tower pads
  GeneratedPath = "../polyworld_data/terrain/"
  MeadowPath = GeneratedPath & "toon_enchanted_meadow/"

proc mipChain(image: Image): seq[Image] =
  ## Full mip chain down to 1x1, box filtered in pixie's premultiplied space.
  result.add image
  while result[^1].width > 1:
    result.add result[^1].minifyBy2()

proc buildTextureArray(layers: seq[seq[Image]], wrap: GLint): GLuint =
  ## Uploads equally sized RGBA mip chains as one anisotropic
  ## GL_TEXTURE_2D_ARRAY, one chain per layer.
  let size = layers[0][0].width.GLsizei
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D_ARRAY, result)
  for level, mip in layers[0]:
    glTexImage3D(
      GL_TEXTURE_2D_ARRAY, level.GLint, GL_RGBA8.GLint,
      mip.width.GLsizei, mip.height.GLsizei,
      layers.len.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil
    )
  for layer, chain in layers:
    doAssert chain.len == layers[0].len
    for level, mip in chain:
      doAssert mip.width == layers[0][level].width
      glTexSubImage3D(
        GL_TEXTURE_2D_ARRAY, level.GLint, 0, 0, layer.GLint,
        mip.width.GLsizei, mip.height.GLsizei, 1,
        GL_RGBA, GL_UNSIGNED_BYTE, mip.data[0].addr
      )
  glTexParameteri(
    GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_LEVEL, (layers[0].len - 1).GLint)
  doAssert size > 0
  # Anisotropic filtering keeps the road and other near-horizontal surfaces
  # sharp at grazing angles instead of smearing into low mip levels.
  glTexParameterf(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_ANISOTROPY_EXT, 8.0)
  glTexParameteri(
    GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, wrap)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, wrap)
  glBindTexture(GL_TEXTURE_2D_ARRAY, 0)

proc readMaterial(directory, name: string): tuple[color, height: Image] =
  ## Loads the generated color and height pair at their native resolution.
  let
    color = terrainImages.loadPng(GeneratedPath / directory / (name & ".rgb.png"))
    height = terrainImages.loadPng(
      GeneratedPath / directory / (name & ".height.png")
    )
  color.sameSize(height)
  if color.width != aigen_splats.TextureSize or
    color.height != aigen_splats.TextureSize:
      raise newException(AigenError, "Expected a 256x256 material: " & name)
  for i, value in height.data:
    if value.a != 255 or value.r != value.g or value.g != value.b:
      raise newException(AigenError, "Expected opaque grayscale height: " & name)
    if directory == "tiles" and color.data[i].a != 255:
      raise newException(AigenError, "Terrain color must be opaque: " & name)
  result.color = color.newImage()
  result.height =
    if directory == "stamps":
      height.stampStencil(color).newImage()
    else:
      height.newImage()

proc loadTerrainMaterials(): seq[seq[Image]] =
  ## Builds color and height mips independently, then packs height into alpha.
  for name in TerrainMaterials:
    let
      material = readMaterial("tiles", name)
      colors = mipChain(material.color)
      heights = mipChain(material.height)
    for level in 0 ..< colors.len:
      for i in 0 ..< colors[level].data.len:
        colors[level].data[i].a = heights[level].data[i].r
    result.add colors

proc loadSplatMaterials(): tuple[colors, heights: seq[seq[Image]]] =
  ## Loads the matching soft stamp pairs with coverage-aware height filtering.
  for name in SurfaceNames:
    let material = readMaterial("stamps", name)
    result.colors.add mipChain(material.color)
    result.heights.add mipChain(material.height)

let terrainTextureArray = buildTextureArray(loadTerrainMaterials(), GL_REPEAT)
let splatMaterials = loadSplatMaterials()
let splatColorArray = buildTextureArray(splatMaterials.colors, GL_CLAMP_TO_EDGE)
let splatHeightArray = buildTextureArray(splatMaterials.heights, GL_CLAMP_TO_EDGE)

var
  splatBuffer, splatDataTexture: GLuint
  blendBuffer, blendDataTexture: GLuint
  splatPlacements = 0
  peakSplatsPerTile = 0
glGenBuffers(1, splatBuffer.addr)
glGenTextures(1, splatDataTexture.addr)
glGenBuffers(1, blendBuffer.addr)
glGenTextures(1, blendDataTexture.addr)

## Tree paintings: every variant of a tree model shares its UV layout, so
## one texture array holds all of them and each planted tree picks a layer.
## Alpha is the foliage cutout.

const TreeTextures = [
  GeneratedPath & "handpainted_trees/fir.png",
  MeadowPath & "terrain_stone_02d.png"
]

const TreeAlphaCutoff = 0.5'f32

proc coverage(image: Image): float32 =
  ## Fraction of texels that pass the cutout test.
  var passing = 0
  for c in image.data:
    if c.a.float32 / 255 >= TreeAlphaCutoff:
      inc passing
  passing.float32 / image.data.len.float32

proc loadTreeTextures(): seq[seq[Image]] =
  ## Coverage-preserving mip chains. Box filtering thin leaf shapes into
  ## their transparent surroundings drags alpha under the cutoff, so plain
  ## mips shed leaves level by level and distant trees go bald. Each level
  ## instead gets its alpha rescaled until the same fraction of texels
  ## passes the cutout as at full resolution.
  for layer, path in TreeTextures:
    let chain = mipChain(readImage(path))
    let target = coverage(chain[0])
    for level, mip in chain:
      # Filtered in premultiplied space (no dark fringes); the cutout
      # shader wants straight color.
      mip.data.toStraightAlpha()
      if layer > 0:
        for color in mip.data.mitems:
          color.r = uint8(min(color.r.float32 * 1.4'f, 255))
          color.g = uint8(min(color.g.float32 * 1.4'f, 255))
          color.b = uint8(min(color.b.float32 * 1.4'f, 255))
      if level == 0 or layer > 0:
        continue
      # Binary search the alpha scale that restores full-res coverage.
      var lo = 1.0'f32
      var hi = 8.0'f32
      for step in 0 ..< 10:
        let mid = (lo + hi) / 2
        var passing = 0
        for c in mip.data:
          if min(c.a.float32 * mid / 255, 1.0) >= TreeAlphaCutoff:
            inc passing
        if passing.float32 / mip.data.len.float32 < target:
          lo = mid
        else:
          hi = mid
      let alphaScale = (lo + hi) / 2
      for c in mip.data.mitems:
        c.a = uint8(min(c.a.float32 * alphaScale, 255))
    result.add chain

let treeTextureArray = buildTextureArray(loadTreeTextures(), GL_REPEAT)

## Shaders

var
  mvp: Uniform[Mat4]
  borderWidth: Uniform[float32]
  heightScale: Uniform[float32]
  edgesEnabled: Uniform[float32]
  texScale: Uniform[float32]
  blendDepth: Uniform[float32]
  heightBlend: Uniform[float32]
  heightBlendEnabled: Uniform[float32]
  splatsEnabled: Uniform[float32]
  splatAmount: Uniform[float32]
  splatColors: Uniform[Sampler2dArray]
  splatHeights: Uniform[Sampler2dArray]
  splatData: Uniform[SamplerBuffer]
  blendData: Uniform[SamplerBuffer]
  blendDebug: Uniform[float32]
  terrainTextures: Uniform[Sampler2dArray]
  visibilityTex: Uniform[Sampler2D]
  visOffset: Uniform[float32]
  visScale: Uniform[float32]
  # Shadow mapping: the sun's view-projection, its depth map, and controls.
  # The lit shaders sample through a comparison sampler (hardware PCF, each
  # tap bilinearly filtered); the debug view reads the same texture as a
  # plain sampler with the compare mode temporarily off.
  lightMvp: Uniform[Mat4]
  shadowMap: Uniform[Sampler2D]
  shadowMapPcf: Uniform[Sampler2dShadow]
  shadowsEnabled: Uniform[float32]
  shadowStrength: Uniform[float32]
  shadowBias: Uniform[float32]
  shadowTexel: Uniform[float32]
  shadowSoftness: Uniform[float32]
  # How much directional light shapes the surface at all: 1 is full sun
  # shading, 0 is a flat overcast/night look with no lit or shadow side.
  shadingStrength: Uniform[float32]
  sunDir: Uniform[Vec3]
  # Toon banding, the technique from src/polyworld/toon.nim: Lambert
  # intensity through a ramp texture, then palette highlight/shadow colors.
  toonEnabled: Uniform[float32]
  toonRampTex: Uniform[Sampler2D]
  toonHighlight: Uniform[Vec3]
  toonShadow: Uniform[Vec3]

proc texture(buffer: Uniform[Sampler2dArray], pos: Vec3): Vec4 =
  ## CPU stub; shady passes texture() through to GLSL as a builtin.
  vec4(0, 0, 0, 0)

proc terrainSample(uv: Vec2, material: float32): Vec4 =
  ## Uses the same texel density for every generated material.
  result = texture(terrainTextures, vec3(uv.x, uv.y, material))

proc terrainVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    edgeMask: float32,
    normal: Vec3,
    tileColor: Vec3,
    materials: Vec4,
    cornerWeight: Vec4,
    splatRange: Vec3,
    worldPos: var Vec3,
    vertEdgeMask: var float32,
    vertNormal: var Vec3,
    vertColor: var Vec3,
    vertMaterials: var Vec4,
    vertWeights: var Vec4,
    vertSplatRange: var Vec3,
    shadowCoord: var Vec4
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  # Normal-offset shadows: sample the map slightly off the surface along
  # its normal, which suppresses self-shadow acne better than depth bias.
  shadowCoord = lightMvp * vec4(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08,
    1.0
  )
  worldPos = vertPos
  vertEdgeMask = edgeMask
  vertNormal = normal
  vertColor = tileColor
  vertMaterials = materials
  vertWeights = cornerWeight
  vertSplatRange = splatRange

proc surfaceAmount(paint, baseHeight, detailHeight: float32): float32 =
  ## Shifts paint toward raised details while keeping pure endpoints intact.
  result = paint
  if heightBlendEnabled > 0.5 and paint > 0.0 and paint < 1.0:
    let
      difference = 2.0 * paint - 1.0 +
        (detailHeight - baseHeight) * heightBlend
      ratio = clamp(difference / max(blendDepth, 0.0001), -1.0, 1.0)
      a = 1.0 - max(ratio, 0.0)
      b = 1.0 + min(ratio, 0.0)
    result = b / (a + b)

proc terrainFrag(
    fragColor: var Vec4,
    worldPos: Vec3,
    vertEdgeMask: float32,
    vertNormal: Vec3,
    vertColor: Vec3,
    vertMaterials: Vec4,
    vertWeights: Vec4,
    vertSplatRange: Vec3,
    shadowCoord: Vec4
) =
  let tilePos = vec2(worldPos.x, worldPos.z)
  let h = clamp(worldPos.y / max(heightScale, 0.001) * 0.5 + 0.5, 0.0, 1.0)
  # Planar projection: tops map from world xz; walls pick the vertical plane
  # facing their normal so the texture doesn't stretch down cliff faces.
  let absNormal = abs(vertNormal)
  var uv = vec2(worldPos.x, worldPos.z) * texScale
  if absNormal.y < 0.5:
    if absNormal.x > absNormal.z:
      uv = vec2(worldPos.z, -worldPos.y) * texScale
    else:
      uv = vec2(worldPos.x, -worldPos.y) * texScale
  var
    materials = vertMaterials
    spatial = vertWeights
  if vertSplatRange.z >= 0:
    let
      tileUv = tilePos - floor(tilePos)
      quadrant = int(floor(tileUv.x + 0.5)) +
        int(floor(tileUv.y + 0.5)) * 2
      centerUv = tilePos - floor(tilePos + vec2(0.5)) + vec2(0.5)
    materials = texelFetch(blendData, int(vertSplatRange.z + 0.5) + quadrant)
    spatial = radialWeights(centerUv)
  let
    s0 = terrainSample(uv, max(materials.x, 0.0))
    s1 = terrainSample(uv, max(materials.y, 0.0))
    s2 = terrainSample(uv, max(materials.z, 0.0))
    s3 = terrainSample(uv, max(materials.w, 0.0))
    baseWeights = materialWeights(spatial, materials)
  var weights = baseWeights
  if heightBlendEnabled > 0.5:
    weights = reliefWeights(
      weights, vec4(s0.w, s1.w, s2.w, s3.w), heightBlend, blendDepth
    )
  var surface = s0 * weights.x + s1 * weights.y + s2 * weights.z + s3 * weights.w
  var debugColor = materialColor(vertMaterials.x)
  if blendDebug > 1.5:
    var debugWeights = baseWeights
    if blendDebug > 2.5:
      debugWeights = weights
    debugColor = materialColor(materials.x) * debugWeights.x +
      materialColor(materials.y) * debugWeights.y +
      materialColor(materials.z) * debugWeights.z +
      materialColor(materials.w) * debugWeights.w
  let
    worldDx = dFdx(tilePos)
    worldDy = dFdy(tilePos)
  if splatsEnabled > 0.5:
    var index = int(vertSplatRange.x + 0.5)
    let finish = index + int(vertSplatRange.y + 0.5)
    while index < finish:
      let
        placement = texelFetch(splatData, index * 2)
        brush = texelFetch(splatData, index * 2 + 1)
        delta = tilePos - placement.xy
        uvSplat = vec2(
          delta.x * placement.z + delta.y * placement.w,
          delta.y * placement.z - delta.x * placement.w
        ) + vec2(0.5)
        dx = vec2(
          worldDx.x * placement.z + worldDx.y * placement.w,
          worldDx.y * placement.z - worldDx.x * placement.w
        )
        dy = vec2(
          worldDy.x * placement.z + worldDy.y * placement.w,
          worldDy.y * placement.z - worldDy.x * placement.w
        )
      if uvSplat.x >= 0.0 and uvSplat.x <= 1.0 and
        uvSplat.y >= 0.0 and uvSplat.y <= 1.0:
          let
            samplePos = vec3(uvSplat.x, uvSplat.y, brush.x)
            paint = textureGrad(splatColors, samplePos, dx, dy)
            relief = textureGrad(splatHeights, samplePos, dx, dy)
            alpha = paint.w
            detailHeight = relief.x / max(relief.w, 0.00001)
          let amount = min(alpha, surfaceAmount(
            alpha * brush.y * splatAmount, surface.w, detailHeight
          ))
          let source = vec4(
            paint.x / max(alpha, 0.00001),
            paint.y / max(alpha, 0.00001),
            paint.z / max(alpha, 0.00001),
            detailHeight
          )
          surface = surface * (1.0 - amount) + source * amount
      index += 1
  let blended = surface.xyz
  # Per-kind tint (near white for textured kinds), brightened a little with
  # height. Impassable tiles keep their normal color; their blocked edges
  # show red when the edge display is on.
  var color = blended * vertColor * (0.75 + 0.5 * h)
  if blendDebug > 0.5:
    color = debugColor
  # Passability borders draw on upward faces only (walls sit exactly on
  # integer x/z, so the fract test would classify their every pixel as
  # border), and only while the edge display is toggled on. Each strip is
  # colored by its edge's passability: green connected, red blocked. The
  # mask packs the four edges as bits: east 1, south 2, west 4, north 8.
  if edgesEnabled > 0.5 and vertNormal.y > 0.3:
    let
      fx = tilePos.x - floor(tilePos.x)
      fy = tilePos.y - floor(tilePos.y)
      edge = min(min(fx, 1.0 - fx), min(fy, 1.0 - fy))
    if edge < borderWidth:
      var maskLeft = vertEdgeMask
      var northPass = 0.0'f32
      var westPass = 0.0'f32
      var southPass = 0.0'f32
      var eastPass = 0.0'f32
      if maskLeft >= 8.0:
        northPass = 1.0
        maskLeft = maskLeft - 8.0
      if maskLeft >= 4.0:
        westPass = 1.0
        maskLeft = maskLeft - 4.0
      if maskLeft >= 2.0:
        southPass = 1.0
        maskLeft = maskLeft - 2.0
      if maskLeft >= 1.0:
        eastPass = 1.0
      var passable = 0.0'f32
      if edge == fx:
        passable = westPass
      elif edge == 1.0 - fx:
        passable = eastPass
      elif edge == fy:
        passable = northPass
      else:
        passable = southPass
      if passable >= 0.5:
        color = vec3(0.10, 0.72, 0.22)
      else:
        color = vec3(0.88, 0.10, 0.08)
  # Shadow map test: project into the sun's depth map and take five taps
  # for a slightly soft edge. Shadow scales the directional term only, so
  # shadowed ground keeps the ambient floor.
  var shadow = 1.0'f32
  if shadowsEnabled > 0.5:
    let
      su = shadowCoord.x * 0.5 + 0.5
      sv = shadowCoord.y * 0.5 + 0.5
      sd = shadowCoord.z * 0.5 + 0.5 - shadowBias
    if su > 0.0 and su < 1.0 and sv > 0.0 and sv < 1.0 and sd < 1.0:
      # 3x3 grid of hardware-PCF taps, each bilinearly filtered by the
      # comparison sampler; spread widens the penumbra.
      let spread = shadowTexel * shadowSoftness
      var lit = 0.0'f32
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv + spread, sd))
      shadow = 1.0 - (1.0 - lit / 9.0) * shadowStrength
  if blendDebug > 0.5:
    discard
  elif toonEnabled > 0.5:
    # Toon banding: one-light Lambert scaled by the shadow test, pushed
    # through the ramp, then the palette's highlight/shadow colors.
    # shadingStrength pulls the intensity toward full highlight, so a low
    # sun or nighttime flattens the surface instead of shading it.
    let
      lambert = max(dot(normalize(vertNormal), sunDir), 0.0) * shadow
      intensity = 1.0 - shadingStrength + lambert * shadingStrength
      band = texture(toonRampTex, vec2(intensity, 0.5)).x
    color = color * (toonShadow * (1.0 - band) + toonHighlight * band)
  else:
    # Half-lambert directional lighting: smooth vertex normals across
    # connected terrain, hard breaks at cliffs and walls. Shadow scales the
    # whole lighting term so full strength really goes to black.
    let
      light = clamp(
        dot(normalize(vertNormal), sunDir) * 0.5 + 0.5,
        0.0, 1.0)
      lighting = (0.45 + 0.7 * light) * shadow
    color = color * (1.0 - shadingStrength + lighting * shadingStrength)
  # Line-of-sight fade: terrain hidden from the start marker drains to a
  # dark monochrome. The visibility texture holds one value per tile,
  # blurred on the CPU and bilinearly sampled here, so the boundary rolls
  # off over a couple of tiles instead of snapping at tile edges.
  let
    visUv = vec2(
      (tilePos.x + visOffset) * visScale,
      (tilePos.y + visOffset) * visScale)
    vis = smoothstep(0.05, 0.95, texture(visibilityTex, visUv).x)
    gray = dot(color, vec3(0.30, 0.59, 0.11)) * 0.5
  color = color * vis + vec3(gray, gray, gray) * (1.0 - vis)
  fragColor = vec4(color.x, color.y, color.z, 1.0)

proc compileStage(kind: GLenum, source, label: string): GLuint =
  result = glCreateShader(kind)
  var sourceArray = allocCStringArray([source])
  defer: deallocCStringArray(sourceArray)
  glShaderSource(result, 1.GLsizei, sourceArray, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    quit(label & " shader failed:\n" & log.strip(chars = {'\0'}) &
      "\nsource:\n" & source)

proc compileProgram(vertexSource, fragmentSource: string): GLuint =
  let
    vertexShader = compileStage(GL_VERTEX_SHADER, vertexSource, "terrain.vert")
    fragmentShader = compileStage(GL_FRAGMENT_SHADER, fragmentSource, "terrain.frag")
  result = glCreateProgram()
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  var ok: GLint
  glGetProgramiv(result, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    quit("terrain program failed:\n" & log)

let terrainProgram = compileProgram(
  toShader(terrainVert, glsl4Desktop, shaderVertex),
  toShader(terrainFrag, glsl4Desktop, shaderFragment)
)
let mvpLocation = glGetUniformLocation(terrainProgram, "mvp")
let borderWidthLocation = glGetUniformLocation(terrainProgram, "borderWidth")
let heightScaleLocation = glGetUniformLocation(terrainProgram, "heightScale")
let edgesEnabledLocation = glGetUniformLocation(terrainProgram, "edgesEnabled")
let texScaleLocation = glGetUniformLocation(terrainProgram, "texScale")
let blendDepthLocation = glGetUniformLocation(terrainProgram, "blendDepth")
let heightBlendLocation = glGetUniformLocation(terrainProgram, "heightBlend")
let heightBlendEnabledLocation =
  glGetUniformLocation(terrainProgram, "heightBlendEnabled")
let splatsEnabledLocation = glGetUniformLocation(terrainProgram, "splatsEnabled")
let splatAmountLocation = glGetUniformLocation(terrainProgram, "splatAmount")
let splatColorsLocation = glGetUniformLocation(terrainProgram, "splatColors")
let splatHeightsLocation = glGetUniformLocation(terrainProgram, "splatHeights")
let splatDataLocation = glGetUniformLocation(terrainProgram, "splatData")
let blendDataLocation = glGetUniformLocation(terrainProgram, "blendData")
let blendDebugLocation = glGetUniformLocation(terrainProgram, "blendDebug")
let terrainTexturesLocation = glGetUniformLocation(terrainProgram, "terrainTextures")
let visibilityTexLocation = glGetUniformLocation(terrainProgram, "visibilityTex")
let visOffsetLocation = glGetUniformLocation(terrainProgram, "visOffset")
let visScaleLocation = glGetUniformLocation(terrainProgram, "visScale")
let terrainLightMvpLocation = glGetUniformLocation(terrainProgram, "lightMvp")
let terrainShadowMapLocation = glGetUniformLocation(terrainProgram, "shadowMapPcf")
let terrainShadowsEnabledLocation = glGetUniformLocation(terrainProgram, "shadowsEnabled")
let terrainShadowStrengthLocation = glGetUniformLocation(terrainProgram, "shadowStrength")
let terrainShadowBiasLocation = glGetUniformLocation(terrainProgram, "shadowBias")
let terrainShadowTexelLocation = glGetUniformLocation(terrainProgram, "shadowTexel")
let terrainShadowSoftnessLocation = glGetUniformLocation(terrainProgram, "shadowSoftness")
let terrainShadingStrengthLocation = glGetUniformLocation(terrainProgram, "shadingStrength")
let terrainSunDirLocation = glGetUniformLocation(terrainProgram, "sunDir")
let terrainToonEnabledLocation = glGetUniformLocation(terrainProgram, "toonEnabled")
let terrainToonRampLocation = glGetUniformLocation(terrainProgram, "toonRampTex")
let terrainToonHighlightLocation = glGetUniformLocation(terrainProgram, "toonHighlight")
let terrainToonShadowLocation = glGetUniformLocation(terrainProgram, "toonShadow")

## Solid-color shader for the start/finish spheres and the path ribbon.

var solidColor: Uniform[Vec3]

proc solidVert(gl_Position: var Vec4, vertPos: Vec3) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)

proc solidFrag(fragColor: var Vec4) =
  fragColor = vec4(solidColor.x, solidColor.y, solidColor.z, 1.0)

let solidProgram = compileProgram(
  toShader(solidVert, glsl4Desktop, shaderVertex),
  toShader(solidFrag, glsl4Desktop, shaderFragment)
)
let solidMvpLocation = glGetUniformLocation(solidProgram, "mvp")
let solidColorLocation = glGetUniformLocation(solidProgram, "solidColor")

## Water shader: transparent blue with a Blinn-Phong specular highlight on
## the south half; the same surface glows as lava on the north half, where
## each vertex carries heat 1 instead of 0.

var cameraPos: Uniform[Vec3]

proc waterVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    normal: Vec3,
    heat: float32,
    worldPos: var Vec3,
    waterNormal: var Vec3,
    waterHeat: var float32
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  worldPos = vertPos
  waterNormal = normal
  waterHeat = heat

proc waterFrag(
    fragColor: var Vec4,
    worldPos: Vec3,
    waterNormal: Vec3,
    waterHeat: float32
) =
  let specular = pow(
    max(dot(
      normalize(waterNormal),
      normalize(
        normalize(cameraPos - worldPos) + sunDir)
    ), 0.0),
    48.0) * (1.0 - waterHeat)
  # Lava is opaque and unlit; slow ripples of brightness stand in for flow.
  let glow = 0.12 * sin(worldPos.x * 1.9 + worldPos.z * 1.3) +
    0.08 * sin(worldPos.x * 0.7 - worldPos.z * 2.3)
  fragColor = vec4(
    (0.13 + specular) * (1.0 - waterHeat) + (0.98 + glow) * waterHeat,
    (0.34 + specular) * (1.0 - waterHeat) + (0.38 + glow) * waterHeat,
    (0.58 + specular) * (1.0 - waterHeat) + 0.04 * waterHeat,
    clamp(0.55 + specular * 0.45 + 0.4 * waterHeat, 0.0, 1.0)
  )

let waterProgram = compileProgram(
  toShader(waterVert, glsl4Desktop, shaderVertex),
  toShader(waterFrag, glsl4Desktop, shaderFragment)
)
let waterMvpLocation = glGetUniformLocation(waterProgram, "mvp")
let waterCameraLocation = glGetUniformLocation(waterProgram, "cameraPos")
let waterSunDirLocation = glGetUniformLocation(waterProgram, "sunDir")

## Low-poly grass puffs: loaded with the gltf library, the
## palette texture baked into per-vertex colors, each model normalized with
## its base at the origin.

proc propVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertColor: Vec3,
    normal: Vec3,
    fragmentColor: var Vec3,
    fragmentNormal: var Vec3,
    shadowCoord: var Vec4
) =
  ## Projects vertex-colored props and offsets their shadow samples.
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  # Normal-offset shadows: sample the map slightly off the surface along
  # its normal, which suppresses self-shadow acne better than depth bias.
  shadowCoord = lightMvp * vec4(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08,
    1.0
  )
  fragmentColor = vertColor
  fragmentNormal = normal

proc propFrag(
    fragColor: var Vec4,
    fragmentColor: Vec3,
    fragmentNormal: Vec3,
    shadowCoord: Vec4
) =
  ## Lights opaque props with the same shadow and toon settings as terrain.
  var shadow = 1.0'f32
  if shadowsEnabled > 0.5:
    let
      su = shadowCoord.x * 0.5 + 0.5
      sv = shadowCoord.y * 0.5 + 0.5
      sd = shadowCoord.z * 0.5 + 0.5 - shadowBias
    if su > 0.0 and su < 1.0 and sv > 0.0 and sv < 1.0 and sd < 1.0:
      # 3x3 grid of hardware-PCF taps, each bilinearly filtered by the
      # comparison sampler; spread widens the penumbra.
      let spread = shadowTexel * shadowSoftness
      var lit = 0.0'f32
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv + spread, sd))
      shadow = 1.0 - (1.0 - lit / 9.0) * shadowStrength
  var shaded = vec3(0.0, 0.0, 0.0)
  if toonEnabled > 0.5:
    let
      lambert = max(dot(normalize(fragmentNormal), sunDir), 0.0) * shadow
      intensity = 1.0 - shadingStrength + lambert * shadingStrength
      band = texture(toonRampTex, vec2(intensity, 0.5)).x
    shaded = fragmentColor * (toonShadow * (1.0 - band) + toonHighlight * band)
  else:
    let
      light = clamp(
        dot(normalize(fragmentNormal), sunDir) * 0.5 + 0.5,
        0.0, 1.0)
      lighting = (0.45 + 0.7 * light) * shadow
    shaded = fragmentColor * (1.0 - shadingStrength + lighting * shadingStrength)
  fragColor = vec4(shaded.x, shaded.y, shaded.z, 1.0)

let propProgram = compileProgram(
  toShader(propVert, glsl4Desktop, shaderVertex),
  toShader(propFrag, glsl4Desktop, shaderFragment)
)
let propMvpLocation = glGetUniformLocation(propProgram, "mvp")
let propLightMvpLocation = glGetUniformLocation(propProgram, "lightMvp")
let propShadowMapLocation = glGetUniformLocation(propProgram, "shadowMapPcf")
let propShadowsEnabledLocation = glGetUniformLocation(propProgram, "shadowsEnabled")
let propShadowStrengthLocation = glGetUniformLocation(propProgram, "shadowStrength")
let propShadowBiasLocation = glGetUniformLocation(propProgram, "shadowBias")
let propShadowTexelLocation = glGetUniformLocation(propProgram, "shadowTexel")
let propShadowSoftnessLocation = glGetUniformLocation(propProgram, "shadowSoftness")
let propShadingStrengthLocation = glGetUniformLocation(propProgram, "shadingStrength")
let propSunDirLocation = glGetUniformLocation(propProgram, "sunDir")
let propToonEnabledLocation = glGetUniformLocation(propProgram, "toonEnabled")
let propToonRampLocation = glGetUniformLocation(propProgram, "toonRampTex")
let propToonHighlightLocation = glGetUniformLocation(propProgram, "toonHighlight")
let propToonShadowLocation = glGetUniformLocation(propProgram, "toonShadow")

## Handpainted trees: textured meshes whose foliage is alpha-cutout cards.
## The vertex stream carries uv plus the texture array layer; the fragment
## shader discards transparent texels, lights cards from either side, and
## applies the same line-of-sight fade as the terrain.

var
  treeTextures: Uniform[Sampler2dArray]
  treeAlphaCutoff: Uniform[float32]

proc treeVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec3,
    normal: Vec3,
    fragUv: var Vec3,
    fragmentNormal: var Vec3,
    fragWorld: var Vec3,
    shadowCoord: var Vec4
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  # Normal-offset shadows: sample the map slightly off the surface along
  # its normal, which suppresses self-shadow acne better than depth bias.
  shadowCoord = lightMvp * vec4(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08,
    1.0
  )
  fragUv = vertUv
  fragmentNormal = normal
  fragWorld = vertPos

proc treeFrag(
    fragColor: var Vec4,
    fragUv: Vec3,
    fragmentNormal: Vec3,
    fragWorld: Vec3,
    shadowCoord: Vec4
) =
  let texel = texture(treeTextures, fragUv)
  if texel.w < treeAlphaCutoff:
    discardFragment()
  var shadow = 1.0'f32
  if shadowsEnabled > 0.5:
    let
      su = shadowCoord.x * 0.5 + 0.5
      sv = shadowCoord.y * 0.5 + 0.5
      sd = shadowCoord.z * 0.5 + 0.5 - shadowBias
    if su > 0.0 and su < 1.0 and sv > 0.0 and sv < 1.0 and sd < 1.0:
      # 3x3 grid of hardware-PCF taps, each bilinearly filtered by the
      # comparison sampler; spread widens the penumbra.
      let spread = shadowTexel * shadowSoftness
      var lit = 0.0'f32
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv + spread, sd))
      shadow = 1.0 - (1.0 - lit / 9.0) * shadowStrength
  # Fir cards light on both sides; boulders use their outward-facing normals.
  var facing = dot(normalize(fragmentNormal), sunDir)
  if fragUv.z < 0.5:
    facing = abs(facing)
  var color = vec3(0.0, 0.0, 0.0)
  if toonEnabled > 0.5:
    let
      lambert = max(facing, 0.0) * shadow
      intensity = 1.0 - shadingStrength + lambert * shadingStrength
      band = texture(toonRampTex, vec2(intensity, 0.5)).x
    color = texel.xyz * (toonShadow * (1.0 - band) + toonHighlight * band)
  else:
    let
      light = clamp(
        facing * 0.5 + 0.5,
        0.0, 1.0)
      lighting = (0.5 + 0.65 * light) * shadow
    color = texel.xyz * (1.0 - shadingStrength + lighting * shadingStrength)
  let
    visUv = vec2(
      (fragWorld.x + visOffset) * visScale,
      (fragWorld.z + visOffset) * visScale)
    vis = smoothstep(0.05, 0.95, texture(visibilityTex, visUv).x)
    gray = dot(color, vec3(0.30, 0.59, 0.11)) * 0.5
  color = color * vis + vec3(gray, gray, gray) * (1.0 - vis)
  fragColor = vec4(color.x, color.y, color.z, 1.0)

let treeProgram = compileProgram(
  toShader(treeVert, glsl4Desktop, shaderVertex),
  toShader(treeFrag, glsl4Desktop, shaderFragment)
)
let treeMvpLocation = glGetUniformLocation(treeProgram, "mvp")
let treeTexturesLocation = glGetUniformLocation(treeProgram, "treeTextures")
let treeAlphaCutoffLocation = glGetUniformLocation(treeProgram, "treeAlphaCutoff")
let treeVisibilityTexLocation = glGetUniformLocation(treeProgram, "visibilityTex")
let treeVisOffsetLocation = glGetUniformLocation(treeProgram, "visOffset")
let treeVisScaleLocation = glGetUniformLocation(treeProgram, "visScale")
let treeLightMvpLocation = glGetUniformLocation(treeProgram, "lightMvp")
let treeShadowMapLocation = glGetUniformLocation(treeProgram, "shadowMapPcf")
let treeShadowsEnabledLocation = glGetUniformLocation(treeProgram, "shadowsEnabled")
let treeShadowStrengthLocation = glGetUniformLocation(treeProgram, "shadowStrength")
let treeShadowBiasLocation = glGetUniformLocation(treeProgram, "shadowBias")
let treeShadowTexelLocation = glGetUniformLocation(treeProgram, "shadowTexel")
let treeShadowSoftnessLocation = glGetUniformLocation(treeProgram, "shadowSoftness")
let treeShadingStrengthLocation = glGetUniformLocation(treeProgram, "shadingStrength")
let treeSunDirLocation = glGetUniformLocation(treeProgram, "sunDir")
let treeToonEnabledLocation = glGetUniformLocation(treeProgram, "toonEnabled")
let treeToonRampLocation = glGetUniformLocation(treeProgram, "toonRampTex")
let treeToonHighlightLocation = glGetUniformLocation(treeProgram, "toonHighlight")
let treeToonShadowLocation = glGetUniformLocation(treeProgram, "toonShadow")

## Shadow depth pass: everything that casts — terrain (bridge, walls, and
## overhangs included), props, and trees — rendered from the sun into a
## depth map. Trees keep their alpha cutout so foliage casts leafy shadows.

proc depthVert(gl_Position: var Vec4, vertPos: Vec3) =
  gl_Position = lightMvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)

proc depthFrag(fragColor: var Vec4) =
  fragColor = vec4(1.0, 1.0, 1.0, 1.0)

let depthProgram = compileProgram(
  toShader(depthVert, glsl4Desktop, shaderVertex),
  toShader(depthFrag, glsl4Desktop, shaderFragment)
)
let depthLightMvpLocation = glGetUniformLocation(depthProgram, "lightMvp")

proc treeDepthVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec3,
    fragUv: var Vec3
) =
  gl_Position = lightMvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  fragUv = vertUv

proc treeDepthFrag(fragColor: var Vec4, fragUv: Vec3) =
  let texel = texture(treeTextures, fragUv)
  if texel.w < treeAlphaCutoff:
    discardFragment()
  fragColor = vec4(1.0, 1.0, 1.0, 1.0)

let treeDepthProgram = compileProgram(
  toShader(treeDepthVert, glsl4Desktop, shaderVertex),
  toShader(treeDepthFrag, glsl4Desktop, shaderFragment)
)
let treeDepthLightMvpLocation = glGetUniformLocation(treeDepthProgram, "lightMvp")
let treeDepthTexturesLocation = glGetUniformLocation(treeDepthProgram, "treeTextures")
let treeDepthAlphaCutoffLocation = glGetUniformLocation(treeDepthProgram, "treeAlphaCutoff")

## Debug view: a screen-space quad showing the raw shadow depth map.

proc shadowViewVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec2,
    viewUv: var Vec2
) =
  gl_Position = vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  viewUv = vertUv

proc shadowViewFrag(fragColor: var Vec4, viewUv: Vec2) =
  let depth = texture(shadowMap, viewUv).x
  fragColor = vec4(depth, depth, depth, 1.0)

let shadowViewProgram = compileProgram(
  toShader(shadowViewVert, glsl4Desktop, shaderVertex),
  toShader(shadowViewFrag, glsl4Desktop, shaderFragment)
)
let shadowViewMapLocation = glGetUniformLocation(shadowViewProgram, "shadowMap")

type
  PropModel = object
    name: string
    height: float32         # model height before pack scaling
    vertices: seq[float32]  # x y z r g b nx ny nz; pack-scaled, base at y 0
  TreeModel = object
    name: string
    height: float32
    weight: float32         # relative planting frequency
    vertices: seq[float32]  # x y z u v nx ny nz; pack-scaled, base at y 0
    summerLayers: seq[int]  # tree texture array layers this mesh can wear
    autumnLayers: seq[int]  # summer: greens only; autumn: greens plus reds
                            # and yellows
  TreePlacement = object
    model: int
    position: Vec3
    rotation: float32
    scale: float32  # mild per-instance jitter around 1

var
  treeModels: seq[TreeModel]   # trees; occupy a tile and block it
  grassModels: seq[PropModel]  # grass puffs; walkable decoration
  rockModels: seq[TreeModel]   # Textured boulders use the UV geometry stream.
  grassPlacements: seq[TreePlacement]
  rockPlacements: seq[TreePlacement]

proc collectPropModels(
    node: gltf.Node, parent: Mat4, models: var seq[PropModel],
    skipPrefix = ""
) =
  ## Bakes model palette colors into a flat vertex stream.
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  if node.mesh != nil and
      (skipPrefix.len == 0 or not node.name.startsWith(skipPrefix)):
    var
      points: seq[Vec3]
      colors: seq[Vec3]
      sourceNormals: seq[Vec3]
      low = vec3(float32.high, float32.high, float32.high)
      high = vec3(float32.low, float32.low, float32.low)
    # Normals need the inverse transpose: node scales can be wildly
    # non-uniform (the rock pack), which distorts rotated normals.
    let normalMatrix = world.inverse.transpose
    for primitive in node.mesh.primitives:
      let image =
        if primitive.material != nil: primitive.material.baseColor else: nil
      template addCorner(index: int) =
        let point = world * primitive.points[index]
        low = min(low, point)
        high = max(high, point)
        points.add point
        if index < primitive.normals.len:
          let transformed = normalMatrix * vec4(
            primitive.normals[index].x,
            primitive.normals[index].y,
            primitive.normals[index].z,
            0
          )
          sourceNormals.add normalize(vec3(transformed.x, transformed.y, transformed.z))
        else:
          sourceNormals.add vec3(0, 0, 0)
        if image != nil and index < primitive.uvs.len:
          let
            uv = primitive.uvs[index]
            px = clamp(int(uv.x * image.width.float32), 0, image.width - 1)
            py = clamp(int(uv.y * image.height.float32), 0, image.height - 1)
            sample = image[px, py]
          colors.add vec3(
            sample.r.float32 / 255 * primitive.material.baseColorFactor.r,
            sample.g.float32 / 255 * primitive.material.baseColorFactor.g,
            sample.b.float32 / 255 * primitive.material.baseColorFactor.b
          )
        elif primitive.material != nil:
          # No UVs (e.g. the grass pack): flat material color.
          colors.add vec3(
            primitive.material.baseColorFactor.r,
            primitive.material.baseColorFactor.g,
            primitive.material.baseColorFactor.b
          )
        else:
          colors.add vec3(0.5, 0.5, 0.5)
      if primitive.indices32.len > 0:
        for index in primitive.indices32:
          addCorner(index.int)
      elif primitive.indices16.len > 0:
        for index in primitive.indices16:
          addCorner(index.int)
    if points.len > 0:
      let
        height = max(high.y - low.y, 0.001'f32)
        center = (low + high) / 2
      var model = PropModel(name: node.name, height: height)
      for t in countup(0, points.len - 3, 3):
        # Authored normals when the model has them; otherwise flat facet
        # normals from the triangle.
        var facet = cross(
          points[t + 1] - points[t], points[t + 2] - points[t])
        if facet.length > 0:
          facet = facet.normalize
        else:
          facet = vec3(0, 1, 0)
        for i in t .. t + 2:
          let
            point = points[i] - vec3(center.x, low.y, center.z)
            normal =
              if sourceNormals[i].length > 0.5: sourceNormals[i]
              else: facet
          model.vertices.add point.x
          model.vertices.add point.y
          model.vertices.add point.z
          model.vertices.add colors[i].x
          model.vertices.add colors[i].y
          model.vertices.add colors[i].z
          model.vertices.add normal.x
          model.vertices.add normal.y
          model.vertices.add normal.z
      models.add model
  for child in node.nodes:
    collectPropModels(child, world, models, skipPrefix)

proc scalePack(models: var seq[PropModel], targetTallest: float32) =
  ## Scales a whole pack by one factor (tallest model becomes targetTallest
  ## tiles) so relative sizes within the pack are preserved.
  var tallest = 0.001'f32
  for model in models:
    tallest = max(tallest, model.height)
  let packScale = targetTallest / tallest
  for model in models.mitems:
    model.height *= packScale
    var i = 0
    while i < model.vertices.len:
      model.vertices[i] *= packScale
      model.vertices[i + 1] *= packScale
      model.vertices[i + 2] *= packScale
      i += 9

proc collectTreeMesh(
    node: gltf.Node, parent: Mat4,
    points: var seq[Vec3], uvs: var seq[Vec2], normals: var seq[Vec3]
) =
  ## Flattens a glb node tree into world-space triangle soup keeping UVs.
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  if node.mesh != nil:
    let normalMatrix = world.inverse.transpose
    for primitive in node.mesh.primitives:
      template addCorner(index: int) =
        points.add world * primitive.points[index]
        uvs.add primitive.uvs[index]
        let transformed = normalMatrix * vec4(
          primitive.normals[index].x, primitive.normals[index].y,
          primitive.normals[index].z, 0)
        normals.add normalize(vec3(transformed.x, transformed.y, transformed.z))
      if primitive.indices32.len > 0:
        for index in primitive.indices32:
          addCorner(index.int)
      else:
        for index in primitive.indices16:
          addCorner(index.int)
  for child in node.nodes:
    collectTreeMesh(child, world, points, uvs, normals)

proc loadTexturedModel(
    node: gltf.Node, parent: Mat4,
    name: string, weight: float32, summerLayers, autumnLayers: seq[int]
): TreeModel =
  ## Flattens a textured model and recenters its base without changing UVs.
  var
    points: seq[Vec3]
    uvs: seq[Vec2]
    normals: seq[Vec3]
  collectTreeMesh(node, parent, points, uvs, normals)
  if points.len == 0:
    raise newException(AigenError, "Textured model has no triangles: " & name)
  var
    low = vec3(float32.high, float32.high, float32.high)
    high = vec3(float32.low, float32.low, float32.low)
  for point in points:
    low = min(low, point)
    high = max(high, point)
  let center = (low + high) / 2
  result = TreeModel(
    name: name, height: high.y - low.y, weight: weight,
    summerLayers: summerLayers, autumnLayers: autumnLayers)
  for i, point in points:
    let p = point - vec3(center.x, low.y, center.z)
    result.vertices.add p.x
    result.vertices.add p.y
    result.vertices.add p.z
    result.vertices.add uvs[i].x
    result.vertices.add uvs[i].y
    result.vertices.add normals[i].x
    result.vertices.add normals[i].y
    result.vertices.add normals[i].z

proc loadTreeModel(
  name: string, weight: float32, summerLayers, autumnLayers: seq[int]
): TreeModel =
  ## Loads the selected fir from the shadows experiment's tree pack.
  loadTexturedModel(
    readGltfFile(GeneratedPath & "handpainted_trees/" & name & ".glb").root,
    mat4(), name, weight, summerLayers, autumnLayers
  )

proc collectRockModels(node: gltf.Node, parent: Mat4) =
  ## Selects the Meadow boulders and normalizes each model to unit height.
  if node.name in ["rock_large_02a", "rock_medium_01a"]:
    var model = loadTexturedModel(node, parent, node.name, 1, @[1], @[1])
    let factor = 1.0'f / max(model.height, 0.001'f)
    for i in countup(0, model.vertices.len - 8, 8):
      model.vertices[i] *= factor
      model.vertices[i + 1] *= factor
      model.vertices[i + 2] *= factor
    model.height = 1
    rockModels.add(model)
    return
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  for child in node.nodes:
    collectRockModels(child, world)

# Keep the two dense fir models from the shadows experiment.
treeModels.add loadTreeModel("tree_fir_01", 25, @[0], @[0])
treeModels.add loadTreeModel("tree_fir_02", 20, @[0], @[0])

proc pickTreeModel(rng: var Rand): int =
  ## Weighted choice over the tree models.
  var total = 0.0'f32
  for model in treeModels:
    total += model.weight
  var roll = rng.rand(total.float)
  for i, model in treeModels:
    roll -= model.weight
    if roll <= 0:
      return i
  treeModels.high

proc scaleTrees(models: var seq[TreeModel], targetTallest: float32) =
  ## Scales the whole tree pack by one factor so relative sizes hold.
  var tallest = 0.001'f32
  for model in models:
    tallest = max(tallest, model.height)
  let packScale = targetTallest / tallest
  for model in models.mitems:
    model.height *= packScale
    var i = 0
    while i < model.vertices.len:
      model.vertices[i] *= packScale
      model.vertices[i + 1] *= packScale
      model.vertices[i + 2] *= packScale
      i += 8

collectPropModels(readGltfFile("../polyworld_data/terrain/low_poly_grass.glb").root, mat4(), grassModels)
collectRockModels(readGltfFile(MeadowPath & "rocks.glb").root, mat4())
doAssert rockModels.len == 2

treeModels.scaleTrees(8.4)
grassModels.scalePack(0.7)

## Towers: three fortification pieces from the tower defense kit, baked
## through the prop path so their painted texture becomes vertex color.

const TowerModelNames = ["tower_square_tall1", "tower_square_tall2", "tower_tall1"]
const
  LaneTowerModel = 0   # square battlement tower along every lane
  SpireModel = 1       # the base's tall spire
  FlankTowerModel = 2  # round towers flanking the spire

var
  towerModels: seq[PropModel]
  towerPlacements: seq[TreePlacement]

proc collectTowerModels(node: gltf.Node, parent: Mat4) =
  ## Picks the named kit pieces, keeping TowerModelNames order.
  if node.name in TowerModelNames:
    var found: seq[PropModel]
    collectPropModels(node, parent, found)
    doAssert found.len == 1, "Expected one mesh for " & node.name
    towerModels.add found[0]
    return
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  for child in node.nodes:
    collectTowerModels(child, world)

collectTowerModels(
  readGltfFile(GeneratedPath & "tower_defense_kit.glb").root, mat4())
doAssert towerModels.len == TowerModelNames.len
block:
  var ordered: seq[PropModel]
  for name in TowerModelNames:
    for model in towerModels:
      if model.name == name:
        ordered.add model
  towerModels = ordered
towerModels.scalePack(5.5)

## Terrain parameters (UI-driven)

var
  showSplats = true
  useHeightBlend = true
  splatsPerTile = 1
  splatPlacement = 0.40'f
  splatPaint = 1.00'f
  grassPatchSize = 24.0'f
  seed = 1988
  levelHeight = 1.5'f32      # rise per terrace
  rampLength = 4             # tiles a ramp takes to climb one terrace
  laneWidth = 1.9'f32        # main lane half width; four tiles wide
  jungleLaneWidth = 1.2'f32  # jungle lane half width; two tiles wide
  bumpAmplitude = 0.2'f32    # gentle per-corner relief on every terrace
  bumpFrequency = 0.13'f32
  wobbleAmplitude = 2.5'f32  # how far terrace edges wander between ramps
  grassCount = 320
  waterEnabled = true
  treesEnabled = true
  grassEnabled = true
  rocksEnabled = true
  towersEnabled = true
  rockCount = 70
  slopeLimit = 60.0'f32  # degrees; steeper top tiles are marked impassable
  losEnabled = true      # fade terrain hidden from the start marker to gray
  treeDensity = 1.0'f32       # scales the jungle spots' planting chances
  jungleTouchesLanes = true   # creep camps grow right up to the road edge
  treeHeight = 6.0'f          # Dense fir crowns close the forest at tile scale.
  boulderHeight = 1.6'f32     # jungle boulders on the rock half, in tiles
borderWidth = 0.05
var textureSize = 2.5'f  # world tiles one texture repeat spans
if existsEnv("SPLATS"):
  showSplats = getEnv("SPLATS") != "0"
if existsEnv("HEIGHT_BLEND"):
  useHeightBlend = getEnv("HEIGHT_BLEND") != "0"
if existsEnv("SPLATS_PER_TILE"):
  try:
    splatsPerTile = getEnv("SPLATS_PER_TILE").parseInt()
  except ValueError as error:
    raise newException(AigenError, "Invalid SPLATS_PER_TILE count.", error)
for name in [
  "SPLAT_PLACEMENT", "SPLAT_AMOUNT", "TEXTURE_SIZE", "GRASS_PATCH_SIZE"
]:
  if not existsEnv(name):
    continue
  var value: float32
  try:
    value = getEnv(name).parseFloat.float32
  except ValueError as error:
    raise newException(AigenError, "Invalid " & name & " value.", error)
  if name == "GRASS_PATCH_SIZE":
    if not (value >= 8 and value <= 48):
      raise newException(AigenError, "GRASS_PATCH_SIZE must be between 8 and 48.")
    grassPatchSize = value
  elif name == "TEXTURE_SIZE":
    if not (value >= 0.5 and value <= 12):
      raise newException(AigenError, "TEXTURE_SIZE must be between 0.5 and 12.")
    textureSize = value
  else:
    if not (value >= 0 and value <= 1):
      raise newException(AigenError, name & " must be between zero and one.")
    if name == "SPLAT_PLACEMENT":
      splatPlacement = value
    else:
      splatPaint = value
blendDepth = 0.43    # Sets blend band width; smaller is more abrupt.
heightBlend = 1.30   # Controls how strongly height maps steer the blend.
shadowStrength = 0.75  # how dark shadows get; 1 goes to pure black
shadowBias = 0.0012    # depth offset that hides self-shadow acne
shadowSoftness = 1.5   # PCF spread in shadow-map texels
shadingStrength = 1.0  # 1 full directional shading, 0 flat

## Quad layers

const HeightSteps = 8.0'f32  # heights quantize to 1/8 of a tile

proc pack(values: array[4, float32]): array[4, int16] =
  for i in 0 .. 3:
    result[i] = int16(round(values[i] * HeightSteps))

proc unpack(steps: array[4, int16]): array[4, float32] =
  for i in 0 .. 3:
    result[i] = steps[i].float32 / HeightSteps

const
  TileExists = 1'u32
  TileConnectedEast = 2'u32   # edge to (x+1, z); clear means a break
  TileConnectedSouth = 4'u32  # edge to (x, z+1)
  TileImpassable = 8'u32      # forced: trees, boulders, pools, tower pads
  TileRocky = 16'u32          # north-half material set: rock, gravel, lava
  TileRamp = 32'u32           # sloped tile joining two terraces

  GrassTile = 0'u32    # open ground: grass on the south, rock on the north
  RoadTile = 1'u32     # lanes and jungle lanes, ramps included
  BaseTile = 2'u32     # the base plateau's paved floor
  MarshTile = 3'u32    # wet ground on the lowest terrace
  StoneTile = 4'u32    # tower pads
  TreeTile = 5'u32     # renders like forest floor; the tile carries a tree
  RiverbedTile = 6'u32 # bed beneath a water or lava pool
  BoulderTile = 7'u32  # the rock half's jungle: the tile carries a boulder

type TileStyle = object
  topMaterial: float32    # texture array layer for the top surface
  skirtMaterial: float32  # texture array layer for side walls and undersides
  skirtTint: Vec3         # darkens walls a little; tops are untinted so the
                          # smooth material blend never shows tile squares

# Tile style index for the green half: texture array layers per tile kind.
# Rocky tiles swap in the north materials through tileSkirt and
# rebuildMaterials.
const TileStyleTable = [
  TileStyle(
    topMaterial: GrassSurface,
    skirtMaterial: DirtSurface,
    skirtTint: vec3(0.85)
  ),
  TileStyle(
    topMaterial: DirtSurface,
    skirtMaterial: DirtSurface,
    skirtTint: vec3(0.85)
  ),
  TileStyle(
    topMaterial: CobbleSurface,
    skirtMaterial: CobbleSurface,
    skirtTint: vec3(0.9)
  ),
  TileStyle(
    topMaterial: MarshSurface,
    skirtMaterial: ForestSurface,
    skirtTint: vec3(0.8)
  ),
  TileStyle(
    topMaterial: CobbleSurface,
    skirtMaterial: CobbleSurface,
    skirtTint: vec3(0.9)
  ),
  TileStyle(
    topMaterial: ForestSurface,
    skirtMaterial: ForestSurface,
    skirtTint: vec3(0.85)
  ),
  TileStyle(
    topMaterial: MarshSurface,
    skirtMaterial: ForestSurface,
    skirtTint: vec3(0.85)
  ),
  TileStyle(
    topMaterial: RockGroundSurface,
    skirtMaterial: RockGroundSurface,
    skirtTint: vec3(0.85)
  )
]

const TopTint = vec3(1, 1, 1)

proc styleOf(kind: uint32): TileStyle =
  TileStyleTable[min(kind, TileStyleTable.high.uint32).int]

type
  Tile = object
    ## Corner heights, tile flags, material kind, and a variable splat span.
    tops: array[4, int16]     # top corners: [x0z0, x1z0, x0z1, x1z1]
    bottoms: array[4, int16]  # underside corners; only used by slab layers
    flags: uint32
    kind: uint32
    level: int                # terrace 0 .. 3; the map rim sits one higher
    splats: SplatSpan
    material: int
    blendFirst: int

  QuadLayer = object
    originX, originZ: int  # placement in world tile coordinates
    width, depth: int
    slab: bool   # slab layers close their sides and underside down to
                 # bottoms; the ground layer instead skirts to the floor
    water: bool  # flat transparent surface; never walkable, never connects
                 # to other layers, and renders in its own blended pass
    tiles: seq[Tile]

proc setFlag(tile: var Tile, flag: uint32, on: bool) =
  if on:
    tile.flags = tile.flags or flag
  else:
    tile.flags = tile.flags and not flag

proc exists(tile: Tile): bool = (tile.flags and TileExists) != 0
proc `exists=`(tile: var Tile, on: bool) = tile.setFlag(TileExists, on)
proc connectedEast(tile: Tile): bool = (tile.flags and TileConnectedEast) != 0
proc connectedSouth(tile: Tile): bool = (tile.flags and TileConnectedSouth) != 0
proc impassable(tile: Tile): bool = (tile.flags and TileImpassable) != 0
proc `impassable=`(tile: var Tile, on: bool) = tile.setFlag(TileImpassable, on)
proc rocky(tile: Tile): bool = (tile.flags and TileRocky) != 0
proc ramp(tile: Tile): bool = (tile.flags and TileRamp) != 0

proc tileSkirt(tile: Tile): float32 =
  ## Cliff and skirt material: the green half's per-kind style, or the rock
  ## half's dark rock (dark stone under paving).
  if tile.rocky:
    if tile.kind == StoneTile or tile.kind == BaseTile:
      DarkStoneSurface.float32
    else:
      RockGroundSurface.float32
  else:
    styleOf(tile.kind).skirtMaterial

var layers: seq[QuadLayer]

## MOBA layout
##
## The map is designed once for the south team in design space: x runs
## west to east and s is the distance north from the south edge, both in
## tile units. A design point (x, s) lands on world tile coordinates
## (x, GridTiles - s); the north team is the mirror s -> GridTiles - s and
## the east lane is the west lane mirrored x -> GridTiles - x. Terraces:
## 0 wet ground with pools, 1 ground, 2 high ground, 3 base ground.

type
  LanePoint = object
    x, s: float32
    level: int
  Lane = object
    halfWidth: float32
    points: seq[LanePoint]
  RoadSegment = object
    a, b: Vec2          # world tile coordinates (x, z)
    levelA, levelB: int
    halfWidth: float32
    ramp: bool          # levels differ: axis-aligned and rampLength long
  JungleSpot = object
    x, s, radiusX, radiusS: float32  # ellipse in folded design space
  TowerSpot = object
    x, s: int    # the corner the tower stands on; a 2x2 stone pad surrounds it
    level: int
    model: int
  RoadProbe = object
    penetration: float32  # distance minus half width of the closest lane
    segment: int
    t: float32            # position along that segment, 0 at a, 1 at b
    rampDistance: float32 # distance to the nearest ramp

const
  BaseDepth = 14.0'f32      # the base plateau reaches this far from the edge
  BaseHalfWidth = 14.0'f32
  HighEdge = 22.0'f32       # high ground ends here (terrace 2 -> 1)
  RiverEdge = 42.0'f32      # ground ends here (terrace 1 -> 0)
  RimWidth = 3              # impassable forest frame around the map
  RoadMargin = 1.2'f32      # off-road tiles this close share the road's terrace
  TreeMargin = 1.0'f32      # gap between forest and road edge when camps
                            # may not touch lanes
  PoolSurface = -0.12'f32   # pool surface relative to wet ground
  PoolDepth = 0.8'f32       # how deep pools dig into wet ground

  # Jungle spots in folded design space (x toward the west edge, s toward
  # the south edge), so each appears four times. Each spot rings itself
  # with dense trees, thins inside, and keeps a clearing at its center.
  JungleSpots = [
    JungleSpot(x: 28, s: 24, radiusX: 6, radiusS: 4.5),  # between jungle lanes
    JungleSpot(x: 38, s: 36, radiusX: 7, radiusS: 4.5),  # beside mid, on the ground
    JungleSpot(x: 17, s: 26, radiusX: 5, radiusS: 5),    # under the ring lane's bend
    JungleSpot(x: 28, s: 12, radiusX: 5, radiusS: 2.5),  # high ground, on the south leg
    JungleSpot(x: 6, s: 22, radiusX: 6, radiusS: 16),    # strip outside the ring lane
    JungleSpot(x: 34, s: 44, radiusX: 5, radiusS: 2.5),  # river reeds
    JungleSpot(x: 12, s: 44, radiusX: 4, radiusS: 3)     # river corner
  ]
  # Towers for the south team's west side and mid; mirrored east and north.
  TowerSpots = [
    TowerSpot(x: 52, s: 37, level: 1, model: LaneTowerModel),  # mid, ground
    TowerSpot(x: 52, s: 19, level: 2, model: LaneTowerModel),  # mid, high ground
    TowerSpot(x: 52, s: 11, level: 3, model: LaneTowerModel),  # mid, base gate
    TowerSpot(x: 15, s: 39, level: 1, model: LaneTowerModel),  # ring, ground
    TowerSpot(x: 25, s: 17, level: 2, model: LaneTowerModel),  # ring, high ground
    TowerSpot(x: 38, s: 11, level: 3, model: LaneTowerModel),  # ring, base gate
    TowerSpot(x: 48, s: 5, level: 3, model: SpireModel),       # the base itself
    TowerSpot(x: 41, s: 4, level: 3, model: FlankTowerModel)   # flanking the spire
  ]

proc smoothRamp(edge0, edge1, x: float32): float32 =
  ## Hermite step from 0 at edge0 to 1 at edge1; edges may run either way.
  let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
  t * t * (3 - 2 * t)

proc lanePoint(x, s: float32, level: int): LanePoint =
  LanePoint(x: x, s: s, level: level)

proc designLanes(): seq[Lane] =
  ## The south team's lanes. Ramps are axis-aligned runs rampLength long,
  ## centered on the terrace edge they climb, so lanes only ever cross a
  ## terrace edge on a ramp.
  let
    half = rampLength.float32 / 2
    main = laneWidth
    jungle = jungleLaneWidth
  proc north(x, edge: float32, upper, lower: int): seq[LanePoint] =
    ## Steps down a terrace heading north.
    @[lanePoint(x, edge - half, upper), lanePoint(x, edge + half, lower)]
  proc south(x, edge: float32, upper, lower: int): seq[LanePoint] =
    ## Steps up a terrace heading south.
    @[lanePoint(x, edge + half, lower), lanePoint(x, edge - half, upper)]
  proc west(edge, s: float32, upper, lower: int): seq[LanePoint] =
    ## Steps down a terrace heading west.
    @[lanePoint(edge + half, s, upper), lanePoint(edge - half, s, lower)]
  # Mid lane: straight north out of the base, down every terrace, to the river.
  var mid = Lane(halfWidth: main)
  mid.points.add lanePoint(48, 8, 3)
  mid.points.add north(48, BaseDepth, 3, 2)
  mid.points.add north(48, HighEdge, 2, 1)
  mid.points.add north(48, RiverEdge, 1, 0)
  mid.points.add lanePoint(48, 48, 0)
  result.add mid
  # The west ring lane: its long south leg leaves the base's west gate,
  # bends north-west across the high ground and the ground, and drops to
  # the river by the map edge, where the short west leg meets its twin.
  var ring = Lane(halfWidth: main)
  ring.points.add lanePoint(42, 8, 3)
  ring.points.add west(48 - BaseHalfWidth, 8, 3, 2)
  ring.points.add lanePoint(29, 9.5, 2)
  ring.points.add lanePoint(22, 14, 2)
  ring.points.add north(22, HighEdge, 2, 1)
  ring.points.add lanePoint(14, 34, 1)
  ring.points.add north(10, RiverEdge, 1, 0)
  ring.points.add lanePoint(8, 48, 0)
  result.add ring
  # Jungle lanes: a ground crossing and a high ground crossing from mid to
  # the ring lane, a ramp linking the two, a ramp down to the river road,
  # and the river road itself along the mirror line.
  var ground = Lane(halfWidth: jungle)
  ground.points.add lanePoint(46, 30, 1)
  ground.points.add lanePoint(34, 30, 1)
  ground.points.add lanePoint(24, 36, 1)
  ground.points.add lanePoint(15, 35, 1)
  result.add ground
  var high = Lane(halfWidth: jungle)
  high.points.add lanePoint(46, 17, 2)
  high.points.add lanePoint(36, 17, 2)
  high.points.add lanePoint(30, 15, 2)
  high.points.add lanePoint(27, 11.5, 2)
  result.add high
  var link = Lane(halfWidth: jungle)
  link.points.add lanePoint(34, 30, 1)
  link.points.add south(34, HighEdge, 2, 1)
  link.points.add lanePoint(34, 17, 2)
  result.add link
  var drop = Lane(halfWidth: jungle)
  drop.points.add lanePoint(24, 36, 1)
  drop.points.add north(24, RiverEdge, 1, 0)
  drop.points.add lanePoint(24, 48, 0)
  result.add drop
  var river = Lane(halfWidth: main)
  river.points.add lanePoint(48, 48, 0)
  river.points.add lanePoint(8, 48, 0)
  result.add river

proc worldPoint(p: LanePoint, mirrorX, mirrorZ: bool): Vec2 =
  ## Design space to world tile coordinates; south is high z.
  var
    x = p.x
    z = GridTiles.float32 - p.s
  if mirrorX:
    x = GridTiles.float32 - x
  if mirrorZ:
    z = GridTiles.float32 - z
  vec2(x, z)

proc laneSegments(): seq[RoadSegment] =
  ## Every lane as world segments: the design, its east twin, and both
  ## mirrored north. Twins of self-symmetric lanes just repeat harmlessly.
  for lane in designLanes():
    for mirrorX in [false, true]:
      for mirrorZ in [false, true]:
        for i in 0 ..< lane.points.len - 1:
          let
            p = lane.points[i]
            q = lane.points[i + 1]
            segment = RoadSegment(
              a: worldPoint(p, mirrorX, mirrorZ),
              b: worldPoint(q, mirrorX, mirrorZ),
              levelA: p.level,
              levelB: q.level,
              halfWidth: lane.halfWidth,
              ramp: p.level != q.level
            )
          if segment.ramp:
            doAssert abs(segment.a.x - segment.b.x) < 0.01 or
              abs(segment.a.y - segment.b.y) < 0.01, "Ramps must be axis-aligned."
          result.add segment

proc segmentDistance(segment: RoadSegment, p: Vec2): tuple[distance, t: float32] =
  let
    d = segment.b - segment.a
    lengthSquared = d.x * d.x + d.y * d.y
  var t = 0.0'f32
  if lengthSquared > 0:
    t = clamp(dot(p - segment.a, d) / lengthSquared, 0, 1)
  let closest = segment.a + d * t
  ((p - closest).length, t)

proc probeRoads(segments: seq[RoadSegment], p: Vec2): RoadProbe =
  ## The lane that reaches closest to p, judged by distance past its edge.
  result.penetration = float32.high
  result.rampDistance = float32.high
  for i, segment in segments:
    let (distance, t) = segmentDistance(segment, p)
    if distance - segment.halfWidth < result.penetration:
      result.penetration = distance - segment.halfWidth
      result.segment = i
      result.t = t
    if segment.ramp:
      result.rampDistance = min(result.rampDistance, distance)

proc bandLevel(x, z, wobble: float32): int =
  ## Terrace by distance from the nearest base edge: the base plateau, then
  ## high ground, ground, and the wet river band in the middle.
  let
    n = GridTiles.float32
    s = min(z, n - z)
  if s < BaseDepth and abs(x - n / 2) < BaseHalfWidth:
    return 3
  let w = s + wobble
  result =
    if w < HighEdge: 2
    elif w < RiverEdge: 1
    else: 0

proc jungleDensity(folded: Vec2): float32 =
  ## Planting chance from the jungle spots: dense rings, thinner hearts,
  ## and a clearing at every center.
  for spot in JungleSpots:
    let
      dx = (folded.x - spot.x) / spot.radiusX
      ds = (folded.y - spot.s) / spot.radiusS
      e = sqrt(dx * dx + ds * ds)
    if e >= 1:
      continue
    let
      ox = folded.x - spot.x
      os = folded.y - spot.s
    if ox * ox + os * os < 2.3 * 2.3:
      continue
    result = max(result, if e > 0.62: 0.95'f32 else: 0.45'f32)

proc generateLayers() =
  let n = GridTiles.float32
  var
    bump = initSimplex(seed)
    wobbleNoise = initSimplex(seed xor 0x77)
    poolNoise = initSimplex(seed xor 0x99)
    rockNoise = initSimplex(seed xor 0x33)
  bump.frequency = bumpFrequency
  bump.octaves = 2
  wobbleNoise.frequency = 0.06
  wobbleNoise.octaves = 2
  poolNoise.frequency = 0.11
  poolNoise.octaves = 2
  rockNoise.frequency = 0.15
  rockNoise.octaves = 2

  proc fold(x, z: float32): Vec2 =
    ## Design-space fold: every geometric choice is made in the south-west
    ## quarter and mirrored, so the map plays the same from every side.
    vec2(min(x, n - x), min(z, n - z))

  proc cornerBump(cx, cz: int): float32 =
    ## Gentle relief as a pure function of the corner, so tiles that share a
    ## corner never disagree.
    let f = fold(cx.float32, cz.float32)
    bump.value(f.x, f.y) * bumpAmplitude

  proc levelY(level: int): float32 = level.float32 * levelHeight

  let segments = laneSegments()
  var ground = QuadLayer(
    originX: 0, originZ: 0,
    width: GridTiles, depth: GridTiles,
    slab: false,
    tiles: newSeq[Tile](GridTiles * GridTiles)
  )
  template gtile(x, z: int): var Tile = ground.tiles[(z) * GridTiles + (x)]
  var probes = newSeq[RoadProbe](GridTiles * GridTiles)

  # Pass 1: terrace and kind per tile. Roads carry their own terrace (a
  # ramp's changes along it), tiles hugging a road follow it, and the rest
  # comes from the terrace bands, whose edges wander except near ramps.
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        center = vec2(x.float32 + 0.5, z.float32 + 0.5)
        folded = fold(center.x, center.y)
        hit = probeRoads(segments, center)
        segment = segments[hit.segment]
        rampFalloff = clamp((hit.rampDistance - 3.0'f32) / 4.0'f32, 0, 1)
        wobble = wobbleNoise.value(folded.x, folded.y) * wobbleAmplitude *
          rampFalloff
        rockiness = smoothRamp(56, 40, center.y) +
          0.3'f32 * rockNoise.value(center.x, center.y)
        rim = x < RimWidth or x >= GridTiles - RimWidth or
          z < RimWidth or z >= GridTiles - RimWidth
      probes[z * GridTiles + x] = hit
      var tile = Tile(flags: TileExists or TileConnectedEast or TileConnectedSouth)
      if rockiness > 0.5:
        tile.flags = tile.flags or TileRocky
      if hit.penetration < 0:
        tile.kind = RoadTile
        if segment.ramp:
          tile.flags = tile.flags or TileRamp
          tile.level = if hit.t < 0.5: segment.levelA else: segment.levelB
        else:
          tile.level = segment.levelA
      else:
        tile.kind = GrassTile
        if hit.penetration < RoadMargin and not segment.ramp:
          tile.level = segment.levelA
        else:
          tile.level = bandLevel(center.x, center.y, wobble)
        if tile.level == 3:
          tile.kind = BaseTile
        elif tile.level == 0:
          tile.kind = MarshTile
      if rim:
        inc tile.level
        tile.impassable = true
      gtile(x, z) = tile

  # Tower pads: the four tiles around each tower corner become stone and
  # take the tower's terrace, so the tower stands on a flat pad.
  towerPlacements.setLen(0)
  var towerCorners: seq[(int, int)]
  if towersEnabled and towerModels.len > 0:
    var seen: seq[(int, int)]
    for spot in TowerSpots:
      for mirrorX in [false, true]:
        for mirrorZ in [false, true]:
          var
            cx = spot.x
            cz = GridTiles - spot.s
          if mirrorX:
            cx = GridTiles - cx
          if mirrorZ:
            cz = GridTiles - cz
          if (cx, cz) in seen:
            continue
          seen.add (cx, cz)
          for (px, pz) in [(cx - 1, cz - 1), (cx, cz - 1), (cx - 1, cz), (cx, cz)]:
            gtile(px, pz).kind = StoneTile
            gtile(px, pz).level = spot.level
            gtile(px, pz).impassable = true
            gtile(px, pz).flags = gtile(px, pz).flags and not TileRamp
          towerCorners.add (cx, cz)
          towerPlacements.add TreePlacement(
            model: spot.model,
            position: vec3(cx.float32 - HalfGrid, 0, cz.float32 - HalfGrid),
            rotation: if mirrorZ: PI.float32 else: 0.0'f32,
            scale: 1
          )

  # Pass 2: corner heights. Flat terraces plus relief; ramps interpolate
  # along their segment; wet ground dips into pools away from the roads.
  proc roadCorner(cx, cz: int): bool =
    ## A corner touching a road or pad keeps pools away from it.
    for (tx, tz) in [(cx - 1, cz - 1), (cx, cz - 1), (cx - 1, cz), (cx, cz)]:
      if tx < 0 or tz < 0 or tx >= GridTiles or tz >= GridTiles:
        continue
      let kind = gtile(tx, tz).kind
      if kind == RoadTile or kind == StoneTile:
        return true
    false

  proc dig(cx, cz: int): float32 =
    if roadCorner(cx, cz):
      return 0
    let f = fold(cx.float32, cz.float32)
    PoolDepth * smoothRamp(-0.1, 0.35, poolNoise.value(f.x, f.y))

  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let hit = probes[z * GridTiles + x]
      var tile = gtile(x, z)
      var tops: array[4, float32]
      for i in 0 .. 3:
        let
          cx = x + (i and 1)
          cz = z + (i shr 1)
        var h: float32
        if tile.ramp:
          let
            segment = segments[hit.segment]
            d = segment.b - segment.a
            t = clamp(
              dot(vec2(cx.float32, cz.float32) - segment.a, d) /
                (d.x * d.x + d.y * d.y),
              0, 1)
          h = levelY(segment.levelA) * (1 - t) + levelY(segment.levelB) * t
        else:
          h = levelY(tile.level)
          if tile.level == 0 and tile.kind == MarshTile:
            h -= dig(cx, cz)
        tops[i] = h + cornerBump(cx, cz)
      tile.tops = pack(tops)
      if tile.kind == MarshTile and not tile.impassable:
        let average = (tops[0] + tops[1] + tops[2] + tops[3]) / 4
        if average < PoolSurface - 0.15:
          tile.kind = RiverbedTile
          tile.impassable = true
      gtile(x, z) = tile

  # Pass 3: jungle. Spots plant trees on the green half and boulders on
  # the rock half; the rim is solid forest. Lanes cut through with a
  # margin, and nothing grows on pads, pools, ramps, or the bases.
  rockPlacements.setLen(0)
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        hit = probes[z * GridTiles + x]
        tile = gtile(x, z)
        rim = tile.level >= 4 or (tile.impassable and tile.kind != RiverbedTile and
          tile.kind != StoneTile)
      if tile.kind == RoadTile or tile.kind == StoneTile or
          tile.kind == RiverbedTile or tile.ramp:
        continue
      if tile.level == 3 and not rim:
        continue
      let treeMargin = if jungleTouchesLanes: 0.0'f32 else: TreeMargin
      if hit.penetration < treeMargin and not rim:
        continue
      let
        center = vec2(x.float32 + 0.5, z.float32 + 0.5)
        folded = fold(center.x, center.y)
        density = if rim: 1.0'f32 else: jungleDensity(folded) * treeDensity
      if density <= 0:
        continue
      var rng = initRand(
        (int64(folded.x * 2) * 73856093 + int64(folded.y * 2) * 19349663 +
          seed.int64 * 83492791) or 1)
      if rng.rand(1.0).float32 > density:
        continue
      gtile(x, z).impassable = true
      if tile.rocky:
        gtile(x, z).kind = BoulderTile
        if rockModels.len > 0:
          let
            h = tile.tops.unpack
            model = rng.rand(rockModels.len - 1)
            boulderScale = boulderHeight * (0.8'f32 + rng.rand(0.4).float32)
          rockPlacements.add TreePlacement(
            model: model,
            position: vec3(
              x.float32 - HalfGrid + 0.5,
              (h[0] + h[1] + h[2] + h[3]) / 4.0 - boulderScale * 0.2'f32,
              z.float32 - HalfGrid + 0.5
            ),
            rotation: rng.rand(2.0 * PI).float32,
            scale: boulderScale
          )
      else:
        gtile(x, z).kind = if treesEnabled: TreeTile else: GrassTile
        if not treesEnabled:
          gtile(x, z).impassable = false

  # Towers stand on their pad's shared corner.
  for i, corner in towerCorners:
    towerPlacements[i].position.y = gtile(corner[0], corner[1]).tops.unpack[0]

  # Grass puffs: walkable decoration on the green half's open ground,
  # jittered inside the tile so they don't look planted on a grid.
  grassPlacements.setLen(0)
  if grassModels.len > 0 and grassEnabled:
    var grassRng = initRand(seed * 31337 + 7)
    var attempts = 0
    var placed = 0
    while placed < grassCount and attempts < grassCount * 20:
      inc attempts
      let
        x = grassRng.rand(GridTiles - 1)
        z = grassRng.rand(GridTiles - 1)
        tile = gtile(x, z)
      if not tile.exists or tile.impassable or tile.rocky or
          (tile.kind != GrassTile and tile.kind != MarshTile):
        continue
      let
        h = tile.tops.unpack
        offsetX = 0.15'f32 + grassRng.rand(0.7).float32
        offsetZ = 0.15'f32 + grassRng.rand(0.7).float32
        height = (h[0] * (1 - offsetX) + h[1] * offsetX) * (1 - offsetZ) +
          (h[2] * (1 - offsetX) + h[3] * offsetX) * offsetZ
      grassPlacements.add TreePlacement(
        model: grassRng.rand(grassModels.len - 1),
        position: vec3(
          x.float32 - HalfGrid + offsetX,
          height,
          z.float32 - HalfGrid + offsetZ
        ),
        rotation: grassRng.rand(2.0 * PI).float32,
        scale: 0.7'f32 + grassRng.rand(0.7).float32
      )
      inc placed

  # Loose rocks: half-buried boulders scattered on the rock half's open
  # ground. They block the tile they sit on.
  if rockModels.len > 0 and rocksEnabled:
    var rockRng = initRand(seed * 104729 + 3)
    var attempts = 0
    var placed = 0
    while placed < rockCount and attempts < rockCount * 40:
      inc attempts
      let
        x = rockRng.rand(GridTiles - 1)
        z = rockRng.rand(GridTiles - 1)
        tile = gtile(x, z)
      if not tile.exists or tile.impassable or not tile.rocky or
          tile.kind != GrassTile:
        continue
      gtile(x, z).impassable = true
      let
        h = tile.tops.unpack
        model = rockRng.rand(rockModels.len - 1)
        rockScale = (1.1'f + rockRng.rand(1.1).float32) * 0.75'f
      rockPlacements.add TreePlacement(
        model: model,
        position: vec3(
          x.float32 - HalfGrid + 0.5,
          (h[0] + h[1] + h[2] + h[3]) / 4.0 - rockScale * 0.43'f,
          z.float32 - HalfGrid + 0.5
        ),
        rotation: rockRng.rand(2.0 * PI).float32,
        scale: rockScale
      )
      inc placed

  layers = @[ground]

## Mesh

var
  vertexArray, vertexBuffer: GLuint
  mesh: seq[float32]
  meshVertexCount = 0
  propVertexArray, propVertexBuffer: GLuint
  propMesh: seq[float32]   # Packs position, color, and normal for grass puffs.
  treeVertexArray, treeVertexBuffer: GLuint
  treeMesh: seq[float32]   # x y z u v layer nx ny nz; textured trees
  waterVertexArray, waterVertexBuffer: GLuint
  waterMesh: seq[float32]  # x y z nx ny nz

proc bakeInstance(model: PropModel, position: Vec3, rotation, instanceScale: float32) =
  ## Transforms one opaque prop into the combined geometry buffer.
  let
    rotationMatrix = rotateY(rotation)
    transform = translate(position) * rotationMatrix *
      scale(vec3(instanceScale, instanceScale, instanceScale))
  var i = 0
  while i < model.vertices.len:
    let
      point = transform * vec3(
        model.vertices[i], model.vertices[i + 1], model.vertices[i + 2])
      normal = rotationMatrix * vec3(
        model.vertices[i + 6], model.vertices[i + 7], model.vertices[i + 8])
    propMesh.add point.x
    propMesh.add point.y
    propMesh.add point.z
    propMesh.add model.vertices[i + 3]
    propMesh.add model.vertices[i + 4]
    propMesh.add model.vertices[i + 5]
    propMesh.add normal.x
    propMesh.add normal.y
    propMesh.add normal.z
    i += 9

proc bakePlacements(models: seq[PropModel], placements: seq[TreePlacement]) =
  ## Bakes map-generated prop placements in their stable order.
  for placement in placements:
    bakeInstance(
      models[placement.model], placement.position,
      placement.rotation, placement.scale)

proc bakeTree(
    model: TreeModel, textureLayer: int, position: Vec3,
    rotation, instanceScale: float32
) =
  ## Transforms one tree into the textured foliage buffer.
  let
    rotationMatrix = rotateY(rotation)
    transform = translate(position) * rotationMatrix *
      scale(vec3(instanceScale, instanceScale, instanceScale))
  var i = 0
  while i < model.vertices.len:
    let
      point = transform * vec3(
        model.vertices[i], model.vertices[i + 1], model.vertices[i + 2])
      normal = rotationMatrix * vec3(
        model.vertices[i + 5], model.vertices[i + 6], model.vertices[i + 7])
    treeMesh.add point.x
    treeMesh.add point.y
    treeMesh.add point.z
    treeMesh.add model.vertices[i + 3]
    treeMesh.add model.vertices[i + 4]
    treeMesh.add textureLayer.float32
    treeMesh.add normal.x
    treeMesh.add normal.y
    treeMesh.add normal.z
    i += 8

proc bakeTreeTiles() =
  ## Tree tiles carry their tree in the tile data: which model, painting,
  ## rotation, and size all derive deterministically from the tile
  ## coordinates. Only the two dense fir models are planted.
  if treeModels.len == 0 or layers.len == 0:
    return
  let ground = layers[0]
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      let t = ground.tiles[z * ground.width + x]
      if not t.exists or t.kind != TreeTile:
        continue
      var rng = initRand(x * 73856093 + z * 19349663 + seed * 83492791 + 1)
      let
        h = t.tops.unpack
        model = pickTreeModel(rng)
        layers = treeModels[model].summerLayers
        textureLayer = layers[rng.rand(layers.len - 1)]
        rotation = rng.rand(2.0 * PI).float32
        treeScale = (0.85'f32 + rng.rand(0.45).float32) * treeHeight / 8.4'f32
      bakeTree(
        treeModels[model], textureLayer,
        vec3(
          x.float32 - HalfGrid + 0.5,
          (h[0] + h[1] + h[2] + h[3]) / 4.0,
          z.float32 - HalfGrid + 0.5
        ),
        rotation,
        treeScale
      )

proc rebuildTreeMesh() =
  ## Bakes textured firs and boulders, then vertex-colored grass puffs.
  if treeVertexBuffer == 0:
    return  # buffers not created yet during the initial rebuild
  treeMesh.setLen(0)
  bakeTreeTiles()
  for placement in rockPlacements:
    bakeTree(
      rockModels[placement.model],
      1,
      placement.position,
      placement.rotation,
      placement.scale
    )
  if treeMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      treeMesh.len * sizeof(float32),
      treeMesh[0].addr,
      GL_STATIC_DRAW
    )
  propMesh.setLen(0)
  bakePlacements(grassModels, grassPlacements)
  bakePlacements(towerModels, towerPlacements)
  if propMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, propVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      propMesh.len * sizeof(float32),
      propMesh[0].addr,
      GL_STATIC_DRAW
    )

let cornerWeights = [
  vec4(1, 0, 0, 0), vec4(0, 1, 0, 0), vec4(0, 0, 1, 0), vec4(0, 0, 0, 1)
]

proc addTriangle(
    a, b, c, normalA, normalB, normalC, tint: Vec3,
    materials: Vec4,
    weightA, weightB, weightC: Vec4,
    edgeMask = 0.0'f,
    splatRange = vec3(0, 0, -1)
) =
  for (v, n, w) in [
    (a, normalA, weightA), (b, normalB, weightB), (c, normalC, weightC)
  ]:
    mesh.add v.x
    mesh.add v.y
    mesh.add v.z
    mesh.add edgeMask
    mesh.add n.x
    mesh.add n.y
    mesh.add n.z
    mesh.add tint.x
    mesh.add tint.y
    mesh.add tint.z
    mesh.add materials.x
    mesh.add materials.y
    mesh.add materials.z
    mesh.add materials.w
    mesh.add w.x
    mesh.add w.y
    mesh.add w.z
    mesh.add w.w
    mesh.add splatRange.x
    mesh.add splatRange.y
    mesh.add splatRange.z

proc addWall(top0, top1, bottom0, bottom1, normal, tint: Vec3, material: float32) =
  ## Connects two edges; degenerates to a single triangle when a corner
  ## pair coincides (a partial "connection"). Walls take the owning tile's
  ## skirt material (no blending) and are flat-shaded by their face normal.
  let
    materials = vec4(material, material, material, material)
    weight = cornerWeights[0]
  addTriangle(
    top0, top1, bottom0, normal, normal, normal, tint,
    materials, weight, weight, weight)
  addTriangle(
    top1, bottom1, bottom0, normal, normal, normal, tint,
    materials, weight, weight, weight)

proc faceNormal(h: array[4, float32]): Vec3 =
  ## Gradient normal of one tile's bilinear top surface (unit tile size).
  let
    slopeX = ((h[1] + h[3]) - (h[0] + h[2])) * 0.5
    slopeZ = ((h[2] + h[3]) - (h[0] + h[1])) * 0.5
  normalize(vec3(-slopeX, 1, -slopeZ))

proc cornerNormal(
    layer: QuadLayer, faceNormals: seq[Vec3], x, z, cornerIndex: int
): Vec3 =
  ## Averages the face normals of the tiles sharing this corner, but only
  ## those whose corner height matches exactly — smooth shading across
  ## continuous terrain, hard breaks at cliffs and disconnections.
  let
    cornerX = x + (cornerIndex and 1)
    cornerZ = z + (cornerIndex shr 1)
    myHeight = layer.tiles[z * layer.width + x].tops[cornerIndex]
  var total: Vec3
  for (tileX, tileZ, corner) in [
    (cornerX - 1, cornerZ - 1, 3), (cornerX, cornerZ - 1, 2),
    (cornerX - 1, cornerZ, 1), (cornerX, cornerZ, 0)
  ]:
    if tileX < 0 or tileX >= layer.width or tileZ < 0 or tileZ >= layer.depth:
      continue
    let i = tileZ * layer.width + tileX
    if not layer.tiles[i].exists or layer.tiles[i].tops[corner] != myHeight:
      continue
    total = total + faceNormals[i]
  if total.length < 0.001:
    vec3(0, 1, 0)
  else:
    total.normalize

proc cornerSurfaces(layer: QuadLayer, x, z, cornerIndex: int): Vec4 =
  ## Collects tile-center materials around one shared corner at this height.
  let
    cornerX = x + (cornerIndex and 1)
    cornerZ = z + (cornerIndex shr 1)
    myHeight = layer.tiles[z * layer.width + x].tops[cornerIndex]
  result = vec4(-1.0)
  for slot, (tileX, tileZ, corner) in [
    (cornerX - 1, cornerZ - 1, 3), (cornerX, cornerZ - 1, 2),
    (cornerX - 1, cornerZ, 1), (cornerX, cornerZ, 0)
  ]:
    if tileX < 0 or tileX >= layer.width or tileZ < 0 or tileZ >= layer.depth:
      continue
    let i = tileZ * layer.width + tileX
    if not layer.tiles[i].exists or layer.tiles[i].tops[corner] != myHeight:
      continue
    result[slot] = layer.tiles[i].material.float32

proc rebuildBlends() =
  ## Uploads four shared neighborhoods per tile without changing the mesh.
  var data: seq[float32]
  for layerIndex in 0 ..< layers.len:
    let layer = layers[layerIndex]
    if layer.water:
      continue
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let i = z * layer.width + x
        if not layer.tiles[i].exists:
          continue
        layers[layerIndex].tiles[i].blendFirst = data.len div 4
        for corner in 0 .. 3:
          let materials = cornerSurfaces(layer, x, z, corner)
          data.add [materials.x, materials.y, materials.z, materials.w]
  var capacity: GLint
  glGetIntegerv(GL_MAX_TEXTURE_BUFFER_SIZE, capacity.addr)
  if data.len div 4 > min(capacity.int, 16_777_215):
    raise newException(AigenError, "Terrain blend data exceeds GPU capacity.")
  if data.len == 0:
    data = @[0.0'f, 0.0'f, 0.0'f, 0.0'f]
  glBindBuffer(GL_TEXTURE_BUFFER, blendBuffer)
  glBufferData(
    GL_TEXTURE_BUFFER,
    data.len * sizeof(float32),
    data[0].addr,
    GL_STATIC_DRAW
  )
  glBindTexture(GL_TEXTURE_BUFFER, blendDataTexture)
  glTexBuffer(GL_TEXTURE_BUFFER, GL_RGBA32F, blendBuffer)
  glBindTexture(GL_TEXTURE_BUFFER, 0)
  glBindBuffer(GL_TEXTURE_BUFFER, 0)

proc isSteep(a, b, c: Vec3, cosLimit: float32): bool =
  ## True when the triangle's surface is steeper than the slope limit.
  let normal = cross(b - a, c - a)
  let length = normal.length
  length > 0 and abs(normal.y) / length < cosLimit

var layerWalkable: seq[seq[bool]]  # parallel to layers; filled per rebuild

proc computeWalkable(layer: QuadLayer, cosLimit: float32): seq[bool] =
  ## A tile is walkable when it exists, isn't force-marked impassable, and
  ## neither of its top triangles exceeds the slope limit.
  result = newSeq[bool](layer.tiles.len)
  if layer.water:
    return  # water is never walkable and never links to other layers
  for i, t in layer.tiles:
    if not t.exists or t.impassable:
      continue
    let h = t.tops.unpack
    let steep = isSteep(
        vec3(0, h[0], 0), vec3(1, h[1], 0), vec3(0, h[2], 1), cosLimit) or
      isSteep(
        vec3(1, h[1], 0), vec3(1, h[3], 1), vec3(0, h[2], 1), cosLimit)
    result[i] = not steep

type EdgeLink = object
  open: bool
  layer, x, z: int  # target tile when open

proc edgeLink(layerIndex, x, z, direction: int): EdgeLink =
  ## The walkable connection across one edge of a tile: to the in-layer
  ## neighbor when it is walkable, connected, and matches both corner heights
  ## exactly, otherwise to a matching walkable tile in another layer (e.g. a
  ## bridge deck landing on the ground). Directions: 0 east, 1 south,
  ## 2 west, 3 north. Used by both the border shader mask and A*.
  let
    layer = layers[layerIndex]
    h = layer.tiles[z * layer.width + x].tops
  var
    myA, myB: int16
    indexA, indexB, dx, dz: int
  case direction
  of 0: myA = h[1]; myB = h[3]; indexA = 0; indexB = 2; dx = 1
  of 1: myA = h[2]; myB = h[3]; indexA = 0; indexB = 1; dz = 1
  of 2: myA = h[0]; myB = h[2]; indexA = 1; indexB = 3; dx = -1
  else: myA = h[0]; myB = h[1]; indexA = 2; indexB = 3; dz = -1

  let
    nx = x + dx
    nz = z + dz
  if nx >= 0 and nx < layer.width and nz >= 0 and nz < layer.depth:
    let
      i = z * layer.width + x
      ni = nz * layer.width + nx
      connected = case direction
        of 0: layer.tiles[i].connectedEast
        of 1: layer.tiles[i].connectedSouth
        of 2: layer.tiles[ni].connectedEast
        else: layer.tiles[ni].connectedSouth
    if layerWalkable[layerIndex][ni] and connected and
        myA == layer.tiles[ni].tops[indexA] and
        myB == layer.tiles[ni].tops[indexB]:
      return EdgeLink(open: true, layer: layerIndex, x: nx, z: nz)

  let
    worldX = layer.originX + x + dx
    worldZ = layer.originZ + z + dz
  for li in 0 ..< layers.len:
    if li == layerIndex:
      continue
    let
      other = layers[li]
      lx = worldX - other.originX
      lz = worldZ - other.originZ
    if lx < 0 or lx >= other.width or lz < 0 or lz >= other.depth:
      continue
    let i = lz * other.width + lx
    if layerWalkable[li][i] and
        myA == other.tiles[i].tops[indexA] and
        myB == other.tiles[i].tops[indexB]:
      return EdgeLink(open: true, layer: li, x: lx, z: lz)
  EdgeLink(open: false)

proc emitLayer(layerIndex: int, layer: QuadLayer, floorY: float32) =
  let w = layer.width
  var faceNormals = newSeq[Vec3](layer.tiles.len)
  for i, t in layer.tiles:
    if t.exists:
      faceNormals[i] = faceNormal(t.tops.unpack)
  for z in 0 ..< layer.depth:
    for x in 0 ..< w:
      let
        i = z * w + x
        t = layer.tiles[i]
      if not t.exists:
        continue
      let
        x0 = (layer.originX + x).float32 - HalfGrid
        x1 = x0 + 1
        z0 = (layer.originZ + z).float32 - HalfGrid
        z1 = z0 + 1
        h = t.tops.unpack
        b = t.bottoms.unpack
        v00 = vec3(x0, h[0], z0)
        v10 = vec3(x1, h[1], z0)
        v01 = vec3(x0, h[2], z1)
        v11 = vec3(x1, h[3], z1)
        tileWalkable = layerWalkable[layerIndex][i]

      # Edge passability mask for the border shader: an edge is connected
      # (green) when its neighbor — in this layer or another one — is
      # walkable, connected, and matches both corner heights exactly.
      # Bits: east 1, south 2, west 4, north 8.
      var edgeMask = 0.0'f32
      if tileWalkable:
        for direction in 0 .. 3:
          if edgeLink(layerIndex, x, z, direction).open:
            edgeMask += float32(1 shl direction)

      let
        style = styleOf(t.kind)
        materials = vec4(t.material.float32)
        n0 = cornerNormal(layer, faceNormals, x, z, 0)
        n1 = cornerNormal(layer, faceNormals, x, z, 1)
        n2 = cornerNormal(layer, faceNormals, x, z, 2)
        n3 = cornerNormal(layer, faceNormals, x, z, 3)
      addTriangle(
        v00, v10, v01, n0, n1, n2, TopTint, materials,
        cornerWeights[0], cornerWeights[1], cornerWeights[2], edgeMask,
        vec3(t.splats.first.float32, t.splats.count.float32, t.blendFirst.float32))
      addTriangle(
        v10, v11, v01, n1, n3, n2, TopTint, materials,
        cornerWeights[1], cornerWeights[3], cornerWeights[2], edgeMask,
        vec3(t.splats.first.float32, t.splats.count.float32, t.blendFirst.float32))

      if layer.slab:
        # Underside of the slab; never walkable.
        let
          down = vec3(0, -1, 0)
          skirtMaterials = vec4(
            style.skirtMaterial, style.skirtMaterial,
            style.skirtMaterial, style.skirtMaterial)
        addTriangle(
          vec3(x0, b[0], z0), vec3(x1, b[1], z0), vec3(x0, b[2], z1),
          down, down, down, style.skirtTint, skirtMaterials,
          cornerWeights[0], cornerWeights[0], cornerWeights[0])
        addTriangle(
          vec3(x1, b[1], z0), vec3(x1, b[3], z1), vec3(x0, b[2], z1),
          down, down, down, style.skirtTint, skirtMaterials,
          cornerWeights[0], cornerWeights[0], cornerWeights[0])

      # East edge: side wall when open, connecting wall when heights differ.
      # Mismatch walls are emitted from the east/south side only, so each
      # shared edge produces exactly one wall.
      if x == w - 1 or not layer.tiles[z * w + x + 1].exists or not t.connectedEast:
        let
          y0 = if layer.slab: b[1] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(
          v10, v11, vec3(x1, y0, z0), vec3(x1, y1, z1), vec3(1, 0, 0),
          style.skirtTint, tileSkirt(t))
      else:
        let n = layer.tiles[z * w + x + 1]
        let nh = n.tops.unpack
        if h[1] != nh[0] or h[3] != nh[2]:
          # The cliff face belongs to the higher side; use its skirt style.
          let cliffTile = if h[1] + h[3] >= nh[0] + nh[2]: t else: n
          addWall(
            v10, v11, vec3(x1, nh[0], z0), vec3(x1, nh[2], z1), vec3(1, 0, 0),
            styleOf(cliffTile.kind).skirtTint, tileSkirt(cliffTile))
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[1] != nb[0] or b[3] != nb[2]:
            addWall(
              vec3(x1, b[1], z0), vec3(x1, b[3], z1),
              vec3(x1, nb[0], z0), vec3(x1, nb[2], z1), vec3(1, 0, 0),
              style.skirtTint, tileSkirt(t))

      # South edge.
      if z == layer.depth - 1 or not layer.tiles[(z + 1) * w + x].exists or not t.connectedSouth:
        let
          y0 = if layer.slab: b[2] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(
          v01, v11, vec3(x0, y0, z1), vec3(x1, y1, z1), vec3(0, 0, 1),
          style.skirtTint, tileSkirt(t))
      else:
        let n = layer.tiles[(z + 1) * w + x]
        let nh = n.tops.unpack
        if h[2] != nh[0] or h[3] != nh[1]:
          let cliffTile = if h[2] + h[3] >= nh[0] + nh[1]: t else: n
          addWall(
            v01, v11, vec3(x0, nh[0], z1), vec3(x1, nh[1], z1), vec3(0, 0, 1),
            styleOf(cliffTile.kind).skirtTint, tileSkirt(cliffTile))
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[2] != nb[0] or b[3] != nb[1]:
            addWall(
              vec3(x0, b[2], z1), vec3(x1, b[3], z1),
              vec3(x0, nb[0], z1), vec3(x1, nb[1], z1), vec3(0, 0, 1),
              style.skirtTint, tileSkirt(t))

      # West and north edges only need side walls when open (the neighbor,
      # if present and connected, already emitted any mismatch wall).
      if x == 0 or not layer.tiles[z * w + x - 1].exists or
          not layer.tiles[z * w + x - 1].connectedEast:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[2] else: floorY
        addWall(
          v00, v01, vec3(x0, y0, z0), vec3(x0, y1, z1), vec3(-1, 0, 0),
          style.skirtTint, tileSkirt(t))
      if z == 0 or not layer.tiles[(z - 1) * w + x].exists or
          not layer.tiles[(z - 1) * w + x].connectedSouth:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[1] else: floorY
        addWall(
          v00, v10, vec3(x0, y0, z0), vec3(x1, y1, z0), vec3(0, 0, -1),
          style.skirtTint, tileSkirt(t))

proc emitWaterSurface(layer: QuadLayer) =
  ## Pool surfaces over the riverbed tiles of the ground layer: water on the
  ## green half, lava on the rock half (heat 1). Flat tops plus side faces
  ## where a pool ends; drawn in its own transparent pass from waterMesh.
  proc addWaterTriangle(a, b, c, normal: Vec3, heat: float32) =
    for v in [a, b, c]:
      waterMesh.add v.x
      waterMesh.add v.y
      waterMesh.add v.z
      waterMesh.add normal.x
      waterMesh.add normal.y
      waterMesh.add normal.z
      waterMesh.add heat
  let w = layer.width
  proc pool(x, z: int): bool =
    x >= 0 and z >= 0 and x < w and z < layer.depth and
      layer.tiles[z * w + x].kind == RiverbedTile
  for z in 0 ..< layer.depth:
    for x in 0 ..< w:
      let t = layer.tiles[z * w + x]
      if not t.exists or t.kind != RiverbedTile:
        continue
      # Boundary side faces sit inset from the tile edge: terrain walls live
      # exactly on integer x/z planes, and a coplanar transparent quad
      # z-fights them. The top face stays full size.
      const Inset = 0.01'f32
      let
        heat = if t.rocky: 1.0'f32 else: 0.0'f32
        x0 = (layer.originX + x).float32 - HalfGrid
        x1 = x0 + 1
        z0 = (layer.originZ + z).float32 - HalfGrid
        z1 = z0 + 1
        xi0 = x0 + Inset
        xi1 = x1 - Inset
        zi0 = z0 + Inset
        zi1 = z1 - Inset
        top = PoolSurface
        bottom = PoolSurface - PoolDepth - bumpAmplitude - 0.2'f32
        up = vec3(0, 1, 0)
      addWaterTriangle(vec3(x0, top, z0), vec3(x1, top, z0), vec3(x0, top, z1), up, heat)
      addWaterTriangle(vec3(x1, top, z0), vec3(x1, top, z1), vec3(x0, top, z1), up, heat)
      if not pool(x + 1, z):
        addWaterTriangle(vec3(xi1, top, z0), vec3(xi1, top, z1), vec3(xi1, bottom, z0), vec3(1, 0, 0), heat)
        addWaterTriangle(vec3(xi1, top, z1), vec3(xi1, bottom, z1), vec3(xi1, bottom, z0), vec3(1, 0, 0), heat)
      if not pool(x - 1, z):
        addWaterTriangle(vec3(xi0, top, z0), vec3(xi0, top, z1), vec3(xi0, bottom, z0), vec3(-1, 0, 0), heat)
        addWaterTriangle(vec3(xi0, top, z1), vec3(xi0, bottom, z1), vec3(xi0, bottom, z0), vec3(-1, 0, 0), heat)
      if not pool(x, z + 1):
        addWaterTriangle(vec3(x0, top, zi1), vec3(x1, top, zi1), vec3(x0, bottom, zi1), vec3(0, 0, 1), heat)
        addWaterTriangle(vec3(x1, top, zi1), vec3(x1, bottom, zi1), vec3(x0, bottom, zi1), vec3(0, 0, 1), heat)
      if not pool(x, z - 1):
        addWaterTriangle(vec3(x0, top, zi0), vec3(x1, top, zi0), vec3(x0, bottom, zi0), vec3(0, 0, -1), heat)
        addWaterTriangle(vec3(x1, top, zi0), vec3(x1, bottom, zi0), vec3(x0, bottom, zi0), vec3(0, 0, -1), heat)

proc grassHabitat(layer: QuadLayer, x, z: int): tuple[elevation, slope: float32] =
  ## Smooths height and gradient over nearby ground to avoid tile-sized flecks.
  var
    elevation, gradientX, gradientZ: float32
    count = 0
  for dz in -2 .. 2:
    for dx in -2 .. 2:
      let
        nx = x + dx
        nz = z + dz
      if nx < 0 or nx >= layer.width or nz < 0 or nz >= layer.depth:
        continue
      let tile = layer.tiles[nz * layer.width + nx]
      if not tile.exists or tile.kind == StoneTile:
        continue
      let heights = tile.tops.unpack
      elevation += (heights[0] + heights[1] + heights[2] + heights[3]) * 0.25'f
      gradientX += (heights[1] + heights[3] - heights[0] - heights[2]) * 0.5'f
      gradientZ += (heights[2] + heights[3] - heights[0] - heights[1]) * 0.5'f
      inc count
  if count > 0:
    result.elevation = elevation / (count.float32 * max(levelHeight * 3, 0.001'f))
    result.slope = sqrt(gradientX * gradientX + gradientZ * gradientZ) /
      count.float32

proc rebuildMaterials() =
  ## Picks each tile's top material: the green half's grasses and soft
  ## surfaces, or the rock half's rock, gravel, cinder, and lava beds. The
  ## corner blend then feathers neighbors into each other.
  let regions = initGrassRegions(seed, grassPatchSize)
  var variety = initSimplex(seed xor 0x4242)
  variety.frequency = 0.09
  variety.octaves = 2
  for layerIndex in 0 ..< layers.len:
    let layer = layers[layerIndex]
    for i, tile in layer.tiles:
      let
        x = i mod layer.width
        z = i div layer.width
        rocky = tile.rocky
      var material = styleOf(tile.kind).topMaterial.int
      case tile.kind
      of GrassTile:
        if rocky:
          material =
            if variety.value(x.float32, z.float32) > 0.2: RubbleSurface
            else: RockGroundSurface
        else:
          # The meadow dries toward the river: olive and sparse grass take
          # over before the rock does.
          let
            habitat = grassHabitat(layer, x, z)
            dryness = smoothRamp(60, 44, z.float32 + 0.5)
          material = grassMaterial(
            regions,
            (layer.originX + x).float32 + 0.5'f,
            (layer.originZ + z).float32 + 0.5'f,
            habitat.elevation + dryness * 1.5'f32,
            habitat.slope
          )
      of RoadTile:
        material = if rocky: GravelSurface else: DirtSurface
      of BaseTile, StoneTile:
        material = if rocky: DarkStoneSurface else: CobbleSurface
      of MarshTile:
        material = if rocky: CinderSurface else: MarshSurface
      of RiverbedTile:
        material = if rocky: LavaBedSurface else: MarshSurface
      of TreeTile:
        material = ForestSurface
      of BoulderTile:
        material = RockGroundSurface
      else:
        discard
      layers[layerIndex].tiles[i].material = material

proc rebuildSplats() =
  ## Places brushes during map generation and uploads each tile's full span.
  var splats: seq[Splat]
  splatPlacements = 0
  peakSplatsPerTile = 0
  for layerIndex in 0 ..< layers.len:
    if layers[layerIndex].water:
      continue
    let layer = layers[layerIndex]
    var surfaces = newSeq[SplatTile](layer.tiles.len)
    for i, tile in layer.tiles:
      surfaces[i] = SplatTile(
        exists: tile.exists and tile.material < SplatMaterialCount,
        material: min(tile.material, SplatMaterialCount - 1),
        variants: 1,
        tops: tile.tops
      )
    let map = generateSplats(
      surfaces,
      layer.width,
      layer.depth,
      vec2(layer.originX.float32 - HalfGrid, layer.originZ.float32 - HalfGrid),
      seed.int64 * 7919 + layerIndex.int64 * 104729 + 53,
      splatsPerTile,
      splatPlacement,
      textureSize,
      SplatMaterialCount
    )
    for i, span in map.spans:
      peakSplatsPerTile = max(peakSplatsPerTile, span.count)
      layers[layerIndex].tiles[i].splats = SplatSpan(
        first: span.first + splats.len,
        count: span.count
      )
    splats.add(map.splats)
    splatPlacements += map.placements
  var capacity: GLint
  glGetIntegerv(GL_MAX_TEXTURE_BUFFER_SIZE, capacity.addr)
  if splats.len > min(capacity.int div 2, 16_777_215):
    raise newException(AigenError, "Splat data exceeds the GPU buffer capacity.")
  let data = splats.packedSplats()
  glBindBuffer(GL_TEXTURE_BUFFER, splatBuffer)
  glBufferData(
    GL_TEXTURE_BUFFER,
    data.len * sizeof(float32),
    data[0].addr,
    GL_DYNAMIC_DRAW
  )
  glBindTexture(GL_TEXTURE_BUFFER, splatDataTexture)
  glTexBuffer(GL_TEXTURE_BUFFER, GL_RGBA32F, splatBuffer)
  glBindTexture(GL_TEXTURE_BUFFER, 0)
  glBindBuffer(GL_TEXTURE_BUFFER, 0)

proc rebuildTerrain() =
  generateLayers()
  rebuildMaterials()
  rebuildBlends()
  rebuildSplats()
  mesh.setLen(0)
  waterMesh.setLen(0)
  let
    floorY = -levelHeight * 2 - 2
    cosLimit = cos(slopeLimit * PI.float32 / 180.0)
  layerWalkable.setLen(0)
  for layer in layers:
    layerWalkable.add computeWalkable(layer, cosLimit)
  for i in 0 ..< layers.len:
    emitLayer(i, layers[i], floorY)
  if waterEnabled:
    emitWaterSurface(layers[0])
  rebuildTreeMesh()
  if waterVertexBuffer != 0 and waterMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      waterMesh.len * sizeof(float32),
      waterMesh[0].addr,
      GL_DYNAMIC_DRAW
    )

  meshVertexCount = mesh.len div 21
  glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    mesh.len * sizeof(float32),
    mesh[0].addr,
    GL_DYNAMIC_DRAW
  )

glGenVertexArrays(1, vertexArray.addr)
glBindVertexArray(vertexArray)
glGenBuffers(1, vertexBuffer.addr)
rebuildTerrain()

block:
  const stride = (21 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(terrainProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let edgeMaskLocation = glGetAttribLocation(terrainProgram, "edgeMask")
  doAssert edgeMaskLocation >= 0
  glEnableVertexAttribArray(edgeMaskLocation.GLuint)
  glVertexAttribPointer(
    edgeMaskLocation.GLuint, 1, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
  let normalLocation = glGetAttribLocation(terrainProgram, "normal")
  doAssert normalLocation >= 0
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](4 * sizeof(float32))
  )
  let tileColorLocation = glGetAttribLocation(terrainProgram, "tileColor")
  doAssert tileColorLocation >= 0
  glEnableVertexAttribArray(tileColorLocation.GLuint)
  glVertexAttribPointer(
    tileColorLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](7 * sizeof(float32))
  )
  let materialsLocation = glGetAttribLocation(terrainProgram, "materials")
  doAssert materialsLocation >= 0
  glEnableVertexAttribArray(materialsLocation.GLuint)
  glVertexAttribPointer(
    materialsLocation.GLuint, 4, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](10 * sizeof(float32))
  )
  let cornerWeightLocation = glGetAttribLocation(terrainProgram, "cornerWeight")
  doAssert cornerWeightLocation >= 0
  glEnableVertexAttribArray(cornerWeightLocation.GLuint)
  glVertexAttribPointer(
    cornerWeightLocation.GLuint, 4, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](14 * sizeof(float32))
  )

block:
  let location = glGetAttribLocation(terrainProgram, "splatRange")
  doAssert location >= 0
  glEnableVertexAttribArray(location.GLuint)
  glVertexAttribPointer(
    location.GLuint,
    3,
    cGL_FLOAT,
    GL_FALSE,
    (21 * sizeof(float32)).GLsizei,
    cast[pointer](18 * sizeof(float32))
  )

## Sphere and path geometry, drawn with the solid shader.

proc bindSolidPosition() =
  let location = glGetAttribLocation(solidProgram, "vertPos")
  doAssert location >= 0
  glEnableVertexAttribArray(location.GLuint)
  glVertexAttribPointer(location.GLuint, 3, cGL_FLOAT, GL_FALSE, 0, nil)

var sphereMesh: seq[float32]
block:
  const
    Stacks = 10
    Slices = 16
  proc spherePoint(stack, slice: int): Vec3 =
    let
      phi = PI.float32 * stack.float32 / Stacks.float32
      theta = 2.0'f32 * PI.float32 * slice.float32 / Slices.float32
    vec3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
  for stack in 0 ..< Stacks:
    for slice in 0 ..< Slices:
      let
        a = spherePoint(stack, slice)
        b = spherePoint(stack + 1, slice)
        c = spherePoint(stack, slice + 1)
        d = spherePoint(stack + 1, slice + 1)
      for v in [a, b, c, c, b, d]:
        sphereMesh.add v.x
        sphereMesh.add v.y
        sphereMesh.add v.z

var sphereVertexArray, sphereVertexBuffer: GLuint
glGenVertexArrays(1, sphereVertexArray.addr)
glBindVertexArray(sphereVertexArray)
glGenBuffers(1, sphereVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, sphereVertexBuffer)
glBufferData(
  GL_ARRAY_BUFFER,
  sphereMesh.len * sizeof(float32),
  sphereMesh[0].addr,
  GL_STATIC_DRAW
)
bindSolidPosition()

var
  pathVertexArray, pathVertexBuffer: GLuint
  pathMesh: seq[float32]
glGenVertexArrays(1, pathVertexArray.addr)
glBindVertexArray(pathVertexArray)
glGenBuffers(1, pathVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, pathVertexBuffer)
bindSolidPosition()

glGenVertexArrays(1, propVertexArray.addr)
glBindVertexArray(propVertexArray)
glGenBuffers(1, propVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, propVertexBuffer)
block:
  const stride = (9 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(propProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let colorLocation = glGetAttribLocation(propProgram, "vertColor")
  doAssert colorLocation >= 0
  glEnableVertexAttribArray(colorLocation.GLuint)
  glVertexAttribPointer(
    colorLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
  let normalLocation = glGetAttribLocation(propProgram, "normal")
  doAssert normalLocation >= 0
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](6 * sizeof(float32))
  )
glGenVertexArrays(1, treeVertexArray.addr)
glBindVertexArray(treeVertexArray)
glGenBuffers(1, treeVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
block:
  const stride = (9 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(treeProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let uvLocation = glGetAttribLocation(treeProgram, "vertUv")
  doAssert uvLocation >= 0
  glEnableVertexAttribArray(uvLocation.GLuint)
  glVertexAttribPointer(
    uvLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
  let normalLocation = glGetAttribLocation(treeProgram, "normal")
  doAssert normalLocation >= 0
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](6 * sizeof(float32))
  )
glGenVertexArrays(1, waterVertexArray.addr)
glBindVertexArray(waterVertexArray)
glGenBuffers(1, waterVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
block:
  const stride = (7 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(waterProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let normalLocation = glGetAttribLocation(waterProgram, "normal")
  doAssert normalLocation >= 0
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
  let heatLocation = glGetAttribLocation(waterProgram, "heat")
  doAssert heatLocation >= 0
  glEnableVertexAttribArray(heatLocation.GLuint)
  glVertexAttribPointer(
    heatLocation.GLuint, 1, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](6 * sizeof(float32))
  )
glBindVertexArray(0)
rebuildTreeMesh()
if waterMesh.len > 0:
  glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    waterMesh.len * sizeof(float32),
    waterMesh[0].addr,
    GL_DYNAMIC_DRAW
  )

## Shadow map

const ShadowMapSize = 4096

# Steerable sun: azimuth swings the shadow direction around the map,
# elevation is the time of day. Defaults match the old fixed light
# direction (0.45, 0.8, 0.4). The orthographic box always covers the whole
# grid plus the tallest features.
var
  sunAzimuth = 48.0'f
  sunElevation = 53.0'f
  frustumMesh: seq[float32]
  frustumVertexArray, frustumVertexBuffer: GLuint

proc updateSun() =
  ## Recomputes the sun direction (shared by all lighting shaders), the
  ## light's view-projection, and the frustum wire box.
  const
    # Half the grid's diagonal plus room for the towers.
    LightRadius = float32(HalfGrid * 1.5 + 8)
    LightDistance = 150.0'f32
  let
    azimuth = sunAzimuth * PI.float32 / 180.0
    elevation = sunElevation * PI.float32 / 180.0
  sunDir = vec3(
    cos(elevation) * sin(azimuth),
    sin(elevation),
    cos(elevation) * cos(azimuth)
  )
  let
    view = lookAt(sunDir * LightDistance, vec3(0, 0, 0), vec3(0, 1, 0))
    proj = ortho(
      -LightRadius, LightRadius, -LightRadius, LightRadius,
      LightDistance - LightRadius, LightDistance + LightRadius)
  lightMvp = proj * view
  # The frustum's ortho box corners come from unprojecting the NDC cube
  # through the inverse light matrix.
  frustumMesh.setLen(0)
  let invLight = inverse(lightMvp)
  var corners: array[8, Vec3]
  for i in 0 ..< 8:
    let p = invLight * vec4(
      if (i and 1) != 0: 1.0 else: -1.0,
      if (i and 2) != 0: 1.0 else: -1.0,
      if (i and 4) != 0: 1.0 else: -1.0,
      1.0
    )
    corners[i] = vec3(p.x, p.y, p.z) / p.w
  for (a, b) in [(0, 1), (2, 3), (4, 5), (6, 7),
                 (0, 2), (1, 3), (4, 6), (5, 7),
                 (0, 4), (1, 5), (2, 6), (3, 7)]:
    for corner in [corners[a], corners[b]]:
      frustumMesh.add corner.x
      frustumMesh.add corner.y
      frustumMesh.add corner.z
  if frustumVertexBuffer != 0:
    glBindBuffer(GL_ARRAY_BUFFER, frustumVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      frustumMesh.len * sizeof(float32),
      frustumMesh[0].addr,
      GL_DYNAMIC_DRAW
    )

updateSun()
shadowTexel = 1.0'f32 / ShadowMapSize.float32

var shadowTexture, shadowFramebuffer: GLuint
glGenTextures(1, shadowTexture.addr)
glBindTexture(GL_TEXTURE_2D, shadowTexture)
glTexImage2D(
  GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint,
  ShadowMapSize, ShadowMapSize, 0,
  GL_DEPTH_COMPONENT, cGL_FLOAT, nil
)
# Linear + compare mode turns each sampler2DShadow tap into a bilinearly
# filtered comparison (hardware PCF). The debug view flips the compare
# mode off for its plain reads and restores it.
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
glTexParameteri(
  GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL.GLint)
glBindTexture(GL_TEXTURE_2D, 0)
glGenFramebuffers(1, shadowFramebuffer.addr)
glBindFramebuffer(GL_FRAMEBUFFER, shadowFramebuffer)
glFramebufferTexture2D(
  GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, shadowTexture, 0)
glDrawBuffer(GL_NONE)
glReadBuffer(GL_NONE)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
glBindFramebuffer(GL_FRAMEBUFFER, 0)

# Depth-pass vertex arrays: the same vertex buffers, but only the position
# attribute (plus uv and layer for the tree cutout).
var terrainDepthVertexArray: GLuint
glGenVertexArrays(1, terrainDepthVertexArray.addr)
glBindVertexArray(terrainDepthVertexArray)
glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
block:
  const stride = (21 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(depthProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
var propDepthVertexArray: GLuint
glGenVertexArrays(1, propDepthVertexArray.addr)
glBindVertexArray(propDepthVertexArray)
glBindBuffer(GL_ARRAY_BUFFER, propVertexBuffer)
block:
  const stride = (9 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(depthProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
var treeDepthVertexArray: GLuint
glGenVertexArrays(1, treeDepthVertexArray.addr)
glBindVertexArray(treeDepthVertexArray)
glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
block:
  const stride = (9 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(treeDepthProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let uvLocation = glGetAttribLocation(treeDepthProgram, "vertUv")
  doAssert uvLocation >= 0
  glEnableVertexAttribArray(uvLocation.GLuint)
  glVertexAttribPointer(
    uvLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )

# The sun's frustum wire box, refilled by updateSun() whenever the sun moves.
glGenVertexArrays(1, frustumVertexArray.addr)
glBindVertexArray(frustumVertexArray)
glGenBuffers(1, frustumVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, frustumVertexBuffer)
glBufferData(
  GL_ARRAY_BUFFER,
  frustumMesh.len * sizeof(float32),
  frustumMesh[0].addr,
  GL_DYNAMIC_DRAW
)
bindSolidPosition()

# Debug quad for the shadow map view; positions rebuilt per frame in NDC so
# the view stays square in pixels.
var shadowViewVertexArray, shadowViewVertexBuffer: GLuint
glGenVertexArrays(1, shadowViewVertexArray.addr)
glBindVertexArray(shadowViewVertexArray)
glGenBuffers(1, shadowViewVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, shadowViewVertexBuffer)
block:
  const stride = (5 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(shadowViewProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let uvLocation = glGetAttribLocation(shadowViewProgram, "vertUv")
  doAssert uvLocation >= 0
  glEnableVertexAttribArray(uvLocation.GLuint)
  glVertexAttribPointer(
    uvLocation.GLuint, 2, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
glBindVertexArray(0)

## Toon shading: the games' ramp and palettes (src/polyworld/toon.nim),
## plus their gradient background so the map doesn't float in a void.

var toonRampTexture: GLuint
glGenTextures(1, toonRampTexture.addr)
block:
  let ramp = rampImage()
  glBindTexture(GL_TEXTURE_2D, toonRampTexture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint, ramp.width.GLint, ramp.height.GLint,
    0, GL_RGBA, GL_UNSIGNED_BYTE, ramp.data[0].addr
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

let toonBackgroundProgram =
  compileProgram(ToonBackgroundVertSrc, ToonBackgroundFragSrc)
let toonSkyLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonSkyColor")
let toonHorizonLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonHorizonColor")
let toonGroundLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonGroundColor")
let toonHorizonHeightLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonHorizonHeight")
var toonBackgroundVertexArray, toonBackgroundVertexBuffer: GLuint
glGenVertexArrays(1, toonBackgroundVertexArray.addr)
glBindVertexArray(toonBackgroundVertexArray)
glGenBuffers(1, toonBackgroundVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, toonBackgroundVertexBuffer)
block:
  # One triangle covering clip space; the vertex shader reads only xy.
  var corners = [vec3(-1, -1, 0), vec3(3, -1, 0), vec3(-1, 3, 0)]
  glBufferData(
    GL_ARRAY_BUFFER, corners.len * sizeof(Vec3), corners[0].addr,
    GL_STATIC_DRAW
  )
  let positionLocation =
    glGetAttribLocation(toonBackgroundProgram, "vertexPosition")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, 0, nil)
glBindVertexArray(0)

## Camera

var
  cameraYaw = 0.0'f32   # from the south base, looking north
  cameraPitch = 0.95'f
  cameraDistance = 150.0'f
  cameraTarget = vec3(0, 0, 0)
  rotating = false
  panning = false
  showPanel = true
  showEdges = false
  showShadows = true
  showLightFrustum = false
  showShadowMap = false
  showToon = true
  toonHour = 12.0'f32  # picks the palette from the games' day cycle
  cameraEye = vec3(0, 0, 0)

## Atmosphere: one clock that drives everything. With the tie enabled, the
## hour positions the sun (or the moon at night), picks the toon palette,
## and scales both cast shadows and directional shading, so noon is crisp,
## twilight goes soft, and night is nearly flat moonlight.

var
  timeOfDay = 12.0'f32
  tieToTime = true

proc applyTimeOfDay() =
  ## Sun 6:00-20:00 arcing east to west; the moon rides the same track
  ## through the night, low and dim. sunUp is 0 at night, 1 at noon.
  let hour = ((timeOfDay mod 24) + 24) mod 24
  var sunUp = 0.0'f32
  if hour >= 6 and hour <= 20:
    let t = (hour - 6) / 14
    sunUp = sin(t * PI.float32)
    sunAzimuth = 90 + t * 180
    sunElevation = max(sunUp * 70, 12)
  else:
    let sinceSunset = if hour > 20: hour - 20 else: hour + 4
    let t = sinceSunset / 10
    sunAzimuth = 90 + t * 180
    sunElevation = max(sin(t * PI.float32) * 45, 12)
  toonHour = timeOfDay
  # One strength for both cast shadows and directional shading: they fade
  # out together through twilight to faint flat moonlight. Two separate
  # curves made the shading pop visibly right at sunset.
  let strength = 0.15'f32 + 0.7'f32 * smoothstep(0.0'f32, 0.3'f32, sunUp)
  shadowStrength = strength
  shadingStrength = strength

proc mouseOverUi(): bool =
  ## Hidden controls never intercept camera input.
  if not showPanel:
    return false
  for state in subWindowStates.values:
    if state.visible and sk.mousePos.overlaps(rect(state.pos, state.size)):
      return true
  false

proc cameraMvp(): Mat4 =
  let
    eyeOffset = vec3(
      sin(cameraYaw) * cos(cameraPitch),
      sin(cameraPitch),
      cos(cameraYaw) * cos(cameraPitch)
    ) * cameraDistance
    view = lookAt(cameraTarget + eyeOffset, cameraTarget, vec3(0, 1, 0))
    aspect = window.size.x.float32 / max(window.size.y.float32, 1)
    proj = perspective(45.0'f32, aspect, 0.1'f32, 1000.0'f32)
  cameraEye = cameraTarget + eyeOffset
  proj * view

## Pathfinding

type
  PlaceMode = enum
    NoPlacement, PlacingStart, PlacingFinish
  DragTarget = enum
    NoDrag, DragStart, DragFinish

var
  placeMode = NoPlacement
  dragTarget = NoDrag
  hasStart = false
  hasFinish = false
  startLayer, startX, startZ: int
  finishLayer, finishX, finishZ: int
  pathPoints: seq[Vec3]
  pathStatus = "Use the buttons to place points."

proc tileCenter(layerIndex, x, z: int): Vec3 =
  let
    layer = layers[layerIndex]
    h = layer.tiles[z * layer.width + x].tops.unpack
  vec3(
    (layer.originX + x).float32 - HalfGrid + 0.5,
    (h[0] + h[1] + h[2] + h[3]) / 4.0,
    (layer.originZ + z).float32 - HalfGrid + 0.5
  )

proc rayTriangle(origin, dir, a, b, c: Vec3): float32 =
  ## Ray-triangle intersection distance, or -1 when there is no hit.
  let
    edge1 = b - a
    edge2 = c - a
    p = cross(dir, edge2)
    det = dot(edge1, p)
  if abs(det) < 1e-6:
    return -1
  let
    invDet = 1.0'f32 / det
    tv = origin - a
    u = dot(tv, p) * invDet
  if u < 0 or u > 1:
    return -1
  let
    q = cross(tv, edge1)
    v = dot(dir, q) * invDet
  if v < 0 or u + v > 1:
    return -1
  let distance = dot(edge2, q) * invDet
  if distance > 0: distance else: -1

proc pickTile(): tuple[hit: bool, layer, x, z: int] =
  ## Casts a ray from the mouse into the scene and returns the nearest
  ## walkable tile top it hits, across all layers.
  let
    ndcX = 2.0'f32 * window.mousePos.x.float32 / window.size.x.float32 - 1
    ndcY = 1.0'f32 - 2.0'f32 * window.mousePos.y.float32 / window.size.y.float32
    inv = inverse(cameraMvp())
  var
    nearPoint = inv * vec4(ndcX, ndcY, -1, 1)
    farPoint = inv * vec4(ndcX, ndcY, 1, 1)
  let
    origin = nearPoint.xyz / nearPoint.w
    farPos = farPoint.xyz / farPoint.w
    dir = normalize(farPos - origin)
  var best = float32.high
  for li in 0 ..< layers.len:
    let layer = layers[li]
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let i = z * layer.width + x
        if not layerWalkable[li][i]:
          continue
        let
          h = layer.tiles[i].tops.unpack
          x0 = (layer.originX + x).float32 - HalfGrid
          z0 = (layer.originZ + z).float32 - HalfGrid
          v00 = vec3(x0, h[0], z0)
          v10 = vec3(x0 + 1, h[1], z0)
          v01 = vec3(x0, h[2], z0 + 1)
          v11 = vec3(x0 + 1, h[3], z0 + 1)
        for distance in [rayTriangle(origin, dir, v00, v10, v01),
            rayTriangle(origin, dir, v10, v11, v01)]:
          if distance > 0 and distance < best:
            best = distance
            result = (true, li, x, z)

proc nodeKey(layerIndex, x, z: int): int =
  (layerIndex * 4096 + z) * 4096 + x

proc findPath(): seq[Vec3] =
  ## A* over the edge-link graph between the start and finish tiles.
  if not (hasStart and hasFinish):
    return
  # Layers can disappear when toggled off; stale endpoints then have no path.
  if startLayer >= layers.len or finishLayer >= layers.len:
    return
  if not layerWalkable[startLayer][startZ * layers[startLayer].width + startX] or
      not layerWalkable[finishLayer][finishZ * layers[finishLayer].width + finishX]:
    return
  let
    startKey = nodeKey(startLayer, startX, startZ)
    goalKey = nodeKey(finishLayer, finishX, finishZ)
    goalCenter = tileCenter(finishLayer, finishX, finishZ)
  var
    frontier = initHeapQueue[(float32, int)]()
    cameFrom = initTable[int, int]()
    costSoFar = initTable[int, float32]()
  frontier.push((0.0'f32, startKey))
  costSoFar[startKey] = 0
  var found = false
  while frontier.len > 0:
    let (_, key) = frontier.pop()
    if key == goalKey:
      found = true
      break
    let
      x = key mod 4096
      z = (key div 4096) mod 4096
      li = key div (4096 * 4096)
      center = tileCenter(li, x, z)
    for direction in 0 .. 3:
      let link = edgeLink(li, x, z, direction)
      if not link.open:
        continue
      let
        nextKey = nodeKey(link.layer, link.x, link.z)
        nextCenter = tileCenter(link.layer, link.x, link.z)
        newCost = costSoFar[key] + dist(center, nextCenter)
      if nextKey notin costSoFar or newCost < costSoFar[nextKey]:
        costSoFar[nextKey] = newCost
        cameFrom[nextKey] = key
        frontier.push((newCost + dist(nextCenter, goalCenter), nextKey))
  if not found:
    return
  var key = goalKey
  while true:
    let
      x = key mod 4096
      z = (key div 4096) mod 4096
      li = key div (4096 * 4096)
    result.insert(tileCenter(li, x, z), 0)
    if key == startKey:
      break
    key = cameFrom[key]

proc rebuildPathMesh() =
  ## The path renders as a flat ribbon of quads through the tile centers,
  ## lifted a little so it doesn't z-fight the terrain.
  pathMesh.setLen(0)
  const
    HalfWidth = 0.12'f32
    Lift = 0.25'f32
  for i in 0 ..< max(0, pathPoints.len - 1):
    let
      a = pathPoints[i] + vec3(0, Lift, 0)
      b = pathPoints[i + 1] + vec3(0, Lift, 0)
      flat = vec3(b.x - a.x, 0, b.z - a.z)
      side = normalize(vec3(-flat.z, 0, flat.x)) * HalfWidth
    for v in [a - side, b - side, a + side, a + side, b - side, b + side]:
      pathMesh.add v.x
      pathMesh.add v.y
      pathMesh.add v.z
  if pathMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, pathVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      pathMesh.len * sizeof(float32),
      pathMesh[0].addr,
      GL_DYNAMIC_DRAW
    )

proc recomputePath() =
  pathPoints = findPath()
  if hasStart and hasFinish:
    if pathPoints.len > 0:
      pathStatus = &"Path found: {pathPoints.len} tiles."
    else:
      pathStatus = "No path: finish is unreachable."
  rebuildPathMesh()

## Line of sight
##
## The start marker is the observer. Every tile center gets a sight ray
## marched over the ground surface; the result is a one-value-per-tile
## visibility texture the terrain shader samples to fade hidden tiles to
## monochrome.

var
  visibilityTexture: GLuint
  visibilityData = newSeq[uint8](GridTiles * GridTiles)

proc groundSurfaceHeight(tx, tz: float32): float32 =
  ## Bilinear height of the ground layer's top surface at tile-space
  ## coordinates. Tree tiles are raised so forests block sight.
  let
    ix = clamp(int(tx), 0, GridTiles - 1)
    iz = clamp(int(tz), 0, GridTiles - 1)
    t = layers[0].tiles[iz * GridTiles + ix]
  if not t.exists:
    return -1000
  let
    h = t.tops.unpack
    fx = clamp(tx - ix.float32, 0, 1)
    fz = clamp(tz - iz.float32, 0, 1)
  result = (h[0] * (1 - fx) + h[1] * fx) * (1 - fz) +
    (h[2] * (1 - fx) + h[3] * fx) * fz
  if t.kind == TreeTile or t.kind == BoulderTile:
    result += 2.5

proc recomputeVisibility() =
  if visibilityTexture == 0:
    return  # texture not created yet during the initial rebuild
  var raw = newSeq[float32](GridTiles * GridTiles)
  if not losEnabled or not hasStart:
    for v in raw.mitems:
      v = 1.0
  else:
    let eye = tileCenter(startLayer, startX, startZ) + vec3(0, 1.7, 0)
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          tx = x.float32 + 0.5
          tz = z.float32 + 0.5
          target = vec3(
            tx - HalfGrid,
            groundSurfaceHeight(tx, tz) + 0.35,
            tz - HalfGrid
          )
          span = target - eye
          distance = span.length
        var visible = 1.0'f32
        # Skip both ray ends so neither the eye's own tile nor the target
        # tile's tree bump occludes the ray to itself.
        var s = 0.7'f32
        while s < distance - 0.9:
          let p = eye + span * (s / distance)
          if groundSurfaceHeight(p.x + HalfGrid, p.z + HalfGrid) > p.y:
            visible = 0.0
            break
          s += 0.4
        raw[z * GridTiles + x] = visible

  # A small box blur widens the visible/hidden boundary so the shader's
  # bilinear sample fades over about two tiles instead of one hard edge.
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      var total = 0.0'f32
      var count = 0
      for dz in -1 .. 1:
        for dx in -1 .. 1:
          let
            nx = x + dx
            nz = z + dz
          if nx < 0 or nx >= GridTiles or nz < 0 or nz >= GridTiles:
            continue
          total += raw[nz * GridTiles + nx]
          inc count
      visibilityData[z * GridTiles + x] =
        uint8(clamp(total / count.float32 * 255.0, 0.0, 255.0))
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glTexSubImage2D(
    GL_TEXTURE_2D, 0, 0, 0, GridTiles, GridTiles,
    GL_RED, GL_UNSIGNED_BYTE, visibilityData[0].addr
  )
  glBindTexture(GL_TEXTURE_2D, 0)

glGenTextures(1, visibilityTexture.addr)
glBindTexture(GL_TEXTURE_2D, visibilityTexture)
glTexImage2D(
  GL_TEXTURE_2D, 0, GL_R8.GLint, GridTiles, GridTiles, 0,
  GL_RED, GL_UNSIGNED_BYTE, nil
)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
glBindTexture(GL_TEXTURE_2D, 0)
recomputeVisibility()

## Input

proc updateCamera() =
  ## Handles camera gestures, marker placement, and the clean-view toggle.
  if window.buttonPressed[KeyF1]:
    showPanel = not showPanel
  let overUi = mouseOverUi()

  # Marker placement and dragging. The place buttons arm a one-shot
  # placement; once a marker exists, grabbing its tile drags it around with
  # the path (and the start's line-of-sight fade) updating live. Placing or
  # moving one marker never clears the other.
  var markerClick = false
  if window.buttonPressed[MouseLeft] and not overUi:
    let pick = pickTile()
    if pick.hit:
      case placeMode
      of PlacingStart:
        hasStart = true
        startLayer = pick.layer
        startX = pick.x
        startZ = pick.z
        dragTarget = DragStart
        placeMode = NoPlacement
        markerClick = true
        if not hasFinish:
          pathStatus = "Drag the start; place a finish for a path."
        recomputePath()
        recomputeVisibility()
      of PlacingFinish:
        hasFinish = true
        finishLayer = pick.layer
        finishX = pick.x
        finishZ = pick.z
        dragTarget = DragFinish
        placeMode = NoPlacement
        markerClick = true
        if not hasStart:
          pathStatus = "Drag the finish; place a start for a path."
        recomputePath()
      of NoPlacement:
        if hasStart and pick.layer == startLayer and
            pick.x == startX and pick.z == startZ:
          dragTarget = DragStart
          markerClick = true
        elif hasFinish and pick.layer == finishLayer and
            pick.x == finishX and pick.z == finishZ:
          dragTarget = DragFinish
          markerClick = true
  elif dragTarget != NoDrag and window.buttonDown[MouseLeft] and not overUi:
    let pick = pickTile()
    if pick.hit:
      if dragTarget == DragStart and (pick.layer != startLayer or
          pick.x != startX or pick.z != startZ):
        startLayer = pick.layer
        startX = pick.x
        startZ = pick.z
        recomputePath()
        recomputeVisibility()
      elif dragTarget == DragFinish and (pick.layer != finishLayer or
          pick.x != finishX or pick.z != finishZ):
        finishLayer = pick.layer
        finishX = pick.x
        finishZ = pick.z
        recomputePath()
  if not window.buttonDown[MouseLeft]:
    dragTarget = NoDrag

  if window.buttonPressed[MouseLeft] and not overUi and not markerClick:
    if window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]:
      panning = true
    else:
      rotating = true
  if window.buttonPressed[MouseRight] and not overUi:
    panning = true
  if not window.buttonDown[MouseLeft] and not window.buttonDown[MouseRight]:
    rotating = false
    panning = false

  let delta = window.mouseDelta.vec2
  if rotating:
    cameraYaw -= delta.x * 0.01
    cameraPitch = clamp(cameraPitch + delta.y * 0.01, 0.1, 1.55)
  if panning:
    let
      right = vec3(cos(cameraYaw), 0, -sin(cameraYaw))
      forward = vec3(-sin(cameraYaw), 0, -cos(cameraYaw))
      panSpeed = cameraDistance * 0.0015
    cameraTarget = cameraTarget - right * delta.x * panSpeed
    cameraTarget = cameraTarget + forward * delta.y * panSpeed
  if not overUi and window.scrollDelta.y != 0:
    cameraDistance = clamp(
      cameraDistance * pow(0.92'f32, window.scrollDelta.y), 5.0, 400.0)

## Frame

type
  PanelTab = enum
    TerrainTab, TexturesTab, ShadowTab, TreesTab, LayersTab, PathTab
  BlendView = enum
    PaintedView, MaterialView, WeightView, ReliefView

var
  panelTab = TerrainTab
  materialView = PaintedView

if existsEnv("BLEND_VIEW"):
  case getEnv("BLEND_VIEW")
  of "painted": materialView = PaintedView
  of "materials": materialView = MaterialView
  of "weights": materialView = WeightView
  of "height": materialView = ReliefView
  else:
    raise newException(AigenError, "Unknown BLEND_VIEW mode.")

template currentParams(): untyped =
  ## Every setting whose change needs the map regenerated.
  (seed, levelHeight, rampLength, laneWidth, jungleLaneWidth, bumpAmplitude,
    bumpFrequency, wobbleAmplitude, slopeLimit, treeDensity, grassCount,
    waterEnabled, treesEnabled, grassEnabled, rocksEnabled, rockCount,
    towersEnabled, treeHeight, boulderHeight, jungleTouchesLanes,
    splatsPerTile, splatPlacement,
    textureSize, grassPatchSize)

var lastParams = currentParams()
var lastLosEnabled = losEnabled
var lastSunParams = (sunAzimuth, sunElevation)

proc saveScreenshot() =
  ## Saves the rendered frame before swapping, with its current UI visibility.
  let
    image = newImage(window.size.x, window.size.y)
    path = getEnv("SCREENSHOT_PATH", "tmp/quadterrain_aigen.png")
  glReadPixels(
    0,
    0,
    window.size.x,
    window.size.y,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    image.data[0].addr
  )
  # The window is already composited; coverage alpha is not PNG transparency.
  for c in image.data.mitems:
    c.a = 255
  image.flipVertical()
  if path.parentDir.len > 0:
    createDir(path.parentDir)
  image.writeFile(path)
  echo "Screenshot saved: ", path

if existsEnv("SHOW_UI"):
  showPanel = getEnv("SHOW_UI") != "0"

when defined(takeScreenshot):
  var screenshotFrame = 0

when defined(takeScreenshot) or defined(frameTimer):
  # Use matching camera and scene overrides for captures and benchmarks.
  if existsEnv("CAM_YAW"): cameraYaw = getEnv("CAM_YAW").parseFloat.float32
  if existsEnv("CAM_PITCH"): cameraPitch = getEnv("CAM_PITCH").parseFloat.float32
  if existsEnv("CAM_DIST"): cameraDistance = getEnv("CAM_DIST").parseFloat.float32
  if existsEnv("CAM_X"): cameraTarget.x = getEnv("CAM_X").parseFloat.float32
  if existsEnv("CAM_Y"):
    cameraTarget.y = getEnv("CAM_Y").parseFloat.float32
  if existsEnv("CAM_Z"): cameraTarget.z = getEnv("CAM_Z").parseFloat.float32
  if existsEnv("SHOW_EDGES"): showEdges = getEnv("SHOW_EDGES") != "0"
  if existsEnv("PANEL_TAB"): panelTab = PanelTab(getEnv("PANEL_TAB").parseInt)
  if existsEnv("TOWERS"): towersEnabled = getEnv("TOWERS") != "0"
  if existsEnv("JUNGLE_TOUCH"): jungleTouchesLanes = getEnv("JUNGLE_TOUCH") != "0"
  if existsEnv("LOS"): losEnabled = getEnv("LOS") != "0"
  if existsEnv("WATER"): waterEnabled = getEnv("WATER") != "0"
  if existsEnv("TREES"): treesEnabled = getEnv("TREES") != "0"
  if existsEnv("GRASS"): grassEnabled = getEnv("GRASS") != "0"
  if existsEnv("TREE_HEIGHT"):
    treeHeight = getEnv("TREE_HEIGHT").parseFloat.float32
  if existsEnv("SHADOWS"): showShadows = getEnv("SHADOWS") != "0"
  if existsEnv("SUN_AZIMUTH"): sunAzimuth = getEnv("SUN_AZIMUTH").parseFloat.float32
  if existsEnv("SUN_ELEVATION"): sunElevation = getEnv("SUN_ELEVATION").parseFloat.float32
  if existsEnv("SHADOW_STRENGTH"): shadowStrength = getEnv("SHADOW_STRENGTH").parseFloat.float32
  if existsEnv("SHADOW_SOFTNESS"): shadowSoftness = getEnv("SHADOW_SOFTNESS").parseFloat.float32
  if existsEnv("TOON"): showToon = getEnv("TOON") != "0"
  if existsEnv("TOON_HOUR"): toonHour = getEnv("TOON_HOUR").parseFloat.float32
  if existsEnv("TIME_OF_DAY"): timeOfDay = getEnv("TIME_OF_DAY").parseFloat.float32
  if existsEnv("TIE_TIME"): tieToTime = getEnv("TIE_TIME") != "0"
  if existsEnv("SHADING_STRENGTH"): shadingStrength = getEnv("SHADING_STRENGTH").parseFloat.float32
  if existsEnv("SHADOW_FRUSTUM"): showLightFrustum = getEnv("SHADOW_FRUSTUM") != "0"
  if existsEnv("SHADOW_MAP_VIEW"): showShadowMap = getEnv("SHADOW_MAP_VIEW") != "0"
  # Scripted path test: PATH_START/PATH_FINISH as "layer,x,z".
  if existsEnv("PATH_START") and existsEnv("PATH_FINISH"):
    proc parseTile(s: string): array[3, int] =
      let parts = s.split(',')
      [parts[0].parseInt, parts[1].parseInt, parts[2].parseInt]
    let
      s = parseTile(getEnv("PATH_START"))
      f = parseTile(getEnv("PATH_FINISH"))
    hasStart = true
    startLayer = s[0]
    startX = s[1]
    startZ = s[2]
    hasFinish = true
    finishLayer = f[0]
    finishX = f[1]
    finishZ = f[2]
    recomputePath()
    recomputeVisibility()
  if existsEnv("DUMP_MAP"):
    # Environment overrides above changed settings after the first build;
    # regenerate now so the dump matches what the frame will show.
    if currentParams() != lastParams:
      lastParams = currentParams()
      rebuildTerrain()
      recomputePath()
    # Text map, north at the top: = road, / ramp, ~ pool, X tower pad,
    # T tree, O boulder, , wet ground, . ground, : high ground, # base,
    # ^ rim. Lower case marks the rocky (north) material set on roads.
    for z in 0 ..< GridTiles:
      var line = ""
      for x in 0 ..< GridTiles:
        let t = layers[0].tiles[z * GridTiles + x]
        var c =
          if t.ramp: '/'
          elif t.kind == RoadTile: '='
          elif t.kind == RiverbedTile: '~'
          elif t.kind == StoneTile: 'X'
          elif t.kind == TreeTile: 'T'
          elif t.kind == BoulderTile: 'O'
          elif t.level >= 4: '^'
          elif t.level == 3: '#'
          elif t.level == 2: ':'
          elif t.level == 1: '.'
          else: ','
        if c == '=' and t.rocky:
          c = '-'
        line.add c
      echo line
    var kindCounts: array[8, int]
    for t in layers[0].tiles:
      kindCounts[min(t.kind, 7'u32).int].inc
    echo "kinds grass/road/base/marsh/stone/tree/pool/boulder: ", kindCounts
    echo "towers: ", towerPlacements.len, " boulders+rocks: ", rockPlacements.len
    if hasStart or hasFinish:
      echo "path: ", pathStatus, " (", pathPoints.len, " waypoints)"
    for p in pathPoints:
      echo "  ", p.x + HalfGrid, " ", p.z + HalfGrid, " y=", p.y

when defined(frameTimer):
  import std/[monotimes, times]
  const
    WarmupFrames = 120
    MeasuredFrames = 600
  var
    timerFrame = 0
    timerStart: MonoTime
  window.size = ivec2(1280, 800)

window.onFrame = proc() =
  when defined(frameTimer):
    inc timerFrame
    if timerFrame == WarmupFrames:
      glFinish()
      echo "Frame size: ", window.size, "; splats: ", splatPlacements,
        "; peak overlap: ", peakSplatsPerTile,
        "; placement: ", splatPlacement, "; amount: ", splatPaint,
        "; enabled: ", showSplats, "; texture size: ", textureSize
      timerStart = getMonoTime()
    if timerFrame == WarmupFrames + MeasuredFrames:
      glFinish()
      let ms = (getMonoTime() - timerStart).inMicroseconds.float64 /
        1000.0 / MeasuredFrames.float64
      echo "avg frame ms: ", ms
      quit(0)
  updateCamera()

  let params = currentParams()
  if params != lastParams:
    lastParams = params
    rebuildTerrain()
    recomputePath()
    recomputeVisibility()
  if losEnabled != lastLosEnabled:
    lastLosEnabled = losEnabled
    recomputeVisibility()
  if tieToTime:
    applyTimeOfDay()
  if (sunAzimuth, sunElevation) != lastSunParams:
    lastSunParams = (sunAzimuth, sunElevation)
    updateSun()

  # Shadow depth pass: the sun's view of every caster, rendered before the
  # main pass so the surface shaders can sample the finished depth map.
  if showShadows or showShadowMap:
    glBindFramebuffer(GL_FRAMEBUFFER, shadowFramebuffer)
    glViewport(0, 0, ShadowMapSize, ShadowMapSize)
    glClear(GL_DEPTH_BUFFER_BIT)
    glEnable(GL_DEPTH_TEST)
    glUseProgram(depthProgram)
    glUniformMatrix4fv(
      depthLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
    glBindVertexArray(terrainDepthVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, meshVertexCount.GLsizei)
    if propMesh.len > 0:
      glBindVertexArray(propDepthVertexArray)
      glDrawArrays(GL_TRIANGLES, 0, (propMesh.len div 9).GLsizei)
    if treeMesh.len > 0:
      glUseProgram(treeDepthProgram)
      glUniformMatrix4fv(
        treeDepthLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
      glActiveTexture(GL_TEXTURE0)
      glBindTexture(GL_TEXTURE_2D_ARRAY, treeTextureArray)
      glUniform1i(treeDepthTexturesLocation, 0)
      glUniform1f(treeDepthAlphaCutoffLocation, TreeAlphaCutoff)
      glBindVertexArray(treeDepthVertexArray)
      glDrawArrays(GL_TRIANGLES, 0, (treeMesh.len div 9).GLsizei)
    glBindVertexArray(0)
    glUseProgram(0)
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    glViewport(0, 0, window.size.x, window.size.y)

  sk.beginUi(window, window.size)

  glClearColor(0.05, 0.06, 0.09, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)

  # Toon palette for this frame, and the games' gradient background: the
  # horizon glows with the highlight, the sky cools toward the shadow
  # color, the ground below is the shadow color darkened a little.
  let toonPalette = paletteAtHour(toonHour)
  if showToon:
    let
      horizonColor = mix(toonPalette.highlight, toonPalette.shadow, 0.25)
      skyColor = mix(toonPalette.highlight, toonPalette.shadow, 0.8)
      groundColor = toonPalette.shadow * 0.8
    glUseProgram(toonBackgroundProgram)
    glUniform4f(toonSkyLocation, skyColor.r, skyColor.g, skyColor.b, 1)
    glUniform4f(
      toonHorizonLocation, horizonColor.r, horizonColor.g, horizonColor.b, 1)
    glUniform4f(
      toonGroundLocation, groundColor.r, groundColor.g, groundColor.b, 1)
    glUniform1f(toonHorizonHeightLocation, 0.42)
    glDisable(GL_DEPTH_TEST)
    glDepthMask(GL_FALSE)
    glBindVertexArray(toonBackgroundVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, 3)
    glBindVertexArray(0)
    glDepthMask(GL_TRUE)
    glEnable(GL_DEPTH_TEST)
    glUseProgram(0)

  glUseProgram(terrainProgram)
  mvp = cameraMvp()
  glUniformMatrix4fv(mvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
  glUniform1f(borderWidthLocation, borderWidth)
  glUniform1f(heightScaleLocation, levelHeight * 4)
  glUniform1f(edgesEnabledLocation, if showEdges: 1.0 else: 0.0)
  glUniform1f(texScaleLocation, 1.0'f32 / textureSize)
  glUniform1f(blendDepthLocation, blendDepth)
  glUniform1f(heightBlendLocation, heightBlend)
  glUniform1f(heightBlendEnabledLocation, if useHeightBlend: 1.0 else: 0.0)
  glUniform1f(splatsEnabledLocation, if showSplats: 1.0 else: 0.0)
  glUniform1f(splatAmountLocation, splatPaint)
  glUniform1f(blendDebugLocation, materialView.ord.float32)
  glActiveTexture(GL_TEXTURE7)
  glBindTexture(GL_TEXTURE_BUFFER, blendDataTexture)
  glUniform1i(blendDataLocation, 7)
  glActiveTexture(GL_TEXTURE4)
  glBindTexture(GL_TEXTURE_2D_ARRAY, splatColorArray)
  glUniform1i(splatColorsLocation, 4)
  glActiveTexture(GL_TEXTURE5)
  glBindTexture(GL_TEXTURE_2D_ARRAY, splatHeightArray)
  glUniform1i(splatHeightsLocation, 5)
  glActiveTexture(GL_TEXTURE6)
  glBindTexture(GL_TEXTURE_BUFFER, splatDataTexture)
  glUniform1i(splatDataLocation, 6)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(visibilityTexLocation, 1)
  glUniform1f(visOffsetLocation, HalfGrid)
  glUniform1f(visScaleLocation, 1.0'f32 / GridTiles.float32)
  glActiveTexture(GL_TEXTURE2)
  glBindTexture(GL_TEXTURE_2D, shadowTexture)
  glUniform1i(terrainShadowMapLocation, 2)
  glUniformMatrix4fv(
    terrainLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
  glUniform1f(terrainShadowsEnabledLocation, if showShadows: 1.0 else: 0.0)
  glUniform1f(terrainShadowStrengthLocation, shadowStrength)
  glUniform1f(terrainShadowBiasLocation, shadowBias)
  glUniform1f(terrainShadowTexelLocation, shadowTexel)
  glUniform1f(terrainShadowSoftnessLocation, shadowSoftness)
  glUniform1f(terrainShadingStrengthLocation, shadingStrength)
  glUniform3f(terrainSunDirLocation, sunDir.x, sunDir.y, sunDir.z)
  glUniform1f(terrainToonEnabledLocation, if showToon: 1.0 else: 0.0)
  glUniform3f(
    terrainToonHighlightLocation, toonPalette.highlight.r,
    toonPalette.highlight.g, toonPalette.highlight.b)
  glUniform3f(
    terrainToonShadowLocation, toonPalette.shadow.r,
    toonPalette.shadow.g, toonPalette.shadow.b)
  glActiveTexture(GL_TEXTURE3)
  glBindTexture(GL_TEXTURE_2D, toonRampTexture)
  glUniform1i(terrainToonRampLocation, 3)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, terrainTextureArray)
  glUniform1i(terrainTexturesLocation, 0)
  glBindVertexArray(vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, meshVertexCount.GLsizei)
  glBindVertexArray(0)

  # Grass puffs.
  if propMesh.len > 0:
    glUseProgram(propProgram)
    glUniformMatrix4fv(propMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniformMatrix4fv(
      propLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
    glUniform1f(propShadowsEnabledLocation, if showShadows: 1.0 else: 0.0)
    glUniform1f(propShadowStrengthLocation, shadowStrength)
    glUniform1f(propShadowBiasLocation, shadowBias)
    glUniform1f(propShadowTexelLocation, shadowTexel)
    glUniform1f(propShadowSoftnessLocation, shadowSoftness)
    glUniform1f(propShadingStrengthLocation, shadingStrength)
    glUniform3f(propSunDirLocation, sunDir.x, sunDir.y, sunDir.z)
    glUniform1f(propToonEnabledLocation, if showToon: 1.0 else: 0.0)
    glUniform3f(
      propToonHighlightLocation, toonPalette.highlight.r,
      toonPalette.highlight.g, toonPalette.highlight.b)
    glUniform3f(
      propToonShadowLocation, toonPalette.shadow.r,
      toonPalette.shadow.g, toonPalette.shadow.b)
    glActiveTexture(GL_TEXTURE2)
    glBindTexture(GL_TEXTURE_2D, shadowTexture)
    glUniform1i(propShadowMapLocation, 2)
    glActiveTexture(GL_TEXTURE3)
    glBindTexture(GL_TEXTURE_2D, toonRampTexture)
    glUniform1i(propToonRampLocation, 3)
    glActiveTexture(GL_TEXTURE0)
    glBindVertexArray(propVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (propMesh.len div 9).GLsizei)
    glBindVertexArray(0)

  # Textured firs and boulders share one geometry stream.
  if treeMesh.len > 0:
    glUseProgram(treeProgram)
    glUniformMatrix4fv(treeMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, visibilityTexture)
    glUniform1i(treeVisibilityTexLocation, 1)
    glUniform1f(treeVisOffsetLocation, HalfGrid)
    glUniform1f(treeVisScaleLocation, 1.0'f32 / GridTiles.float32)
    glActiveTexture(GL_TEXTURE2)
    glBindTexture(GL_TEXTURE_2D, shadowTexture)
    glUniform1i(treeShadowMapLocation, 2)
    glUniformMatrix4fv(
      treeLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
    glUniform1f(treeShadowsEnabledLocation, if showShadows: 1.0 else: 0.0)
    glUniform1f(treeShadowStrengthLocation, shadowStrength)
    glUniform1f(treeShadowBiasLocation, shadowBias)
    glUniform1f(treeShadowTexelLocation, shadowTexel)
    glUniform1f(treeShadowSoftnessLocation, shadowSoftness)
    glUniform1f(treeShadingStrengthLocation, shadingStrength)
    glUniform3f(treeSunDirLocation, sunDir.x, sunDir.y, sunDir.z)
    glUniform1f(treeToonEnabledLocation, if showToon: 1.0 else: 0.0)
    glUniform3f(
      treeToonHighlightLocation, toonPalette.highlight.r,
      toonPalette.highlight.g, toonPalette.highlight.b)
    glUniform3f(
      treeToonShadowLocation, toonPalette.shadow.r,
      toonPalette.shadow.g, toonPalette.shadow.b)
    glActiveTexture(GL_TEXTURE3)
    glBindTexture(GL_TEXTURE_2D, toonRampTexture)
    glUniform1i(treeToonRampLocation, 3)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D_ARRAY, treeTextureArray)
    glUniform1i(treeTexturesLocation, 0)
    glUniform1f(treeAlphaCutoffLocation, TreeAlphaCutoff)
    glBindVertexArray(treeVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (treeMesh.len div 9).GLsizei)
    glBindVertexArray(0)

  # Start/finish spheres and the path ribbon.
  glUseProgram(solidProgram)
  let viewProjection = mvp
  if pathMesh.len > 0:
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 1.0, 0.85, 0.2)
    glBindVertexArray(pathVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (pathMesh.len div 3).GLsizei)
  if hasStart:
    mvp = viewProjection *
      translate(tileCenter(startLayer, startX, startZ) + vec3(0, 0.45, 0)) *
      scale(vec3(0.4))
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 1.0, 0.95, 0.15)
    glBindVertexArray(sphereVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (sphereMesh.len div 3).GLsizei)
  if hasFinish:
    mvp = viewProjection *
      translate(tileCenter(finishLayer, finishX, finishZ) + vec3(0, 0.45, 0)) *
      scale(vec3(0.4))
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 0.9, 0.25, 0.9)
    glBindVertexArray(sphereVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (sphereMesh.len div 3).GLsizei)
  # The sun's orthographic frustum as a yellow wire box.
  if showPanel and showLightFrustum and frustumMesh.len > 0:
    mvp = viewProjection
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 1.0, 0.8, 0.15)
    glBindVertexArray(frustumVertexArray)
    glDrawArrays(GL_LINES, 0, (frustumMesh.len div 3).GLsizei)
  glBindVertexArray(0)

  # Transparent water goes last, blended over everything opaque.
  if waterMesh.len > 0:
    glUseProgram(waterProgram)
    mvp = viewProjection
    glUniformMatrix4fv(waterMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(waterCameraLocation, cameraEye.x, cameraEye.y, cameraEye.z)
    glUniform3f(waterSunDirLocation, sunDir.x, sunDir.y, sunDir.z)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDepthMask(GL_FALSE)
    glBindVertexArray(waterVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (waterMesh.len div 7).GLsizei)
    glBindVertexArray(0)
    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)
  glUseProgram(0)

  glDisable(GL_DEPTH_TEST)

  # Shadow map debug view: the raw depth map in the lower-right corner.
  if showPanel and showShadowMap:
    let
      viewSize = 300.0'f32
      margin = 12.0'f32
      x0 = 1.0'f32 - 2.0'f32 * (margin + viewSize) / window.size.x.float32
      x1 = 1.0'f32 - 2.0'f32 * margin / window.size.x.float32
      y0 = -1.0'f32 + 2.0'f32 * margin / window.size.y.float32
      y1 = -1.0'f32 + 2.0'f32 * (margin + viewSize) / window.size.y.float32
    var quad: seq[float32]
    for (x, y, u, v) in [
      (x0, y0, 0.0'f32, 0.0'f32), (x1, y0, 1.0'f32, 0.0'f32),
      (x0, y1, 0.0'f32, 1.0'f32), (x0, y1, 0.0'f32, 1.0'f32),
      (x1, y0, 1.0'f32, 0.0'f32), (x1, y1, 1.0'f32, 1.0'f32)
    ]:
      quad.add x
      quad.add y
      quad.add 0.0
      quad.add u
      quad.add v
    glUseProgram(shadowViewProgram)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, shadowTexture)
    # Plain depth reads need the comparison mode off for this draw.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE.GLint)
    glUniform1i(shadowViewMapLocation, 0)
    glBindVertexArray(shadowViewVertexArray)
    glBindBuffer(GL_ARRAY_BUFFER, shadowViewVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      quad.len * sizeof(float32),
      quad[0].addr,
      GL_DYNAMIC_DRAW
    )
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(0)
    glBindTexture(GL_TEXTURE_2D, shadowTexture)
    glTexParameteri(
      GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glUseProgram(0)

  ui:
    subWindow("MOBA Map", showPanel, vec2(10, 10), vec2(340, 680)):
      text "capture help":
        characters "F1: toggle UI   F12: screenshot"
      group "tab row 1":
        box 310, 32
        layout LeftToRight
        itemSpacing 10
        radioButton "Terrain", panelTab, TerrainTab
        radioButton "Textures", panelTab, TexturesTab
        radioButton "Trees", panelTab, TreesTab
      group "tab row 2":
        box 310, 32
        layout LeftToRight
        itemSpacing 10
        radioButton "Shadow", panelTab, ShadowTab
        radioButton "Map", panelTab, LayersTab
        radioButton "Path", panelTab, PathTab
      var colorBlendView = materialView != PaintedView
      checkBox "Color blend view", colorBlendView
      if colorBlendView != (materialView != PaintedView):
        materialView =
          if colorBlendView:
            WeightView
          else:
            PaintedView
      case panelTab
      of TerrainTab:
        text "seed label":
          characters &"Seed: {seed}"
        scrubber "seed", seed, 0, 9999, ""
        text "seed hint":
          characters "Relief, edge wander, pools, planting"
        text "terrace title":
          characters "Terraces"
        text "level label":
          characters &"Terrace rise: {levelHeight:0.2f} tiles"
        scrubber "levelHeight", levelHeight, 0.5'f32, 4.0'f32, ""
        text "ramp label":
          characters &"Ramp length: {rampLength} tiles"
        scrubber "rampLength", rampLength, 2, 8, ""
        text "wobble label":
          characters &"Edge wander: {wobbleAmplitude:0.1f} tiles"
        scrubber "wobbleAmplitude", wobbleAmplitude, 0.0'f32, 6.0'f32, ""
        text "wobble hint":
          characters "Terrace edges stay straight at ramps"
        text "bump label":
          characters &"Relief: {bumpAmplitude:0.2f} tiles"
        scrubber "bumpAmplitude", bumpAmplitude, 0.0'f32, 0.6'f32, ""
        text "bump frequency label":
          characters &"Relief size: {int(round(1.0 / bumpFrequency))} tiles"
        scrubber "bumpFrequency", bumpFrequency, 0.04'f32, 0.4'f32, ""
        text "lanes title":
          characters "Lanes"
        text "lane label":
          characters &"Lane half width: {laneWidth:0.1f}"
        scrubber "laneWidth", laneWidth, 1.0'f32, 3.5'f32, ""
        text "jungle lane label":
          characters &"Jungle lane half width: {jungleLaneWidth:0.1f}"
        scrubber "jungleLaneWidth", jungleLaneWidth, 0.6'f32, 2.5'f32, ""
        text "slope label":
          characters &"Max slope: {int(slopeLimit)} deg"
        scrubber "slopeLimit", slopeLimit, 10.0'f32, 85.0'f32, ""
        text "border label":
          characters &"Tile border: {borderWidth:0.3f}"
        scrubber "border", borderWidth, 0.0'f32, 0.25'f32, ""
      of TexturesTab:
        text "material view":
          characters "Terrain view"
        group "material views":
          box 310, 32
          layout LeftToRight
          itemSpacing 10
          radioButton "Painted", materialView, PaintedView
          radioButton "Material IDs", materialView, MaterialView
        group "weight views":
          box 310, 32
          layout LeftToRight
          itemSpacing 10
          radioButton "Blend weights", materialView, WeightView
          radioButton "Height weights", materialView, ReliefView
        text "material view hint":
          characters "Before roads and splats"
        text "material view legend":
          characters "Pink: gravel. Green/gold: grass."
        text "texture title":
          characters "Texture size"
        text "texSize label":
          characters &"Tiles and splats: {textureSize:0.1f} world tiles"
        scrubber "textureSize", textureSize, 0.5'f, 12.0'f, ""
        text "texSize hint":
          characters "Bigger: calmer, broader strokes"
        text "painted materials":
          characters "Soft terrain: 4 grasses + 5 surfaces"
        text "grass patches":
          characters &"Grass patch size: {int(round(grassPatchSize))} tiles"
        scrubber "grassPatchSize", grassPatchSize, 8.0'f, 48.0'f, ""
        text "grass patches hint":
          characters "Bigger: larger grass clumps"
        checkBox "Splats", showSplats
        checkBox "Height-based blending", useHeightBlend
        text "splat placement":
          characters &"Splat placement: {splatPlacement * 100:0.0f}%"
        scrubber "splatPlacement", splatPlacement, 0.0'f, 1.0'f, ""
        text "splat amount":
          characters &"Splat amount: {splatPaint:0.2f}"
        scrubber "splatPaint", splatPaint, 0.0'f, 1.0'f, ""
        text "splat total":
          characters &"{splatPlacements} splats placed"
        text "splat overlap":
          characters &"Up to {peakSplatsPerTile} splats overlap a tile"
        text "blend title":
          characters "Blending"
        text "blendDepth label":
          characters &"Blend depth: {blendDepth:0.2f}"
        scrubber "blendDepth", blendDepth, 0.02'f32, 1.0'f32, ""
        text "blendDepth hint":
          characters "Smaller: more abrupt borders"
        text "heightBlend label":
          characters &"Height blend: {heightBlend:0.2f}"
        scrubber "heightBlend", heightBlend, 0.0'f32, 2.0'f32, ""
        text "heightBlend hint":
          characters "Higher: clumpier borders"
      of ShadowTab:
        text "time title":
          characters "Time of day"
        text "time label":
          characters &"Hour: {timeOfDay:0.1f}"
        scrubber "timeOfDay", timeOfDay, 0.0'f32, 24.0'f32, ""
        checkBox "Tie everything to the hour", tieToTime
        text "tie hint":
          characters "Drives sun, palette, and strengths"
        text "sun title":
          characters "Sun"
        text "sun azimuth label":
          characters &"Azimuth: {int(round(sunAzimuth))} deg"
        scrubber "sunAzimuth", sunAzimuth, 0.0'f32, 360.0'f32, ""
        text "sun azimuth hint":
          characters "Swings shadows around the map"
        text "sun elevation label":
          characters &"Elevation: {int(round(sunElevation))} deg"
        scrubber "sunElevation", sunElevation, 10.0'f32, 85.0'f32, ""
        text "sun elevation hint":
          characters "Time of day; low is long shadows"
        text "toon title":
          characters "Toon"
        checkBox "Toon shading", showToon
        text "toon hour label":
          characters &"Palette hour: {toonHour:0.1f}"
        scrubber "toonHour", toonHour, 0.0'f32, 24.0'f32, ""
        text "toon hour hint":
          characters "Day-cycle palettes from the games"
        text "shadow title":
          characters "Shadows"
        checkBox "Cast shadows", showShadows
        text "shadow strength label":
          characters &"Strength: {shadowStrength:0.2f}"
        scrubber "shadowStrength", shadowStrength, 0.0'f32, 1.0'f32, ""
        text "shadow strength hint":
          characters "1: shadows go pure black"
        text "shading label":
          characters &"Shading: {shadingStrength:0.2f}"
        scrubber "shadingStrength", shadingStrength, 0.0'f32, 1.0'f32, ""
        text "shading hint":
          characters "0: flat, no directional light"
        text "shadow softness label":
          characters &"Softness: {shadowSoftness:0.1f}"
        scrubber "shadowSoftness", shadowSoftness, 0.0'f32, 4.0'f32, ""
        text "shadow softness hint":
          characters "Wider: blurrier shadow edges"
        text "shadow bias label":
          characters &"Bias: {shadowBias:0.4f}"
        scrubber "shadowBias", shadowBias, 0.0'f32, 0.01'f32, ""
        text "shadow bias hint":
          characters "Up: fixes acne. Down: fixes gaps"
        text "shadow debug title":
          characters "Debug"
        checkBox "Show sun frustum", showLightFrustum
        checkBox "Show shadow map", showShadowMap
      of LayersTab:
        text "display title":
          characters "Display"
        checkBox "Show edges", showEdges
        checkBox "Line of sight fade", losEnabled
        text "features title":
          characters "Features"
        checkBox "Water and lava pools", waterEnabled
        checkBox "Towers", towersEnabled
        text "towers hint":
          characters "Three per lane per side, plus the base"
        text "props title":
          characters "Props"
        checkBox "Grass puffs", grassEnabled
        text "grass label":
          characters &"Grass puffs: {grassCount}"
        scrubber "grassCount", grassCount, 0, 500, ""
        checkBox "Rocks", rocksEnabled
        text "rocks label":
          characters &"Rocks: {rockCount}"
        scrubber "rockCount", rockCount, 0, 100, ""
      of TreesTab:
        checkBox "Trees", treesEnabled
        checkBox "Jungle touches lanes", jungleTouchesLanes
        text "touch hint":
          characters "Off: camps keep one tile back from roads"
        text "tree models":
          characters "Dense fir 01 + fir 02 from shadows"
        text "tree height label":
          characters &"Tree height: {treeHeight:0.1f} tiles"
        scrubber "treeHeight", treeHeight, 2.0'f32, 12.0'f32, ""
        text "trees label":
          characters &"Jungle density: {treeDensity:0.2f}"
        scrubber "treeDensity", treeDensity, 0.0'f32, 1.0'f32, ""
        text "trees hint":
          characters "Scales planting inside the jungle spots"
        text "jungle hint":
          characters "Spots ring themselves densely; lanes cut through"
        text "boulder title":
          characters "Rock half"
        text "boulder label":
          characters &"Boulder height: {boulderHeight:0.1f} tiles"
        scrubber "boulderHeight", boulderHeight, 1.0'f32, 5.0'f32, ""
        text "boulder hint":
          characters "Jungle spots north of the river grow boulders"
      of PathTab:
        text "path title":
          characters "Pathfinding"
        button "Place Start":
          placeMode = PlacingStart
          pathStatus = "Click a tile to place the start."
        button "Place Finish":
          placeMode = PlacingFinish
          pathStatus = "Click a tile to place the finish."
        text "path status":
          characters pathStatus
        text "help markers":
          characters "Drag a placed sphere to move it"
        text "help drag":
          characters "Drag: rotate"
        text "help pan":
          characters "Right/shift drag: pan"
        text "help zoom":
          characters "Scroll: zoom"

  sk.endUi()

  if window.buttonPressed[KeyF12]:
    saveScreenshot()

  when defined(takeScreenshot):
    inc screenshotFrame
    if screenshotFrame == 30:
      saveScreenshot()
      quit(0)

  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
