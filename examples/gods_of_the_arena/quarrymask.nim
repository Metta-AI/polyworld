## High-resolution visual paint for Gota's quarries.
##
## Quarry tile kinds remain authoritative for gameplay and decor, while this
## sidecar mask gives their dirt and gravel sub-tile, height-shaped borders.

import std/math

import maps
import polyworld/pathing

const
  QuarryMaskTexelsPerTile* = 4
  QuarryMaskSize* = GridTiles * QuarryMaskTexelsPerTile
  QuarryMaskChannels* = 2
  DirtFullRadius = QuarryRadius.float32 - 1.0'f32
  DirtFadeWidth = QuarryShoulderRadius.float32 - DirtFullRadius + 0.5'f32
  GravelFullRadius = QuarryFloorRadius.float32 - 0.5'f32
  GravelFadeWidth = 2.0'f32

proc smoothCoverage(distance, fullRadius, fadeWidth: float32): float32 =
  let t = clamp((distance - fullRadius) / fadeWidth, 0.0'f32, 1.0'f32)
  1.0'f32 - t * t * (3.0'f32 - 2.0'f32 * t)

proc contourDistance(x, z, centerX, centerZ: float32): float32 =
  ## Even angular harmonics keep the two point-symmetric quarry cuts alike.
  let
    dx = x - centerX
    dz = z - centerZ
    angle = arctan2(dz, dx)
    wobble = 0.42'f32 * cos(angle * 2.0'f32 + 0.65'f32) +
      0.22'f32 * cos(angle * 4.0'f32 - 0.35'f32)
  sqrt(dx * dx + dz * dz) - wobble

proc toByte(value: float32): uint8 =
  uint8(clamp(value * 255.0'f32 + 0.5'f32, 0.0'f32, 255.0'f32))

proc buildQuarryGroundMask*(): seq[uint8] =
  ## R is gravel-floor coverage and G is exposed-earth coverage, matching
  ## quadterrain's two-channel height-aware ground mask.
  result = newSeq[uint8](
    QuarryMaskSize * QuarryMaskSize * QuarryMaskChannels)
  for ty in 0 ..< QuarryMaskSize:
    for tx in 0 ..< QuarryMaskSize:
      let
        x = (tx.float32 + 0.5'f32) / QuarryMaskTexelsPerTile.float32
        z = (ty.float32 + 0.5'f32) / QuarryMaskTexelsPerTile.float32
      var distance = float32.high
      for site in QuarrySites:
        distance = min(distance, contourDistance(
          x, z, site[0].float32 + 0.5'f32, site[1].float32 + 0.5'f32))
      let
        dirt = smoothCoverage(distance, DirtFullRadius, DirtFadeWidth)
        gravel = smoothCoverage(
          distance, GravelFullRadius, GravelFadeWidth) * dirt
        index = (ty * QuarryMaskSize + tx) * QuarryMaskChannels
      result[index] = toByte(gravel)
      result[index + 1] = toByte(dirt)
