import
  chroma, vmath,
  polyworld/[chrome, rtscameras, shadows, toon],
  ../examples/gods_of_the_arena/lighting

proc close(a, b: Color): bool =
  ## Compares palette colors with tolerance for fractional clock rounding.
  abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) < 0.0001

echo "Testing GotA palette changes take two seconds at normal speed"
for change in [(6'f, 5, 1), (11'f, 1, 0), (16'f, 0, 2), (18'f, 2, 5)]:
  let
    (hour, previous, target) = change
    before = arenaLighting(hour - 0.01).palette
    start = arenaLighting(hour).palette
    half = arenaLighting(hour + 24 / HudDaySeconds.float32).palette
    finish = arenaLighting(
      hour + PaletteFadeSeconds * 24 / HudDaySeconds.float32
    ).palette
    expectedHalf = mix(ToonPalettes[previous], ToonPalettes[target], 0.5)
  doAssert close(before.highlight, ToonPalettes[previous].highlight)
  doAssert close(start.shadow, ToonPalettes[previous].shadow)
  doAssert close(half.highlight, expectedHalf.highlight)
  doAssert close(half.shadow, expectedHalf.shadow)
  doAssert close(finish.highlight, ToonPalettes[target].highlight)
  doAssert close(finish.shadow, ToonPalettes[target].shadow)

echo "Testing midnight, replay seeks, and stable palette periods"
for hour in [0'f, 8, 12, 17, 21, 23.99]:
  doAssert arenaLighting(hour) == arenaLighting(hour + 24)
  doAssert arenaLighting(hour) == arenaLighting(hour - 24)
  let later = arenaLighting(hour + 0.001)
  doAssert close(arenaLighting(hour).palette.highlight, later.palette.highlight)

echo "Testing fixed diagonal shadows never fade out through a full day"
block:
  let toon = ToonContext()
  toon.setArenaLight(0)
  let
    direction = sunDirection
    matrix = sunLightMvp0
    view = lookAt(rtsCameraEye(vec3(0), 20), vec3(0), vec3(0, 1, 0))
    projected = view * vec4(-direction.x, 0, -direction.z, 0)
  doAssert projected.x < 0 and projected.y > 0
  doAssert abs(abs(projected.x / projected.y) - 1) < 0.1
  for minute in 0 ..< 24 * 60:
    let state = arenaLighting(minute.float32 / 60)
    toon.setArenaLight(state.night)
    doAssert sunDirection == direction and toon.lightDirection == -direction
    doAssert sunLightMvp0 == matrix and sunLightMvp1 == matrix
    doAssert sunShadowBlend == 0
    doAssert lightLevel == 1 and sunShadingStrength == 1
    doAssert sunShadowStrength >= NightShadowStrength
    doAssert sunShadowStrength <= DayShadowStrength
  doAssert NightShadowStrength < DayShadowStrength
  doAssert arenaLighting(0).night == 1
  doAssert arenaLighting(12).night == 0
  doAssert abs(arenaLighting(18 + 24 / HudDaySeconds.float32).night - 0.5) < 0.001
