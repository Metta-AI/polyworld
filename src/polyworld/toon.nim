## Toon (cel) shading for gltf node trees, in the classic console style:
##
## 1. Per-vertex Lambert from exactly one light: `max(dot(N, L), 0)`, no
##    shadow maps, no ambient occlusion, no other lights. One light means one
##    lit region and one shadow region, so the silhouette stays readable.
## 2. That intensity is used as a texture coordinate into a 256 wide ramp:
##    black up to about 47%, white from about 53%, and a short gradient
##    between. The tiny gradient gives the slightly soft terminator most cel
##    shaders miss; the ramp is data, so it can be reshaped.
## 3. White maps to a hand-picked highlight colour, black to a shadow colour,
##    and the result multiplies the albedo. Palettes are per world state
##    (time of day x weather); a set of twelve lives in `ToonPalettes`.
##
## An optional rim light is available through `rimColor`; its alpha is the
## strength.
##
## Eyes and mouths read best when never shaded: node names in `unlitNodes`
## are drawn always full-bright, albedo times the highlight colour, no shadow
## band, no rim.
##
## The shaders are written with Shady and draw the same GPU buffers the gltf
## PBR renderer uploads, so a scene can switch between the two per frame.

import
  std/sets,
  opengl, vmath, chroma, pixie, shady,
  gltf,
  shadows

## Shaders

var
  toonModel: Uniform[Mat4]
  toonNormalMatrix: Uniform[Mat3]
  toonView: Uniform[Mat4]
  toonProj: Uniform[Mat4]
  toonUseSkinning: Uniform[bool]
  toonJointMatrices: Uniform[array[128, Mat4]]
  toonLightDirection: Uniform[Vec3]   # direction the light travels
  toonCameraPosition: Uniform[Vec3]
  toonBaseColorTexture: Uniform[Sampler2d]
  toonBaseColorFactor: Uniform[Vec4]
  toonEmissiveTexture: Uniform[Sampler2d]
  toonEmissiveFactor: Uniform[Vec3]
  toonAlphaCutoff: Uniform[float32]
  toonRamp: Uniform[Sampler2d]
  toonHighlightColor: Uniform[Vec4]
  toonShadowColor: Uniform[Vec4]
  toonRimColor: Uniform[Vec4]
  toonUnlit: Uniform[bool]           # always in the highlight band
  toonUnlitReceivesShadow: Uniform[bool]
    ## convoy/unlit-shadow-receive: when an unlit node also opts into this,
    ## the unlit branch below multiplies by the sun shadow term instead of
    ## discarding it -- no ramp, no N.L, so ramp-banding cannot return.
  toonUnlitShadowDark: Uniform[float32]
    ## Darkest multiply an unlit+shadow-receiving fragment can reach, fully
    ## in the sun's own shadow. 1.0 = no visible darkening.
  toonSmoothShaded: Uniform[bool]
    ## terrain-lighting (convoy/terrain-lighting): opts a node out of the
    ## 2-3 band toon ramp into a continuous ambient N.L diffuse, and turns
    ## on the explicit cast-shadow multiply below (`toonSmoothShadowDark`).
    ## False by construction for every node until a game opts one in, so
    ## the OFF path (nobody sets this) is byte-identical to before this
    ## uniform existed.
  toonSmoothShadowDark: Uniform[float32]
    ## terrain-lighting: multiply floor a `toonSmoothShaded` fragment's
    ## OWN lit colour reaches in full cast shadow (a darker, slightly
    ## cooler version of the same colour -- never a flat grey blend, the
    ## owner's ruling). 1.0 = no visible darkening.
  toonTint: Uniform[Vec4]
  toonFogColor: Uniform[Vec4]
    ## terrain-lighting (convoy/terrain-lighting): distance fog blends
    ## geometry into the horizon rather than letting the terrain mesh's
    ## own silhouette meet the sky as a hard edge. Set to the SAME colour
    ## as the background gradient's own `toonHorizonColor` uniform
    ## (`toonBackgroundFrag`, a separate shader) -- never a flat grey --
    ## so a fogged fragment blends toward exactly what the sky already
    ## looks like at the horizon, not an invented haze colour.
  toonFogNear: Uniform[float32]
  toonFogFar: Uniform[float32]
    ## World-unit distance from the camera where the fog blend starts/
    ## reaches full strength. `toonFogFar > toonFogNear` is the caller's
    ## job to guarantee; this shader only ever divides by their
    ## difference guarded by `max(..., 0.001)` (see `toonFrag` below).
  toonFogOn: Uniform[bool]
    ## False by construction until a game opts in (`ctx.fogOn`,
    ## `newToonContext`'s own default) -- the OFF path never evaluates
    ## the blend below, reproducing pre-fog pixels exactly.
  # Sun shadow map sampling, fed from polyworld/shadows each frame. Two
  # maps at neighbouring quantized sun steps, cross-faded by toonShadowStep
  # so shadows dissolve toward the next sun position instead of shimmering.
  toonShadowMvp0: Uniform[Mat4]
  toonShadowMvp1: Uniform[Mat4]
  toonShadowMap0: Uniform[Sampler2dShadow]
  toonShadowMap1: Uniform[Sampler2dShadow]
  toonShadowStep: Uniform[float32]
  toonShadowsOn: Uniform[float32]
  toonShadowStrength: Uniform[float32]
  toonShadowBias: Uniform[float32]
  toonShadowTexel: Uniform[float32]
  toonShadowSoftness: Uniform[float32]
  toonShadingStrength: Uniform[float32]

proc toonLitFraction0(worldPos: Vec3): float32 =
  ## Raw lit fraction from the first shadow step, 0 shadowed .. 1 clear: a
  ## 3x3 grid of hardware-PCF taps, each itself bilinearly filtered by the
  ## comparison sampler. Positions outside the map count as lit.
  result = 1.0'f
  let
    shadowCoord: Vec4 = toonShadowMvp0 * vec4(worldPos, 1.0'f)
    su = shadowCoord.x * 0.5'f + 0.5'f
    sv = shadowCoord.y * 0.5'f + 0.5'f
    sd = shadowCoord.z * 0.5'f + 0.5'f - toonShadowBias
  if su > 0.0'f and su < 1.0'f and sv > 0.0'f and sv < 1.0'f and sd < 1.0'f:
    let spread = toonShadowTexel * toonShadowSoftness
    var lit = 0.0'f32
    lit = lit + texture(toonShadowMap0, vec3(su - spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su, sv - spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su + spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su - spread, sv, sd))
    lit = lit + texture(toonShadowMap0, vec3(su, sv, sd))
    lit = lit + texture(toonShadowMap0, vec3(su + spread, sv, sd))
    lit = lit + texture(toonShadowMap0, vec3(su - spread, sv + spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su, sv + spread, sd))
    lit = lit + texture(toonShadowMap0, vec3(su + spread, sv + spread, sd))
    result = lit / 9.0'f

proc toonLitFraction1(worldPos: Vec3): float32 =
  ## The same for the second shadow step.
  result = 1.0'f
  let
    shadowCoord: Vec4 = toonShadowMvp1 * vec4(worldPos, 1.0'f)
    su = shadowCoord.x * 0.5'f + 0.5'f
    sv = shadowCoord.y * 0.5'f + 0.5'f
    sd = shadowCoord.z * 0.5'f + 0.5'f - toonShadowBias
  if su > 0.0'f and su < 1.0'f and sv > 0.0'f and sv < 1.0'f and sd < 1.0'f:
    let spread = toonShadowTexel * toonShadowSoftness
    var lit = 0.0'f32
    lit = lit + texture(toonShadowMap1, vec3(su - spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su, sv - spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su + spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su - spread, sv, sd))
    lit = lit + texture(toonShadowMap1, vec3(su, sv, sd))
    lit = lit + texture(toonShadowMap1, vec3(su + spread, sv, sd))
    lit = lit + texture(toonShadowMap1, vec3(su - spread, sv + spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su, sv + spread, sd))
    lit = lit + texture(toonShadowMap1, vec3(su + spread, sv + spread, sd))
    result = lit / 9.0'f

proc sunShadowFactor(worldPos: Vec3): float32 =
  ## How lit by the sun a fragment is, cross-fading between the two
  ## quantized sun steps. The result already folds in the shadow strength.
  result = 1.0'f
  if toonShadowsOn > 0.5'f:
    let lit = mix(
      toonLitFraction0(worldPos), toonLitFraction1(worldPos), toonShadowStep)
    result = 1.0'f - (1.0'f - lit) * toonShadowStrength

proc toonVert(
  vertexPosition: Vec3,
  vertexColor: Vec4,
  vertexNormal: Vec3,
  vertexUV: Vec2,
  vertexTangent: Vec4,
  vertexJoints: UVec4,
  vertexWeights: Vec4,
  vertexUV1: Vec2,
  gl_Position: var Vec4,
  worldPos: var Vec3,
  color: var Vec4,
  normal: var Vec3,
  uv: var Vec2,
  lightIntensity: var float32
) =
  var skin = mat4(1.0'f)
  if toonUseSkinning:
    skin =
      vertexWeights.x * toonJointMatrices[vertexJoints.x.int] +
      vertexWeights.y * toonJointMatrices[vertexJoints.y.int] +
      vertexWeights.z * toonJointMatrices[vertexJoints.z.int] +
      vertexWeights.w * toonJointMatrices[vertexJoints.w.int]
  let
    skinnedPosition = skin * vec4(vertexPosition, 1.0'f)
    skinnedNormal = (skin * vec4(vertexNormal, 0.0'f)).xyz
  worldPos = (toonModel * skinnedPosition).xyz
  color = vertexColor
  uv = vertexUV
  normal = normalize(toonNormalMatrix * skinnedNormal)
  # Step 1: Lambert from the one light, computed per vertex like the
  # GameCube did and interpolated across the triangle.
  let toLight: Vec3 = normalize(-toonLightDirection)
  lightIntensity = max(dot(normal, toLight), 0.0'f)
  gl_Position = toonProj * toonView * vec4(worldPos, 1.0'f)

proc toonFrag(
  worldPos: Vec3,
  color: Vec4,
  normal: Vec3,
  uv: Vec2,
  lightIntensity: float32,
  fragColor: var Vec4
) =
  let albedo: Vec4 = texture(toonBaseColorTexture, uv) * toonBaseColorFactor * color
  if albedo.a < toonAlphaCutoff:
    discardFragment()
  # Step 2: the intensity — scaled by the sun shadow test, flattened by the
  # shading strength when the sky is dark — is a texture coordinate into
  # the ramp. Unlit parts (eyes, mouth) skip it and sit in the highlight
  # band forever.
  let
    sunFactor = sunShadowFactor(worldPos)
    intensity = 1.0'f - toonShadingStrength +
      lightIntensity * sunFactor * toonShadingStrength
  var band = texture(toonRamp, vec2(intensity, 0.5'f)).r
  if toonSmoothShaded:
    # terrain-lighting: a continuous AMBIENT N.L diffuse term, bypassing
    # the 2-3 band toon ramp entirely -- that ramp is what banded the
    # ridge slopes in bible rounds 44/46, the reason the terrain was made
    # `unlit` in the first place. Owner ruling 2026-09-23 overrides that:
    # the ground must be lit, so this gives it a smooth gradient instead
    # of the character ramp. Deliberately NOT `intensity` above -- that
    # already folds in `sunFactor`, and MEASURED (t850, lone Outrider):
    # the shared `toonShadowColor`/`toonHighlightColor` pair is close
    # enough in VALUE (an "Afternoon" palette tuned for a subtle vehicle
    # cel-shade, not a dramatic cast shadow) that routing the cast shadow
    # through this same blend only ever reached ~6-11% pixel darkening --
    # nowhere near "the ground is hit by the sun." The cast shadow gets
    # its OWN, stronger, explicit multiply below instead
    # (`toonSmoothShadowDark`); this term stays shadow-map-free so the two
    # never compound into a double-dark reading on the same pixel.
    band = 1.0'f - toonShadingStrength + lightIntensity * toonShadingStrength
  if toonUnlit:
    band = 1.0'f
    if toonUnlitReceivesShadow:
      # Shadow-only multiply: no ramp, no N.L term, so the ridge-slope
      # banding the unlit branch exists to avoid cannot return. sunFactor
      # is already PCF-softened by sunShadowFactor above; renormalize by
      # toonShadowStrength so toonUnlitShadowDark is the exact floor at
      # full shadow regardless of that global strength setting.
      let shadowTerm = clamp(
        (1.0'f - sunFactor) / max(toonShadowStrength, 0.0001'f), 0.0'f, 1.0'f)
      band = mix(1.0'f, toonUnlitShadowDark, shadowTerm)
  # Step 3: two hand-picked colours, then the albedo on top.
  var lit: Vec3 = mix(toonShadowColor.rgb, toonHighlightColor.rgb, band)
  if toonSmoothShaded:
    # THE GROUND IS HIT BY THE SUN, cast-shadow multiply. Owner ruling
    # 2026-09-23, verbatim: "a shadow is the ground's own colour made
    # darker... never a grey layer painted on top." This darkens the
    # ground's OWN already-computed `lit` colour (which still carries the
    # ambient ridge/basin shading and, two lines below, the surface's own
    # albedo) toward `toonSmoothShadowDark` (~0.5-0.6: roughly HALF as
    # bright, never fully black) with a slight per-channel cool skew (a
    # touch more blue, a touch less red -- the sky-fill idea, applied as a
    # multiply so it can never grey out a saturated hue the way a flat
    # blend toward grey would). `shadowTerm` mirrors `toonUnlitReceivesShadow`'s
    # own normalization: `sunFactor` is PCF-softened already, divided by
    # `toonShadowStrength` so `toonSmoothShadowDark` is the exact floor at
    # full shadow regardless of the day/night strength curve.
    let
      shadowTerm = clamp(
        (1.0'f - sunFactor) / max(toonShadowStrength, 0.0001'f), 0.0'f, 1.0'f)
      coolDark = vec3(
        toonSmoothShadowDark * 0.94'f, toonSmoothShadowDark * 0.99'f,
        toonSmoothShadowDark * 1.07'f)
    lit = lit * mix(vec3(1.0'f, 1.0'f, 1.0'f), coolDark, shadowTerm)
  var n: Vec3 = normalize(normal)
  if not gl_FrontFacing:
    n = -n
  let
    eye: Vec3 = normalize(toonCameraPosition - worldPos)
    facing = 1.0'f - abs(dot(eye, n))
    rim = facing * facing * facing * facing
  if not toonUnlit:
    lit = mix(lit, toonRimColor.rgb, rim * toonRimColor.a)
  let emissive: Vec3 = texture(toonEmissiveTexture, uv).rgb * toonEmissiveFactor
  var surfaceColor: Vec3 = lit * albedo.rgb + emissive
  if toonFogOn:
    # terrain-lighting: distance fog. `dist` is the SAME camera-to-
    # fragment distance the rim term above already derives `eye` from,
    # just unnormalized. `fogT` ramps 0 (no fog, at/inside toonFogNear)
    # to 1 (fully toonFogColor, at/beyond toonFogFar); the manual
    # smoothstep (`t*t*(3-2t)`) avoids depending on a GLSL builtin this
    # file's shady procs have not reached for elsewhere. Blended BEFORE
    # `toonTint` (the golden-hour grade), so fog and grade compose the
    # same way distance and time-of-day would in the source photographs
    # the research based this on -- the fog gets graded too, not left an
    # untouched patch, the same way a real hazy horizon would be.
    let
      dist = length(worldPos - toonCameraPosition)
      fogT = clamp(
        (dist - toonFogNear) / max(toonFogFar - toonFogNear, 0.001'f), 0.0'f, 1.0'f)
      fogSmooth = fogT * fogT * (3.0'f - 2.0'f * fogT)
    surfaceColor = mix(surfaceColor, toonFogColor.rgb, fogSmooth)
  fragColor = vec4(surfaceColor, albedo.a) * toonTint

## Sun depth pass: the same skinned vertex path projected by the sun's
## light matrix instead of the camera, with the base color's alpha cutout
## kept, so characters cast correct shadows into the shared sun map
## (polyworld/shadows). Attribute names match the gltf convention, so the
## primitives' existing vertex arrays bind unchanged.

var toonDepthLightMvp: Uniform[Mat4]

proc toonDepthVert(
  vertexPosition: Vec3,
  vertexUV: Vec2,
  vertexJoints: UVec4,
  vertexWeights: Vec4,
  gl_Position: var Vec4,
  uv: var Vec2
) =
  var skin = mat4(1.0'f)
  if toonUseSkinning:
    skin =
      vertexWeights.x * toonJointMatrices[vertexJoints.x.int] +
      vertexWeights.y * toonJointMatrices[vertexJoints.y.int] +
      vertexWeights.z * toonJointMatrices[vertexJoints.z.int] +
      vertexWeights.w * toonJointMatrices[vertexJoints.w.int]
  gl_Position =
    toonDepthLightMvp * toonModel * (skin * vec4(vertexPosition, 1.0'f))
  uv = vertexUV

proc toonDepthFrag(uv: Vec2, fragColor: var Vec4) =
  let albedo: Vec4 = texture(toonBaseColorTexture, uv) * toonBaseColorFactor
  if albedo.a < toonAlphaCutoff:
    discardFragment()
  fragColor = vec4(1.0'f, 1.0'f, 1.0'f, 1.0'f)

## Background: a full-screen sky-to-ground gradient in the palette's
## colours, so the character is not floating in a void of another palette.

var
  toonSkyColor: Uniform[Vec4]       # top of the screen
  toonHorizonColor: Uniform[Vec4]   # at horizonHeight
  toonGroundColor: Uniform[Vec4]    # bottom of the screen
  toonHorizonHeight: Uniform[float32]  # 0 bottom .. 1 top

proc toonBackgroundVert(
  vertexPosition: Vec3,
  gl_Position: var Vec4,
  screenY: var float32
) =
  screenY = vertexPosition.y * 0.5'f + 0.5'f
  gl_Position = vec4(vertexPosition.x, vertexPosition.y, 1.0'f, 1.0'f)

proc toonBackgroundFrag(screenY: float32, fragColor: var Vec4) =
  let horizon = clamp(toonHorizonHeight, 0.01'f, 0.99'f)
  if screenY > horizon:
    let t = (screenY - horizon) / (1.0'f - horizon)
    fragColor = mix(toonHorizonColor, toonSkyColor, t)
  else:
    let t = screenY / horizon
    fragColor = mix(toonGroundColor, toonHorizonColor, t)

const
  ToonShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop
  ToonVertSrc* = toShader(toonVert, ToonShaderTarget, shaderVertex)
  ToonFragSrc* = toShader(toonFrag, ToonShaderTarget, shaderFragment)
  ToonDepthVertSrc* = toShader(toonDepthVert, ToonShaderTarget, shaderVertex)
  ToonDepthFragSrc* = toShader(toonDepthFrag, ToonShaderTarget, shaderFragment)
  ToonBackgroundVertSrc* =
    toShader(toonBackgroundVert, ToonShaderTarget, shaderVertex)
  ToonBackgroundFragSrc* =
    toShader(toonBackgroundFrag, ToonShaderTarget, shaderFragment)

## Light

# The toon light travels this way: from the upper front-left at a low angle
# (about 25 degrees), so it rakes across characters and terrain. A light
# from nearly overhead puts every surface a top-down camera can see in the
# lit band, which reads as flat.
const ToonLightDirection* = normalize(vec3(0.7, -0.4, -0.6))

## Palettes

type ToonPalette* = object
  name*: string
  highlight*: Color
  shadow*: Color

proc palette(name, highlight, shadow: string): ToonPalette =
  ToonPalette(
    name: name,
    highlight: parseHtmlColor("#" & highlight),
    shadow: parseHtmlColor("#" & shadow)
  )

# Highlight/shadow pairs per time of day and weather.
const ToonPalettes* = [
  palette("Day", "FFFFFF", "A39892"),
  palette("Morning", "F0EAE3", "BCB7CB"),
  palette("Afternoon", "D8C37F", "B09070"),
  palette("Evening", "8D8C9A", "7E7885"),
  palette("Dusk", "A19AA3", "746676"),
  palette("Night", "879EB5", "5D6E99"),
  palette("Day rainy", "ADBBB7", "8E978D"),
  palette("Morning rainy", "B8BDB8", "9AA494"),
  palette("Afternoon rainy", "999187", "888177"),
  palette("Evening rainy", "8E877D", "7A7368"),
  palette("Dusk rainy", "90887A", "746676"),
  palette("Night rainy", "4B6690", "4C595A"),
]

proc mix*(a, b: ToonPalette, t: float32): ToonPalette =
  ToonPalette(
    name: (if t < 0.5: a.name else: b.name),
    highlight: mix(a.highlight, b.highlight, t),
    shadow: mix(a.shadow, b.shadow, t)
  )

# The sunny palettes laid along a 24 hour day: hour -> index into
# ToonPalettes. Dusk doubles as dawn.
const DayCycle = [
  (0.0'f32, 5), (4.0'f32, 5), (6.0'f32, 4), (8.0'f32, 1), (11.0'f32, 0),
  (15.0'f32, 0), (17.0'f32, 2), (19.0'f32, 3), (20.5'f32, 4), (22.0'f32, 5),
  (24.0'f32, 5),
]

proc paletteAtHour*(hour: float32): ToonPalette =
  ## The palette for a time of day, blending between the sunny palettes:
  ## night until 4, dawn at 6, morning at 8, full day 11 to 15, afternoon at
  ## 17, evening at 19, dusk at 20:30, night from 22. Hours wrap.
  let h = ((hour mod 24) + 24) mod 24
  for i in 0 ..< DayCycle.len - 1:
    let (h0, p0) = DayCycle[i]
    let (h1, p1) = DayCycle[i + 1]
    if h <= h1:
      let t = if h1 > h0: (h - h0) / (h1 - h0) else: 0'f32
      return mix(ToonPalettes[p0], ToonPalettes[p1], t)
  ToonPalettes[DayCycle[^1][1]]

## Ramp

const RampWidth = 256

proc rampImage*(shadowEnd = 0.47'f32, highlightStart = 0.53'f32): Image =
  ## The shading ramp: black, a short linear rise, white. Both edges are
  ## fractions of the full intensity range.
  result = newImage(RampWidth, 1)
  for x in 0 ..< RampWidth:
    let
      t = x.float32 / (RampWidth - 1).float32
      v = clamp((t - shadowEnd) / max(highlightStart - shadowEnd, 0.001'f32), 0, 1)
      byte = (v * 255).round.uint8
    result.data[x] = rgbx(byte, byte, byte, 255)

## Context

type
  ToonUniforms = object
    model, normalMatrix, view, proj: GLint
    useSkinning, jointMatrices: GLint
    lightDirection, cameraPosition: GLint
    baseColorTexture, baseColorFactor: GLint
    emissiveTexture, emissiveFactor: GLint
    alphaCutoff, ramp: GLint
    highlightColor, shadowColor, rimColor, unlit, tint: GLint
    unlitReceivesShadow, unlitShadowDark: GLint
    smoothShaded: GLint
    smoothShadowDark: GLint
    fogColor: GLint
    fogNear, fogFar: GLint
    fogOn: GLint
    shadowMvp0, shadowMvp1, shadowMap0, shadowMap1, shadowStep: GLint
    shadowsOn, shadowStrength: GLint
    shadowBias, shadowTexel, shadowSoftness, shadingStrength: GLint

  ToonDepthUniforms = object
    model, lightMvp, useSkinning, jointMatrices: GLint
    baseColorTexture, baseColorFactor, alphaCutoff: GLint

  BackgroundUniforms = object
    sky, horizon, ground, horizonHeight: GLint

  ToonContext* = ref object
    shader: GLuint
    uniforms: ToonUniforms
    depthShader: GLuint
    depthUniforms: ToonDepthUniforms
    backgroundShader: GLuint
    backgroundUniforms: BackgroundUniforms
    backgroundVao, backgroundVbo: GLuint
    rampTexture: GLuint
    jointMatrices: seq[Mat4]
    transform*: Mat4             ## model transform applied above the root
    view*, proj*: Mat4
    cameraPosition*: Vec3
    tint*: Color                 ## multiplies the final colour
    lightDirection*: Vec3        ## direction the light travels
    highlightColor*: Color
    shadowColor*: Color
    rimColor*: Color             ## alpha is the rim strength
    unlitNodes*: HashSet[string] ## mesh nodes drawn always full-bright
    unlitReceivesShadow*: HashSet[string]
      ## convoy/unlit-shadow-receive: subset of unlitNodes that still darken
      ## under the sun's own shadow map (shadow-only multiply, no ramp).
      ## Empty by default; membership here does nothing unless the node is
      ## also in unlitNodes.
    unlitShadowDark*: float32
      ## Multiply floor for unlitReceivesShadow nodes in full shadow. 1.0
      ## (the default) reproduces today's unlit behaviour exactly.
    smoothShadedNodes*: HashSet[string]
      ## convoy/terrain-lighting: nodes shaded with a continuous ambient
      ## N.L diffuse instead of the toon ramp, plus the explicit
      ## `smoothShadowDark` cast-shadow multiply (see `toonSmoothShaded`'s
      ## own header). Empty by default -- membership here is the only way
      ## this mode ever engages, so an empty set reproduces pre-existing
      ## pixels exactly.
    smoothShadowDark*: float32
      ## Multiply floor a smoothShadedNodes fragment's own colour reaches
      ## in full cast shadow. 1.0 (the default) reproduces the ambient-
      ## only look (no visible cast shadow) even with a node opted in.
    skyColor*, horizonColor*, groundColor*: Color  ## background gradient
    horizonHeight*: float32      ## where the horizon sits, 0 bottom .. 1 top
    fogColor*: Color
      ## terrain-lighting: distance fog target colour -- a caller should
      ## set this to the SAME value as `horizonColor` above (see
      ## `toonFrag`'s own header) so fogged geometry blends into exactly
      ## what the sky already looks like at the horizon.
    fogNear*, fogFar*: float32
      ## World-unit camera distance where the fog blend starts/reaches
      ## full strength.
    fogOn*: bool
      ## False (the default) is an exact no-op -- `toonFrag` skips the
      ## whole blend, reproducing pre-fog pixels exactly.

proc uploadRamp(ctx: ToonContext, image: Image) =
  if ctx.rampTexture == 0:
    glGenTextures(1, ctx.rampTexture.addr)
  glBindTexture(GL_TEXTURE_2D, ctx.rampTexture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint, image.width.GLint, image.height.GLint,
    0, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)

proc setRamp*(ctx: ToonContext, image: Image) =
  ## Replaces the ramp with any width x 1 image (red channel is read).
  ctx.uploadRamp(image)

proc setPalette*(ctx: ToonContext, palette: ToonPalette) =
  ## Sets the character colours and derives a background from them: the
  ## horizon glows with the highlight, the sky above cools toward the shadow
  ## colour, the ground below is the shadow colour darkened a little.
  ctx.highlightColor = palette.highlight
  ctx.shadowColor = palette.shadow
  ctx.horizonColor = mix(palette.highlight, palette.shadow, 0.25)
  ctx.skyColor = mix(palette.highlight, palette.shadow, 0.8)
  ctx.groundColor = palette.shadow * 0.8
  ctx.groundColor.a = 1
  ctx.horizonHeight = 0.42

proc newToonContext*(): ToonContext =
  result = ToonContext(
    transform: mat4(),
    lightDirection: ToonLightDirection,
    tint: color(1, 1, 1, 1),
    rimColor: color(1, 1, 1, 0),
    unlitShadowDark: 0.6'f32,
    smoothShadowDark: 1.0'f32,
    fogOn: false,
    # Non-zero, non-degenerate placeholders (never divide-by-zero in
    # toonFrag's guard even if a caller sets fogColor without
    # fogNear/fogFar) -- irrelevant either way while fogOn is false,
    # its own default just above.
    fogNear: 1.0'f32,
    fogFar: 2.0'f32,
  )
  result.setPalette(ToonPalettes[0])
  result.shader = compileShaderFiles(ToonVertSrc, ToonFragSrc)
  template loc(field: untyped, name: string) =
    result.uniforms.field = glGetUniformLocation(result.shader, name)
  loc(model, "toonModel")
  loc(normalMatrix, "toonNormalMatrix")
  loc(view, "toonView")
  loc(proj, "toonProj")
  loc(useSkinning, "toonUseSkinning")
  loc(jointMatrices, "toonJointMatrices")
  loc(lightDirection, "toonLightDirection")
  loc(cameraPosition, "toonCameraPosition")
  loc(baseColorTexture, "toonBaseColorTexture")
  loc(baseColorFactor, "toonBaseColorFactor")
  loc(emissiveTexture, "toonEmissiveTexture")
  loc(emissiveFactor, "toonEmissiveFactor")
  loc(alphaCutoff, "toonAlphaCutoff")
  loc(ramp, "toonRamp")
  loc(highlightColor, "toonHighlightColor")
  loc(shadowColor, "toonShadowColor")
  loc(rimColor, "toonRimColor")
  loc(unlit, "toonUnlit")
  loc(unlitReceivesShadow, "toonUnlitReceivesShadow")
  loc(unlitShadowDark, "toonUnlitShadowDark")
  loc(smoothShaded, "toonSmoothShaded")
  loc(smoothShadowDark, "toonSmoothShadowDark")
  loc(tint, "toonTint")
  loc(fogColor, "toonFogColor")
  loc(fogNear, "toonFogNear")
  loc(fogFar, "toonFogFar")
  loc(fogOn, "toonFogOn")
  loc(shadowMvp0, "toonShadowMvp0")
  loc(shadowMvp1, "toonShadowMvp1")
  loc(shadowMap0, "toonShadowMap0")
  loc(shadowMap1, "toonShadowMap1")
  loc(shadowStep, "toonShadowStep")
  loc(shadowsOn, "toonShadowsOn")
  loc(shadowStrength, "toonShadowStrength")
  loc(shadowBias, "toonShadowBias")
  loc(shadowTexel, "toonShadowTexel")
  loc(shadowSoftness, "toonShadowSoftness")
  loc(shadingStrength, "toonShadingStrength")
  result.uploadRamp(rampImage())

  result.depthShader = compileShaderFiles(ToonDepthVertSrc, ToonDepthFragSrc)
  template dloc(field: untyped, name: string) =
    result.depthUniforms.field =
      glGetUniformLocation(result.depthShader, name)
  dloc(model, "toonModel")
  dloc(lightMvp, "toonDepthLightMvp")
  dloc(useSkinning, "toonUseSkinning")
  dloc(jointMatrices, "toonJointMatrices")
  dloc(baseColorTexture, "toonBaseColorTexture")
  dloc(baseColorFactor, "toonBaseColorFactor")
  dloc(alphaCutoff, "toonAlphaCutoff")

  result.backgroundShader =
    compileShaderFiles(ToonBackgroundVertSrc, ToonBackgroundFragSrc)
  template bloc(field: untyped, name: string) =
    result.backgroundUniforms.field =
      glGetUniformLocation(result.backgroundShader, name)
  bloc(sky, "toonSkyColor")
  bloc(horizon, "toonHorizonColor")
  bloc(ground, "toonGroundColor")
  bloc(horizonHeight, "toonHorizonHeight")
  # One triangle covering clip space; the vertex shader reads only xy.
  var corners = [
    vec3(-1, -1, 0), vec3(3, -1, 0), vec3(-1, 3, 0)
  ]
  glGenVertexArrays(1, result.backgroundVao.addr)
  glBindVertexArray(result.backgroundVao)
  glGenBuffers(1, result.backgroundVbo.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.backgroundVbo)
  glBufferData(
    GL_ARRAY_BUFFER, corners.len * sizeof(Vec3), corners[0].addr,
    GL_STATIC_DRAW)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 0, nil)
  glBindVertexArray(0)

proc drawBackground*(ctx: ToonContext) =
  ## Fills the screen with the palette gradient. Draw it first; it writes
  ## no depth, so the scene lands on top.
  glUseProgram(ctx.backgroundShader)
  let u = ctx.backgroundUniforms
  glUniform4f(u.sky, ctx.skyColor.r, ctx.skyColor.g, ctx.skyColor.b, 1)
  glUniform4f(
    u.horizon, ctx.horizonColor.r, ctx.horizonColor.g, ctx.horizonColor.b, 1)
  glUniform4f(
    u.ground, ctx.groundColor.r, ctx.groundColor.g, ctx.groundColor.b, 1)
  glUniform1f(u.horizonHeight, ctx.horizonHeight)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glBindVertexArray(ctx.backgroundVao)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)
  glEnable(GL_CULL_FACE)
  glUseProgram(0)

proc drawPrimitive(
  ctx: ToonContext, root, owner: Node, primitive: Primitive
) =
  let u = ctx.uniforms
  var
    modelMat = owner.mat
    normalMat = owner.mat.normalMatrix
  glUniformMatrix4fv(u.model, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
  glUniformMatrix3fv(
    u.normalMatrix, 1, GL_FALSE, cast[ptr float32](normalMat.addr))

  root.skinMatricesInto(owner, ctx.jointMatrices)
  let useSkinning = ctx.jointMatrices.len > 0
  glUniform1i(u.useSkinning, useSkinning.ord.GLint)
  glUniform1i(u.unlit, (owner.name in ctx.unlitNodes).ord.GLint)
  glUniform1i(
    u.unlitReceivesShadow, (owner.name in ctx.unlitReceivesShadow).ord.GLint)
  glUniform1i(
    u.smoothShaded, (owner.name in ctx.smoothShadedNodes).ord.GLint)
  if useSkinning:
    glUniformMatrix4fv(
      u.jointMatrices, ctx.jointMatrices.len.GLsizei, GL_FALSE,
      cast[ptr float32](ctx.jointMatrices[0].addr))

  primitive.uploadToGpu()
  glBindVertexArray(primitive.data.vertexArrayId)

  let material = primitive.material
  glActiveTexture(GL_TEXTURE0)
  glUniform1i(u.baseColorTexture, 0)
  glBindTexture(GL_TEXTURE_2D, material.data.baseColorId)
  glUniform4f(
    u.baseColorFactor, material.baseColorFactor.r, material.baseColorFactor.g,
    material.baseColorFactor.b, material.baseColorFactor.a)
  glActiveTexture(GL_TEXTURE1)
  glUniform1i(u.emissiveTexture, 1)
  glBindTexture(GL_TEXTURE_2D, material.data.emissiveId)
  glUniform3f(
    u.emissiveFactor, material.emissiveFactor.r, material.emissiveFactor.g,
    material.emissiveFactor.b)
  glActiveTexture(GL_TEXTURE2)
  glUniform1i(u.ramp, 2)
  glBindTexture(GL_TEXTURE_2D, ctx.rampTexture)

  case material.alphaMode
  of MaskAlphaMode:
    glUniform1f(u.alphaCutoff, material.alphaCutoff)
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
  of BlendAlphaMode:
    glUniform1f(u.alphaCutoff, -1)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDepthMask(GL_FALSE)
  of OpaqueAlphaMode:
    glUniform1f(u.alphaCutoff, -1)
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
  if material.doubleSided:
    glDisable(GL_CULL_FACE)
  else:
    glEnable(GL_CULL_FACE)

  if primitive.indices16.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices16.len.GLint, GL_UNSIGNED_SHORT, nil)
  elif primitive.indices32.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices32.len.GLint, GL_UNSIGNED_INT, nil)
  else:
    glDrawArrays(GL_TRIANGLES, 0, primitive.points.len.cint)

proc draw*(ctx: ToonContext, root: Node) =
  ## Draws every visible mesh under root with toon shading. Blended
  ## materials go last so they see the opaque depth.
  root.updateTransforms(ctx.transform)
  glUseProgram(ctx.shader)
  let u = ctx.uniforms
  var
    viewMat = ctx.view
    projMat = ctx.proj
  glUniformMatrix4fv(u.view, 1, GL_FALSE, cast[ptr float32](viewMat.addr))
  glUniformMatrix4fv(u.proj, 1, GL_FALSE, cast[ptr float32](projMat.addr))
  glUniform3f(
    u.lightDirection, ctx.lightDirection.x, ctx.lightDirection.y,
    ctx.lightDirection.z)
  glUniform3f(
    u.cameraPosition, ctx.cameraPosition.x, ctx.cameraPosition.y,
    ctx.cameraPosition.z)
  glUniform4f(
    u.highlightColor, ctx.highlightColor.r, ctx.highlightColor.g,
    ctx.highlightColor.b, ctx.highlightColor.a)
  glUniform4f(
    u.shadowColor, ctx.shadowColor.r, ctx.shadowColor.g,
    ctx.shadowColor.b, ctx.shadowColor.a)
  glUniform4f(
    u.rimColor, ctx.rimColor.r, ctx.rimColor.g, ctx.rimColor.b,
    ctx.rimColor.a)
  glUniform4f(u.tint, ctx.tint.r, ctx.tint.g, ctx.tint.b, ctx.tint.a)
  glUniform1f(u.unlitShadowDark, ctx.unlitShadowDark)
  glUniform1f(u.smoothShadowDark, ctx.smoothShadowDark)
  glUniform4f(
    u.fogColor, ctx.fogColor.r, ctx.fogColor.g, ctx.fogColor.b, ctx.fogColor.a)
  glUniform1f(u.fogNear, ctx.fogNear)
  glUniform1f(u.fogFar, ctx.fogFar)
  glUniform1i(u.fogOn, ctx.fogOn.ord.GLint)

  # Sun shadow map state (polyworld/shadows): characters darken where the
  # sun cannot see them and flatten with the shared shading strength.
  var
    lightMatrix0 = sunLightMvp0
    lightMatrix1 = sunLightMvp1
  glUniformMatrix4fv(
    u.shadowMvp0, 1, GL_FALSE, cast[ptr float32](lightMatrix0.addr))
  glUniformMatrix4fv(
    u.shadowMvp1, 1, GL_FALSE, cast[ptr float32](lightMatrix1.addr))
  glUniform1f(u.shadowStep, sunShadowBlend)
  glUniform1f(u.shadowsOn, if sunShadowsActive(): 1.0 else: 0.0)
  glUniform1f(u.shadowStrength, sunShadowStrength)
  glUniform1f(u.shadowBias, sunShadowBias)
  glUniform1f(u.shadowTexel, SunShadowTexel)
  glUniform1f(u.shadowSoftness, sunShadowSoftness)
  glUniform1f(u.shadingStrength, sunShadingStrength)
  glActiveTexture(GL_TEXTURE3)
  glBindTexture(GL_TEXTURE_2D, sunShadowTextures[0])
  glUniform1i(u.shadowMap0, 3)
  glActiveTexture(GL_TEXTURE4)
  glBindTexture(GL_TEXTURE_2D, sunShadowTextures[1])
  glUniform1i(u.shadowMap1, 4)
  glActiveTexture(GL_TEXTURE0)

  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LEQUAL)
  glFrontFace(GL_CCW)

  var blended: seq[(Node, Primitive)]
  proc visit(node: Node) =
    if not node.visible:
      return
    if node.mesh != nil:
      for primitive in node.mesh.primitives:
        if primitive.material.alphaMode == BlendAlphaMode:
          blended.add (node, primitive)
        else:
          ctx.drawPrimitive(root, node, primitive)
    for child in node.nodes:
      visit(child)
  visit(root)
  for (node, primitive) in blended:
    ctx.drawPrimitive(root, node, primitive)

  glDisable(GL_BLEND)
  glDepthMask(GL_TRUE)
  glEnable(GL_CULL_FACE)
  glBindVertexArray(0)
  glUseProgram(0)

proc drawSunDepthPrimitive(
  ctx: ToonContext, root, owner: Node, primitive: Primitive
) =
  let u = ctx.depthUniforms
  var modelMat = owner.mat
  glUniformMatrix4fv(u.model, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
  root.skinMatricesInto(owner, ctx.jointMatrices)
  let useSkinning = ctx.jointMatrices.len > 0
  glUniform1i(u.useSkinning, useSkinning.ord.GLint)
  if useSkinning:
    glUniformMatrix4fv(
      u.jointMatrices, ctx.jointMatrices.len.GLsizei, GL_FALSE,
      cast[ptr float32](ctx.jointMatrices[0].addr))

  primitive.uploadToGpu()
  glBindVertexArray(primitive.data.vertexArrayId)

  let material = primitive.material
  glActiveTexture(GL_TEXTURE0)
  glUniform1i(u.baseColorTexture, 0)
  glBindTexture(GL_TEXTURE_2D, material.data.baseColorId)
  glUniform4f(
    u.baseColorFactor, material.baseColorFactor.r, material.baseColorFactor.g,
    material.baseColorFactor.b, material.baseColorFactor.a)
  if material.alphaMode == MaskAlphaMode:
    glUniform1f(u.alphaCutoff, material.alphaCutoff)
  else:
    glUniform1f(u.alphaCutoff, -1)

  if primitive.indices16.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices16.len.GLint, GL_UNSIGNED_SHORT, nil)
  elif primitive.indices32.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
    glDrawElements(
      GL_TRIANGLES, primitive.indices32.len.GLint, GL_UNSIGNED_INT, nil)
  else:
    glDrawArrays(GL_TRIANGLES, 0, primitive.points.len.cint)

proc drawSunDepth*(ctx: ToonContext, root: Node) =
  ## Renders every visible opaque mesh under root into the sun's depth map
  ## (polyworld/shadows), skinning included, so characters cast shadows.
  ## Call between beginSunDepthPass and endSunDepthPass with ctx.transform
  ## already posed; blended materials never cast.
  root.updateTransforms(ctx.transform)
  glUseProgram(ctx.depthShader)
  var lightMatrix = sunDepthPassMvp()
  glUniformMatrix4fv(
    ctx.depthUniforms.lightMvp, 1, GL_FALSE,
    cast[ptr float32](lightMatrix.addr))
  glDisable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)

  proc visit(node: Node) =
    if not node.visible:
      return
    if node.mesh != nil:
      for primitive in node.mesh.primitives:
        if primitive.material.alphaMode != BlendAlphaMode:
          ctx.drawSunDepthPrimitive(root, node, primitive)
    for child in node.nodes:
      visit(child)
  visit(root)
  glBindVertexArray(0)
