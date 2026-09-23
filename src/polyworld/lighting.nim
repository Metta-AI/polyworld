import
  std/[os, strutils],
  vmath,
  chrome, shadows, toon

const
  PaletteFadeSeconds* = 2.0'f
  PaletteFadeHours = PaletteFadeSeconds * 24 / HudDaySeconds.float32
  DayShadowStrength* = 0.85'f
  NightShadowStrength* = 0.65'f
  PaletteChanges = [
    (hour: 6.0'f, palette: 1, night: 0.0'f),
    (hour: 11.0'f, palette: 0, night: 0.0'f),
    (hour: 16.0'f, palette: 2, night: 0.0'f),
    (hour: 18.0'f, palette: 5, night: 1.0'f)
  ]

proc arenaLighting*(hour: float32): tuple[palette: ToonPalette, night: float32] =
  ## Holds authored palettes between two-second fades, including after seeks.
  let h = ((hour mod 24) + 24) mod 24
  var current = PaletteChanges.high
  for i, change in PaletteChanges:
    if h >= change.hour:
      current = i
  let
    target = PaletteChanges[current]
    previous = PaletteChanges[
      (current + PaletteChanges.len - 1) mod PaletteChanges.len
    ]
    elapsed = (h - target.hour + 24) mod 24
    blend = clamp(elapsed / PaletteFadeHours, 0'f, 1'f)
  result.palette = mix(
    ToonPalettes[previous.palette], ToonPalettes[target.palette], blend
  )
  result.night = previous.night + (target.night - previous.night) * blend

proc setArenaLight*(toon: ToonContext, night: float32) =
  ## Keeps diagonal shadows and directional shading throughout the cycle.
  sunAzimuth = 40
  sunElevation = 50
  updateSunMatrix()
  sunShadowStrength = DayShadowStrength +
    (NightShadowStrength - DayShadowStrength) * clamp(night, 0'f, 1'f)
  sunShadingStrength = 1
  toon.lightDirection = -sunDirection

proc setArenaHour*(toon: ToonContext, hour: float32) =
  ## Applies the clock palette with a fixed light and readable night shadows.
  var h = hour
  if existsEnv("TOON_HOUR"):
    h = getEnv("TOON_HOUR").parseFloat.float32
  let lighting = arenaLighting(h)
  toon.setPalette(lighting.palette)
  toon.setArenaLight(lighting.night)
