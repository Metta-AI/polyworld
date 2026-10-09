## Stylised water for quadterrain's water layers: planar reflections with a Fresnel mix,
## animated ripples, refraction, a tint, and shoreline foam and fade. It replaces the
## engine's default water shader; each water layer is drawn on its own, with its own
## parameters and its own reflection pass mirrored at its own surface.
##
## Use: call installWaters before initTerrain and initWaters after it, then once per view
## after the opaque scene, captureScene. For each body, beginReflection, draw the
## mirrored scene, restore the view framebuffer, then drawWaterBody.
##
## Reflections: the scene is rendered once more from the camera reflected in the water's
## surface (oblique near-plane clipping keeps out everything below it) into a texture the
## water reads at its own screen position. How much it reflects follows Schlick's Fresnel,
## with the reflectiveness as the reflectance looking straight down:
##
##   R(θ) = R0 + (1 − R0) · s · (1 − cos θ)^p
##
## where cos θ = dot(normal, toward the camera), R0 is the reflectiveness, s the Fresnel
## strength and p its power. The reflected sky has no sun: the sun reaches the water
## through its ripples, as a broad sheen and sharp glints, both weighted by that Fresnel:
##
##   sheen = sunColour · strength · R(θ) · pow(max(dot(reflect(view, normal), sun), 0), sharpness)
##
## Ripples: the surface's normal comes from a sum of travelling waves after afl_ext's
## "Very fast procedural ocean" (https://www.shadertoy.com/view/MdXyzX, MIT License,
## (c) 2017-2024 afl_ext). Each wave is exp(sin(x) - 1), sharp crests over flat troughs;
## each turns to a scattered direction, rises 1.18x in frequency and fades 20%, and its
## slope drags where the next one is sampled, so small ripples gather on larger ones.
## The normal tilts the reflection lookup (distortion), the Fresnel angle, the sheen and
## the glints, and flattens with distance so far water does not shimmer.
##
## Refraction: the scene's colour and depth are copied before the water draws, and the
## water draws that copy itself, read at a spot the ripples push sideways. The push grows
## with the water's depth up to refractionDepth, so the shoreline seam stays closed; a
## push landing on something in front of the water falls back to the straight lookup.
##
## Shorelines: each water layer has a shore distance field, built once from the terrain
## (see buildShoreFields): a grid of ShoreFieldResolution samples per world unit over the
## water and a margin around it, where ground above the water's surface is land, holding
## each sample's exact distance to the nearest land (a Euclidean distance transform). The
## water reads it once per pixel, filtered, so the distance is smooth, follows the visible
## bank and does not change with the camera. Two effects use it:
##   shoreline: a strip of foamColor foamDistance wide along the shore, with a soft outer
##              edge (foamSoftness, a fraction of its width) and foamOpacity. foamNoise
##              breaks it into foam: a tileable noise texture, foamScale world units across,
##              flowing toward the shore at foamSpeed along the field's gradient (the exact
##              direction to the nearest shore). Two copies of the noise slide along it half
##              a cycle apart, crossfading as each restarts (the flow-map technique), and
##              show where they exceed a threshold that rises across the strip, so the foam
##              is mostly solid at the waterline and scattered at the strip's outer edge.
##   fade: the water, shoreline included, blends into the scene behind it as it nears the
##         shore, alpha = (distance / fadeDistance)^fadeCurve.

import
  std/[math, random, times],
  chroma, opengl, shady, vmath,
  pathing, profiles, quadterrain

const
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop
  # Above the units the terrain (5-9), the toon shadows and drawWater (0-1) bind.
  ReflectionUnit = 10
  SceneDepthUnit = 11
  SceneColorUnit = 12
  ShoreFieldUnit = 13
  FoamNoiseUnit = 14
  ShoreFieldResolution* = 4 ## shore field samples per world unit
  ShoreFieldReach* = 8'f32 ## the furthest shore distance the field holds, in world units
  MaxWaves* = 32

type
  WaterParams* = object
    ## One body of water's look.
    color*: Vec3 ## the water's own colour, tinting what is seen through it
    colorStrength*: float32 ## 0 clear water, 1 only the colour shows through
    lift*: float32 ## world units the drawn surface rises above the baked one (visual only)
    reflectiveness*: float32 ## reflectance looking straight down: 0 none, 1 a mirror
    fresnelStrength*: float32 ## 0 reflects the same at every angle, 1 is Schlick's Fresnel
    fresnelPower*: float32 ## how sharply reflection rises towards grazing angles
    sheenStrength*: float32 ## the sun's glare over the water; 0 turns it off
    sheenSharpness*: float32 ## low spreads the glare over the water, high narrows it to the sun
    waveHeight*: float32 ## trough to crest of the summed ripples
    waveScale*: float32 ## world units per radian of the longest wave (its wavelength / 2π)
    waveSpeed*: float32 ## multiplies how fast the waves travel
    waveDrag*: float32 ## how much each wave's slope pulls the next; bunches ripples together
    waveCount*: float32 ## waves summed, 1 to MaxWaves; each adds shorter, fainter ripples
    rippleFade*: float32 ## distance from the camera at which ripples have flattened most
    distortion*: float32 ## how far the ripples bend the reflection, in screen fractions
    glintStrength*: float32 ## the sun's sharp sparkle on each ripple; 0 turns it off
    glintSharpness*: float32 ## higher makes glints smaller and tighter
    refraction*: float32 ## how far the ripples bend what is seen through the water
    refractionDepth*: float32 ## water depth at which the bending reaches full strength
    foamColor*: Vec3 ## the shoreline strip's colour
    foamDistance*: float32 ## the shoreline strip's width, from the waterline
    foamOpacity*: float32 ## 0 no shoreline strip, 1 solid
    foamSoftness*: float32 ## how much of the strip's width its outer edge softens over
    foamNoise*: float32 ## 0 a flat strip, 1 broken into noisy foam
    foamScale*: float32 ## world units across one tile of the foam's noise
    foamSpeed*: float32 ## world units per second the foam drifts toward the shore
    fadeDistance*: float32 ## distance from the shore over which the water fades in
    fadeCurve*: float32 ## 1 fades evenly; above 1 stays clear longer near the shore

  WaterBody* = object
    ## A water layer of the terrain and how to draw it.
    layer*: int ## the terrain layer index (layers[layer].water is true)
    params*: WaterParams

const
  DefaultWaterParams* = WaterParams(color: vec3(0.03'f32, 0.16, 0.18),
    colorStrength: 0.5, lift: 0, reflectiveness: 0.2, fresnelStrength: 1,
    fresnelPower: 4, sheenStrength: 0.9, sheenSharpness: 24, waveHeight: 0.15,
    waveScale: 1.5, waveSpeed: 0.7, waveDrag: 0.46, waveCount: 12, rippleFade: 150,
    distortion: 0.5, glintStrength: 40, glintSharpness: 300, refraction: 0.25,
    refractionDepth: 0.12, foamColor: vec3(1'f32, 1, 1), foamDistance: 0.95,
    foamOpacity: 1, foamSoftness: 0.28, foamNoise: 1, foamScale: 1.5, foamSpeed: 0.4,
    fadeDistance: 1.13, fadeCurve: 1)
    ## A calm lake or river.
  OceanWaterParams* = WaterParams(color: vec3(0.03'f32, 0.152, 0.178),
    colorStrength: 0.5, lift: 0, reflectiveness: 0.2, fresnelStrength: 1,
    fresnelPower: 4, sheenStrength: 0.9, sheenSharpness: 24, waveHeight: 2,
    waveScale: 2.74, waveSpeed: 0.7, waveDrag: 0.31, waveCount: 15, rippleFade: 150,
    distortion: 0.9, glintStrength: 40, glintSharpness: 2874, refraction: 0.25,
    refractionDepth: 0.12, foamColor: vec3(1'f32, 1, 1), foamDistance: 3.61,
    foamOpacity: 0.68, foamSoftness: 0.4, foamNoise: 1, foamScale: 3.51, foamSpeed: 0.99,
    fadeDistance: 0.3, fadeCurve: 1.02)
    ## An open sea around an island, with tall banks.

## Water shader.

var
  mvp: Uniform[Mat4]
  reflectionTex: Uniform[Sampler2D]
  sceneDepthTex: Uniform[Sampler2D]
  sceneColorTex: Uniform[Sampler2D]
  shoreField: Uniform[Sampler2D] # distance to the nearest shore, in world units
  foamNoiseTex: Uniform[Sampler2D]
  shoreFieldBounds: Uniform[Vec4] # the field's world x, z origin and x, z size
  inverseViewProjection: Uniform[Mat4]
  depthViewport: Uniform[Vec4] # the view's x, y, width, height as fractions of the window
  cameraPos: Uniform[Vec3] # drawWater sets it
  waterSunToward: Uniform[Vec3]
  sunColor: Uniform[Vec3]
  rippleClock: Uniform[float32] # wall-clock seconds, so ripples move even while paused
  waterColor: Uniform[Vec3]
  waterLift: Uniform[float32]
  colorStrength, reflectiveness, fresnelStrength, fresnelPower: Uniform[float32]
  sheenStrength, sheenSharpness, glintStrength, glintSharpness: Uniform[float32]
  waveHeight, waveScale, waveSpeed, waveDrag, waveCount: Uniform[float32]
  rippleFade, distortion, refraction, refractionDepth: Uniform[float32]
  foamColor: Uniform[Vec3]
  foamDistance, foamOpacity, foamSoftness, foamNoise, foamScale, foamSpeed: Uniform[float32]
  fadeDistance, fadeCurve: Uniform[float32]

proc watersVert(gl_Position: var Vec4, vertPos: Vec3, worldPos: var Vec3,
    screenPos: var Vec4) =
  ## Lifts and projects the water mesh and hands its world and clip positions to the
  ## fragment; drawWater sets mvp.
  worldPos = vec3(vertPos.x, vertPos.y + waterLift, vertPos.z)
  gl_Position = mvp * vec4(worldPos.x, worldPos.y, worldPos.z, 1.0)
  screenPos = gl_Position

proc waveSum(position: Vec2, count, speed, drag: float32): float32 =
  ## The ripples' height at `position` (in wave units), from 0 (trough) to 1 (crest).
  var
    p = position
    angle = 0.0
    frequency = 1.0
    timeScale = 2.0
    weight = 1.0
    total = 0.0
    weights = 0.0
  let phaseShift = length(position) * 0.1 # keeps the waves from lining up everywhere
  for i in 0 ..< MaxWaves:
    if float32(i) >= count:
      break
    let
      direction = vec2(sin(angle), cos(angle))
      x = dot(direction, p) * frequency + rippleClock * speed * timeScale + phaseShift
      wave = exp(sin(x) - 1.0)
      slope = -wave * cos(x)
    p = p + direction * (slope * weight * drag)
    total = total + wave * weight
    weights = weights + weight
    weight = weight * 0.8
    frequency = frequency * 1.18
    timeScale = timeScale * 1.07
    angle = angle + 1232.399963
  result = total / weights

proc sceneHeight(uv: Vec2): float32 =
  ## The world height of the scene point seen at `uv` in the copied depth.
  let
    ndc = vec2(
      (uv.x - depthViewport.x) / depthViewport.z * 2.0 - 1.0,
      (uv.y - depthViewport.y) / depthViewport.w * 2.0 - 1.0)
    point = inverseViewProjection *
      vec4(ndc.x, ndc.y, texture(sceneDepthTex, uv).x * 2.0 - 1.0, 1.0)
  result = point.y / point.w

proc watersFrag(fragColor: var Vec4, worldPos: Vec3, screenPos: Vec4) =
  ## Shows the scene behind this pixel, bent by the ripples and tinted, with the
  ## reflection, the sun's sheen and glints, foam, and the fade at the shore.
  let
    ndc = vec2(screenPos.x / screenPos.w, screenPos.y / screenPos.w)
    depthUv = vec2(
      depthViewport.x + (ndc.x * 0.5 + 0.5) * depthViewport.z,
      depthViewport.y + (ndc.y * 0.5 + 0.5) * depthViewport.w)
    straightDepth = max(worldPos.y - sceneHeight(depthUv), 0.0)
    toCamera: Vec3 = normalize(cameraPos - worldPos)
    # The ripples' normal from three height samples a few centimetres apart, flattened
    # with distance so far water does not shimmer.
    e = 0.02
    xz = vec2(worldPos.x, worldPos.z)
    h = waveSum(xz / waveScale, waveCount, waveSpeed, waveDrag) * waveHeight
    hx = waveSum((xz + vec2(e, 0.0)) / waveScale, waveCount, waveSpeed, waveDrag) * waveHeight
    hz = waveSum((xz + vec2(0.0, e)) / waveScale, waveCount, waveSpeed, waveDrag) * waveHeight
    flatten = clamp(length(cameraPos - worldPos) / rippleFade, 0.0, 1.0) * 0.85
    normal: Vec3 = normalize(mix(normalize(vec3(h - hx, e, h - hz)), vec3(0.0, 1.0, 0.0),
      flatten))
    # Refraction: read the scene where the ripples push the view, more in deeper water.
    bentUv = depthUv + vec2(normal.x, normal.z) *
      (refraction * clamp(straightDepth / refractionDepth, 0.0, 1.0))
    bentHeight = sceneHeight(bentUv)
  # A push onto something in front of the water, or outside this view, keeps the
  # straight view.
  var seenUv = bentUv
  if bentHeight > worldPos.y or bentUv.x < depthViewport.x or
      bentUv.y < depthViewport.y or bentUv.x >= depthViewport.x + depthViewport.z or
      bentUv.y >= depthViewport.y + depthViewport.w:
    seenUv = depthUv
  let
    seen: Vec3 = mix(texture(sceneColorTex, seenUv).xyz, waterColor, colorStrength)
    # The reflection pass is mirrored left to right (see reflectedCamera), so u runs
    # the other way; the ripples shift where it is read.
    reflection = texture(reflectionTex, vec2(0.5 - ndc.x * 0.5, 0.5 + ndc.y * 0.5) +
      vec2(normal.x, normal.z) * distortion).xyz
    # Schlick's Fresnel on the rippled surface.
    cosTheta = clamp(dot(normal, toCamera), 0.0, 1.0)
    r = reflectiveness + (1.0 - reflectiveness) * fresnelStrength *
      pow(1.0 - cosTheta, fresnelPower)
    # The view ray mirrored off the rippled surface, against the sun direction: a broad
    # sheen and a sharp glint on each ripple facing the sun.
    mirrored: Vec3 = normal * (2.0 * dot(normal, toCamera)) - toCamera
    toSun = max(dot(mirrored, waterSunToward), 0.0)
    sheen: Vec3 = sunColor * (sheenStrength * r * pow(toSun, sheenSharpness))
    glint: Vec3 = sunColor * (glintStrength * r * pow(toSun, glintSharpness))
    # reflection * r + (the tinted, refracted scene) * (1 - r); sheen and glint can
    # exceed 1 (the sun).
    color = seen * (1.0 - r) + reflection * r + sheen + glint
  let
    # The distance to the shore, from this layer's field; beyond it, far from any shore.
    fieldUv = vec2((worldPos.x - shoreFieldBounds.x) / shoreFieldBounds.z,
      (worldPos.z - shoreFieldBounds.y) / shoreFieldBounds.w)
  var
    shoreDistance = 1000.0
    toShore = vec2(0.0, 0.0)
  if fieldUv.x >= 0.0 and fieldUv.y >= 0.0 and fieldUv.x <= 1.0 and fieldUv.y <= 1.0:
    shoreDistance = texture(shoreField, fieldUv).x
    # The direction to the shore: down the field's gradient, a sample to each side.
    let
      stepUv = vec2(1.0 / (ShoreFieldResolution * shoreFieldBounds.z),
        1.0 / (ShoreFieldResolution * shoreFieldBounds.w))
      gradient = vec2(
        texture(shoreField, fieldUv + vec2(stepUv.x, 0.0)).x -
          texture(shoreField, fieldUv - vec2(stepUv.x, 0.0)).x,
        texture(shoreField, fieldUv + vec2(0.0, stepUv.y)).x -
          texture(shoreField, fieldUv - vec2(0.0, stepUv.y)).x)
    if length(gradient) > 0.0001:
      toShore = -normalize(gradient)
  let
    # Shoreline: a strip foamDistance wide from the waterline, its outer edge softened
    # over foamSoftness of its width.
    width = max(foamDistance, 0.001)
    strip = 1.0 - smoothstep(width * (1.0 - foamSoftness), width, shoreDistance)
    # Foam noise: two copies slide toward the shore, half a cycle apart, each fading out
    # as it restarts (with a fresh offset), so the motion never jumps or smears.
    scale = max(foamScale, 0.01)
    cycle = rippleClock * foamSpeed / scale
    phase0 = fract(cycle)
    phase1 = fract(cycle + 0.5)
    uv0: Vec2 = (xz - toShore * (phase0 * scale)) / scale + vec2(0.37, 0.61) * floor(cycle)
    uv1: Vec2 = (xz - toShore * (phase1 * scale)) / scale +
      vec2(0.61, 0.37) * floor(cycle + 0.5)
    noise = mix(texture(foamNoiseTex, uv0).x, texture(foamNoiseTex, uv1).x,
      abs(phase0 - 0.5) * 2.0)
    # The noise shows above a threshold rising across the strip, over the noise's
    # middle range: mostly foam at the waterline, scattered patches at the outer edge.
    threshold = mix(0.3, 0.7, clamp(shoreDistance / width, 0.0, 1.0))
    broken = smoothstep(threshold - 0.05, threshold + 0.05, noise)
    foam = strip * mix(1.0, broken, foamNoise) * foamOpacity
    # Fade: the water, shoreline included, gives way to the scene behind it toward the shore.
    alpha = pow(clamp(shoreDistance / max(fadeDistance, 0.001), 0.0, 1.0), fadeCurve)
    straight = texture(sceneColorTex, depthUv).xyz
    shaded: Vec3 = mix(straight, mix(color, foamColor, foam), alpha)
  fragColor = vec4(shaded.x, shaded.y, shaded.z, 1.0)

## Reflection sky: the background's colours laid out by view direction, without a sun.

var
  skyInverseViewProjection: Uniform[Mat4]
  skyEye, skyZenith, skyHorizon, skyGround: Uniform[Vec3]

proc waterSkyVert(gl_Position: var Vec4, vertPos: Vec2, ndc: var Vec2) =
  ## A full-screen triangle at the far plane.
  gl_Position = vec4(vertPos.x, vertPos.y, 1.0, 1.0)
  ndc = vertPos

proc waterSkyFrag(fragColor: var Vec4, ndc: Vec2) =
  ## The sky along this pixel's ray, from the eye through its point on the near plane (a
  ## reflection's oblique projection skews the far plane, which can land behind the eye).
  let
    nearPoint = skyInverseViewProjection * vec4(ndc.x, ndc.y, -1.0, 1.0)
    d: Vec3 = normalize(vec3(nearPoint.x, nearPoint.y, nearPoint.z) / nearPoint.w - skyEye)
  var color: Vec3 = mix(skyHorizon, skyZenith, sqrt(clamp(d.y, 0.0, 1.0)))
  if d.y < 0.0:
    color = mix(skyHorizon, skyGround, smoothstep(0.0, 0.55, -d.y))
  fragColor = vec4(color.x, color.y, color.z, 1.0)

## Runtime.

type ShoreField = object
  ## One water layer's distance to its shore, as a texture over a world rectangle.
  texture: GLuint
  origin, size: Vec2 ## world x, z of the field's corner, and its x, z extent

let startTime = epochTime()

var
  reflectionFbo, reflectionColor, reflectionDepth, blankTexture: GLuint
  reflectionSize: IVec2
  sceneCopyFbo, depthCopy, colorCopy, foamNoiseTexture: GLuint
  sceneCopySize: IVec2
  shoreFields: seq[ShoreField] ## per terrain layer; built lazily by drawWaterBody
  skyProgram, skyVertexArray, skyVertexBuffer: GLuint

proc tileableNoise(size = 256): seq[uint8] =
  ## Fractal value noise that wraps at its edges: five octaves of a random lattice
  ## (8 to 128 cells across), each smoothly interpolated with wrapping, summed with
  ## halving weights and stretched to 0..255.
  var
    rng = initRand(2026)
    total = newSeq[float32](size * size)
    weight = 1'f32
    cells = 8
  for octave in 0 ..< 5:
    var lattice = newSeq[float32](cells * cells)
    for value in lattice.mitems: value = rng.rand(1.0).float32
    for y in 0 ..< size:
      for x in 0 ..< size:
        let
          fx = x.float32 * cells.float32 / size.float32
          fy = y.float32 * cells.float32 / size.float32
          x0 = fx.int mod cells
          y0 = fy.int mod cells
          x1 = (x0 + 1) mod cells
          y1 = (y0 + 1) mod cells
          tx = fx - floor(fx)
          ty = fy - floor(fy)
          sx = tx * tx * (3 - 2 * tx)
          sy = ty * ty * (3 - 2 * ty)
          top = lattice[y0 * cells + x0] * (1 - sx) + lattice[y0 * cells + x1] * sx
          bottom = lattice[y1 * cells + x0] * (1 - sx) + lattice[y1 * cells + x1] * sx
        total[y * size + x] += (top * (1 - sy) + bottom * sy) * weight
    weight *= 0.5
    cells *= 2
  let
    low = min(total)
    high = max(total)
  result = newSeq[uint8](size * size)
  for i, value in total:
    result[i] = uint8((value - low) / (high - low) * 255)

proc compileStage(kind: GLenum, source: string): GLuint =
  ## Compiles one shader stage, raising with its log on failure.
  result = glCreateShader(kind)
  var text = allocCStringArray([source])
  glShaderSource(result, 1, text, nil)
  deallocCStringArray(text)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var log = newString(4096)
    var length: GLsizei
    glGetShaderInfoLog(result, 4096, length.addr, log.cstring)
    log.setLen(length)
    raise newException(ValueError, "water sky shader: " & log)

proc installWaters*() =
  ## Replaces the engine's water shader; call before initTerrain, which compiles it.
  waterPremultipliedAlpha = true
  waterShaderOverride = (
    toShader(watersVert, ShaderTarget, shaderVertex),
    toShader(watersFrag, ShaderTarget, shaderFragment))

proc initWaters*() =
  ## Creates the water's textures, framebuffers and sky; call after initTerrain.
  let program = waterShaderProgram()
  glUseProgram(program)
  glUniform1i(glGetUniformLocation(program, "reflectionTex"), ReflectionUnit)
  glUniform1i(glGetUniformLocation(program, "sceneDepthTex"), SceneDepthUnit)
  glUniform1i(glGetUniformLocation(program, "sceneColorTex"), SceneColorUnit)
  glUniform1i(glGetUniformLocation(program, "shoreField"), ShoreFieldUnit)
  glUniform1i(glGetUniformLocation(program, "foamNoiseTex"), FoamNoiseUnit)
  glUseProgram(0)
  glGenFramebuffers(1, sceneCopyFbo.addr)
  glGenTextures(1, depthCopy.addr)
  glGenTextures(1, colorCopy.addr)
  glGenFramebuffers(1, reflectionFbo.addr)
  glGenTextures(1, reflectionColor.addr)
  glGenRenderbuffers(1, reflectionDepth.addr)
  var noise = tileableNoise()
  glGenTextures(1, foamNoiseTexture.addr)
  glBindTexture(GL_TEXTURE_2D, foamNoiseTexture)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8.GLint, 256, 256, 0, GL_RED, GL_UNSIGNED_BYTE,
    noise[0].addr)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glGenerateMipmap(GL_TEXTURE_2D)
  # Bound for views without their own reflection pass, which reflect nothing.
  var white = [255'u8, 255, 255, 255]
  glGenTextures(1, blankTexture.addr)
  glBindTexture(GL_TEXTURE_2D, blankTexture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE,
    white[0].addr)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)
  let
    vertex = compileStage(GL_VERTEX_SHADER,
      toShader(waterSkyVert, ShaderTarget, shaderVertex))
    fragment = compileStage(GL_FRAGMENT_SHADER,
      toShader(waterSkyFrag, ShaderTarget, shaderFragment))
  skyProgram = glCreateProgram()
  glAttachShader(skyProgram, vertex)
  glAttachShader(skyProgram, fragment)
  glLinkProgram(skyProgram)
  glDetachShader(skyProgram, vertex)
  glDetachShader(skyProgram, fragment)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var triangle = [-1'f32, -1, 3, -1, -1, 3]
  glGenVertexArrays(1, skyVertexArray.addr)
  glBindVertexArray(skyVertexArray)
  glGenBuffers(1, skyVertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, skyVertexBuffer)
  glBufferData(GL_ARRAY_BUFFER, sizeof(triangle), triangle[0].addr, GL_STATIC_DRAW)
  let position = glGetAttribLocation(skyProgram, "vertPos")
  glEnableVertexAttribArray(position.GLuint)
  glVertexAttribPointer(position.GLuint, 2, cGL_FLOAT, GL_FALSE, 0, nil)
  glBindVertexArray(0)

proc drawWaterSky*(viewProjection: Mat4, eye: Vec3, zenith, horizon, ground: Color) =
  ## Fills the current viewport with a sky for reflections: the background's colours by
  ## view direction (horizon at eye level), writing no depth. Draw it first.
  var inverse = viewProjection.inverse
  glUseProgram(skyProgram)
  glUniformMatrix4fv(glGetUniformLocation(skyProgram, "skyInverseViewProjection"), 1,
    GL_FALSE, cast[ptr float32](inverse.addr))
  glUniform3f(glGetUniformLocation(skyProgram, "skyEye"), eye.x, eye.y, eye.z)
  glUniform3f(glGetUniformLocation(skyProgram, "skyZenith"), zenith.r, zenith.g, zenith.b)
  glUniform3f(glGetUniformLocation(skyProgram, "skyHorizon"), horizon.r, horizon.g,
    horizon.b)
  glUniform3f(glGetUniformLocation(skyProgram, "skyGround"), ground.r, ground.g, ground.b)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glBindVertexArray(skyVertexArray)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)
  glUseProgram(0)

proc reflectedCamera*(eye: Vec3, view, projection: Mat4,
    height: float32): tuple[eye: Vec3, view, projection: Mat4] =
  ## The camera mirrored in the water plane y = height. Its projection's near plane is the
  ## water itself (Lengyel's oblique clipping), so nothing below the surface is reflected,
  ## and it flips x so the mirrored triangles keep their winding for back-face culling.
  let mirror = translate(vec3(0, height, 0)) * scale(vec3(1'f32, -1, 1)) *
    translate(vec3(0, -height, 0))
  result.eye = vec3(eye.x, 2 * height - eye.y, eye.z)
  result.view = view * mirror
  let plane = transpose(inverse(result.view)) * vec4(0'f32, 1, 0, -height)
  var oblique = projection
  let
    q = inverse(projection) * vec4(sgn(plane.x).float32, sgn(plane.y).float32, 1, 1)
    c = plane * (2'f32 / dot(plane, q))
  for column in 0 .. 3:
    oblique[column, 2] = c[column] - oblique[column, 3]
  result.projection = scale(vec3(-1'f32, 1, 1)) * oblique

proc beginReflection*(size: IVec2) {.measure.} =
  ## Starts rendering a reflection into its texture, at the window's size.
  if size != reflectionSize:
    reflectionSize = size
    glBindTexture(GL_TEXTURE_2D, reflectionColor)
    # Half floats keep bright light above white; WebGL 2 cannot render to them without
    # an extension, so the browser keeps 8 bits.
    when defined(emscripten):
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y, 0, GL_RGBA,
        GL_UNSIGNED_BYTE, nil)
    else:
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F.GLint, size.x, size.y, 0, GL_RGBA,
        cGL_FLOAT, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glBindRenderbuffer(GL_RENDERBUFFER, reflectionDepth)
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, size.x, size.y)
    glBindRenderbuffer(GL_RENDERBUFFER, 0)
    glBindFramebuffer(GL_FRAMEBUFFER, reflectionFbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      reflectionColor, 0)
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
      reflectionDepth)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
      raise newException(ValueError, "water reflection framebuffer is incomplete")
  glBindFramebuffer(GL_FRAMEBUFFER, reflectionFbo)
  glViewport(0, 0, size.x, size.y)
  glClear(GL_DEPTH_BUFFER_BIT)

proc distanceTransform1D(f: openArray[float32], d: var openArray[float32],
    v: var seq[int], z: var seq[float32]) =
  ## Felzenszwalb and Huttenlocher's exact 1D squared distance transform: d[q] is the
  ## lowest (q - p)^2 + f[p] over all p.
  let n = f.len
  var k = 0
  v[0] = 0
  z[0] = -Inf
  z[1] = Inf
  for q in 1 ..< n:
    var s = ((f[q] + float32(q * q)) - (f[v[k]] + float32(v[k] * v[k]))) /
      float32(2 * q - 2 * v[k])
    while s <= z[k]:
      dec k
      s = ((f[q] + float32(q * q)) - (f[v[k]] + float32(v[k] * v[k]))) /
        float32(2 * q - 2 * v[k])
    inc k
    v[k] = q
    z[k] = s
    z[k + 1] = Inf
  k = 0
  for q in 0 ..< n:
    while z[k + 1] < float32(q):
      inc k
    d[q] = float32((q - v[k]) * (q - v[k])) + f[v[k]]

proc buildShoreField(layerIndex: int): ShoreField =
  ## Samples the visible ground around one water layer, ShoreFieldResolution times per
  ## world unit: ground above the water's surface is land. Each sample holds its distance
  ## to the nearest land, from the 2D Euclidean distance transform (columns, then rows),
  ## capped at ShoreFieldReach.
  let layer = layers[layerIndex]
  var
    loX = int.high
    loZ = int.high
    hiX = int.low
    hiZ = int.low
  for z in 0 ..< layer.depth:
    for x in 0 ..< layer.width:
      if layer.tiles[z * layer.width + x].exists:
        loX = min(loX, x)
        loZ = min(loZ, z)
        hiX = max(hiX, x)
        hiZ = max(hiZ, z)
  if loX > hiX:
    return
  let
    margin = ShoreFieldReach
    surface = waterLayerSurfaces[layerIndex]
    resolution = ShoreFieldResolution.float32
  result.origin = vec2((layer.originX + loX).float32 - HalfGrid - margin,
    (layer.originZ + loZ).float32 - HalfGrid - margin)
  result.size = vec2((hiX - loX + 1).float32 + 2 * margin,
    (hiZ - loZ + 1).float32 + 2 * margin)
  let
    w = int(result.size.x * resolution)
    h = int(result.size.y * resolution)
    far = float32((w + h) * (w + h))
  var squared = newSeq[float32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        worldX = result.origin.x + (x.float32 + 0.5) / resolution
        worldZ = result.origin.y + (y.float32 + 0.5) / resolution
        ground = surfaceHeight(worldX, worldZ) + groundOffset(worldX, worldZ)
      squared[y * w + x] = if ground >= surface: 0'f32 else: far
  var
    line = newSeq[float32](max(w, h))
    lineOut = newSeq[float32](max(w, h))
    v = newSeq[int](max(w, h))
    z = newSeq[float32](max(w, h) + 1)
  for x in 0 ..< w:
    for y in 0 ..< h: line[y] = squared[y * w + x]
    distanceTransform1D(line.toOpenArray(0, h - 1), lineOut.toOpenArray(0, h - 1), v, z)
    for y in 0 ..< h: squared[y * w + x] = lineOut[y]
  var distances = newSeq[float32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w: line[x] = squared[y * w + x]
    distanceTransform1D(line.toOpenArray(0, w - 1), lineOut.toOpenArray(0, w - 1), v, z)
    for x in 0 ..< w:
      distances[y * w + x] = min(sqrt(lineOut[x]) / resolution, ShoreFieldReach)
  glGenTextures(1, result.texture.addr)
  glBindTexture(GL_TEXTURE_2D, result.texture)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R16F.GLint, w.GLsizei, h.GLsizei, 0, GL_RED,
    cGL_FLOAT, distances[0].addr)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

proc buildShoreFields*() =
  ## (Re)builds every water layer's shore distance field from the current terrain.
  ## drawWaterBody builds them on first use; call this after the terrain or its
  ## relief changes.
  for field in shoreFields:
    if field.texture != 0:
      var texture = field.texture
      glDeleteTextures(1, texture.addr)
  shoreFields.setLen(layers.len)
  for i in 0 ..< layers.len:
    shoreFields[i] =
      if layers[i].water and i < waterLayerSurfaces.len: buildShoreField(i)
      else: ShoreField()

proc captureScene*(size: IVec2) {.measure.} =
  ## Copies the window's colour and depth into colorCopy and depthCopy. The depth texture
  ## matches the window's 24-bit depth, 8-bit stencil format, which a depth blit requires;
  ## a multisampled window is resolved by the blit.
  if size != sceneCopySize:
    sceneCopySize = size
    glBindTexture(GL_TEXTURE_2D, depthCopy)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8.GLint, size.x, size.y, 0,
      GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, colorCopy)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y, 0, GL_RGBA,
      GL_UNSIGNED_BYTE, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glBindFramebuffer(GL_FRAMEBUFFER, sceneCopyFbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      colorCopy, 0)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D,
      depthCopy, 0)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
      raise newException(ValueError, "water scene-copy framebuffer is incomplete")
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0)
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, sceneCopyFbo)
  glBlitFramebuffer(0, 0, size.x, size.y, 0, 0, size.x, size.y,
    GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT, GL_NEAREST.GLenum)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc reflecting*(params: WaterParams): bool =
  ## Whether this water shows reflections, so it needs its reflection pass.
  params.reflectiveness > 0 or params.fresnelStrength > 0

proc drawWaterBody*(body: WaterBody, viewProjection: Mat4, eye: Vec3, windowSize: IVec2,
    sunToward: Vec3, sunLight: Color, rect: IVec4, reflected: bool) {.measure.} =
  ## Draws one body of water over the captured scene.
  if shoreFields.len != layers.len:
    buildShoreFields()
  let
    params = body.params
    vertices = waterLayerRanges[body.layer]
    program = waterShaderProgram()
  if vertices.len == 0:
    return
  glUseProgram(program)
  var inverse = viewProjection.inverse
  glUniformMatrix4fv(glGetUniformLocation(program, "inverseViewProjection"), 1, GL_FALSE,
    cast[ptr float32](inverse.addr))
  glUniform4f(glGetUniformLocation(program, "depthViewport"),
    rect.x / windowSize.x, rect.y / windowSize.y,
    rect.z / windowSize.x, rect.w / windowSize.y)
  template uniform(name: string, value: float32) =
    glUniform1f(glGetUniformLocation(program, name), value)
  template uniform(name: string, value: Vec3) =
    glUniform3f(glGetUniformLocation(program, name), value.x, value.y, value.z)
  uniform("waterColor", params.color)
  uniform("sunColor", vec3(sunLight.r, sunLight.g, sunLight.b))
  uniform("waterSunToward", sunToward)
  uniform("waterLift", params.lift)
  # A view without its reflection pass reflects nothing at any angle.
  uniform("reflectiveness", if reflected: params.reflectiveness else: 0)
  uniform("fresnelStrength", if reflected: params.fresnelStrength else: 0)
  uniform("colorStrength", params.colorStrength)
  uniform("fresnelPower", params.fresnelPower)
  uniform("sheenStrength", params.sheenStrength)
  uniform("sheenSharpness", params.sheenSharpness)
  uniform("glintStrength", params.glintStrength)
  uniform("glintSharpness", params.glintSharpness)
  uniform("waveHeight", params.waveHeight)
  uniform("waveScale", max(params.waveScale, 0.001))
  uniform("waveSpeed", params.waveSpeed)
  uniform("waveDrag", params.waveDrag)
  uniform("waveCount", params.waveCount)
  uniform("rippleFade", max(params.rippleFade, 0.001))
  uniform("distortion", params.distortion)
  uniform("refraction", params.refraction)
  uniform("refractionDepth", max(params.refractionDepth, 0.001))
  uniform("foamColor", params.foamColor)
  uniform("foamDistance", params.foamDistance)
  uniform("foamOpacity", params.foamOpacity)
  # GLSL leaves smoothstep undefined for equal edges.
  uniform("foamSoftness", clamp(params.foamSoftness, 0.01, 1))
  uniform("foamNoise", clamp(params.foamNoise, 0, 1))
  uniform("foamScale", params.foamScale)
  uniform("foamSpeed", params.foamSpeed)
  uniform("fadeDistance", params.fadeDistance)
  uniform("fadeCurve", params.fadeCurve)
  let field = shoreFields[body.layer]
  glUniform4f(glGetUniformLocation(program, "shoreFieldBounds"), field.origin.x,
    field.origin.y, max(field.size.x, 0.001), max(field.size.y, 0.001))
  # Wrapped every 10,000 s to keep float32 precision; the jump is rare and brief.
  uniform("rippleClock", float32((epochTime() - startTime) mod 10_000))
  glUseProgram(0)
  for (unit, texture) in [
    (ReflectionUnit, if reflected: reflectionColor else: blankTexture),
    (SceneDepthUnit, depthCopy), (SceneColorUnit, colorCopy),
    (ShoreFieldUnit, shoreFields[body.layer].texture),
    (FoamNoiseUnit, foamNoiseTexture)
  ]:
    glActiveTexture(GLenum(GL_TEXTURE0.int + unit))
    glBindTexture(GL_TEXTURE_2D, texture)
  glActiveTexture(GL_TEXTURE0)
  drawWater(viewProjection, eye, firstVertex = vertices.a, vertexCount = vertices.len)
