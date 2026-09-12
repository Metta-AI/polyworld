## High-resolution visual paint for Gota's roads and quarries.
##
## Logical tile kinds remain authoritative for gameplay and decor, while this
## sidecar gives dirt and gravel sub-tile, height-shaped borders.

import std/math

import maps
import polyworld/noises
import polyworld/pathing

const
  GroundMaskTexelsPerTile* = 4
  GroundMaskSize* = GridTiles * GroundMaskTexelsPerTile
  GroundMaskChannels* = 2
  QuarryDirtFullRadius = QuarryRadius.float32 - 1.0'f32
  QuarryDirtFadeWidth =
    QuarryShoulderRadius.float32 - QuarryDirtFullRadius + 0.5'f32
  QuarryGravelFullRadius = QuarryFloorRadius.float32 - 0.5'f32
  QuarryGravelFadeWidth = 2.0'f32
  RoadDirtFullRadius = 2.65'f32
  RoadDirtFadeWidth = 1.05'f32
  RoadGravelInnerRadius = 1.35'f32
  RoadGravelInnerFade = 0.65'f32
  RoadGravelOuterRadius = 2.55'f32
  RoadGravelOuterFade = 0.85'f32
  TowerCourtClearRadius = 3.5'f32
  TowerCourtClearFade = 1.0'f32

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

proc segmentDistance(
    x, z, ax, az, bx, bz: float32
): float32 =
  let
    dx = bx - ax
    dz = bz - az
    length2 = dx * dx + dz * dz
    amount = clamp(
      ((x - ax) * dx + (z - az) * dz) / max(length2, 0.0001'f32),
      0.0'f32,
      1.0'f32
    )
    offsetX = x - (ax + dx * amount)
    offsetZ = z - (az + dz * amount)
  sqrt(offsetX * offsetX + offsetZ * offsetZ)

proc laneDistance(x, z: float32): float32 =
  result = float32.high
  for route in LaneRoutes:
    for i in 0 ..< route.len - 1:
      result = min(result, segmentDistance(
        x, z,
        route[i].x.float32 + 0.5'f32,
        route[i].z.float32 + 0.5'f32,
        route[i + 1].x.float32 + 0.5'f32,
        route[i + 1].z.float32 + 0.5'f32
      ))

proc symmetricRoadNoise(tx, ty, spacing: int, stream: uint64): float32 =
  let
    mirrorX = GroundMaskSize - 1 - tx
    mirrorY = GroundMaskSize - 1 - ty
    detail = valueNoise(0x47A'i32, stream, tx, ty, spacing) +
      valueNoise(0x47A'i32, stream, mirrorX, mirrorY, spacing)
  detail.float32 / (MapBlendScale.float32 * 2.0'f32)

proc roadContourDistance(tx, ty: int, distance: float32): float32 =
  ## Break the ruler-straight distance field into small grass fingers and dirt
  ## pockets. Mirrored value-noise pairs keep the contour field rotationally
  ## stable without producing an obviously repeating wave along straightaways.
  let
    broad = 1.00'f32 * symmetricRoadNoise(
      tx, ty, 19, 0xA0761D6478BD642F'u64)
    medium = 0.55'f32 * symmetricRoadNoise(
      tx, ty, 9, 0xE7037ED1A0B428DB'u64)
    fine = 0.24'f32 * symmetricRoadNoise(
      tx, ty, 4, 0x8EBC6AF09C88C6E3'u64)
    edgeAmount = clamp(
      (distance - 0.9'f32) / 1.8'f32, 0.0'f32, 1.0'f32)
    offset = clamp(broad + medium + fine, -0.75'f32, 0.75'f32)
  distance - offset * edgeAmount

proc roadVisibility(x, z: float32): float32 =
  ## Let the authored cobble courts own tower footprints and keep this ground
  ## mask off the raised fort layers.
  for fort in [RedFortTile, BlueFortTile]:
    if max(abs(x - (fort.float32 + 0.5'f32)),
        abs(z - (fort.float32 + 0.5'f32))) <= FortPlateauRadius.float32 + 0.5'f32:
      return 0
  result = 1
  for teamSites in TowerSites:
    for sideSites in teamSites:
      for site in sideSites:
        let
          dx = x - (site.x.float32 + 0.5'f32)
          dz = z - (site.z.float32 + 0.5'f32)
          distance = sqrt(dx * dx + dz * dz)
          court = smoothCoverage(
            distance, TowerCourtClearRadius, TowerCourtClearFade)
        result *= 1.0'f32 - court

proc toByte(value: float32): uint8 =
  uint8(clamp(value * 255.0'f32 + 0.5'f32, 0.0'f32, 255.0'f32))

proc buildArenaGroundMask*(): seq[uint8] =
  ## R is gravel coverage and G is exposed-earth coverage, matching
  ## quadterrain's two-channel height-aware ground mask.
  result = newSeq[uint8](GroundMaskSize * GroundMaskSize * GroundMaskChannels)
  for ty in 0 ..< GroundMaskSize:
    for tx in 0 ..< GroundMaskSize:
      let
        x = (tx.float32 + 0.5'f32) / GroundMaskTexelsPerTile.float32
        z = (ty.float32 + 0.5'f32) / GroundMaskTexelsPerTile.float32
        roadDistance = roadContourDistance(tx, ty, laneDistance(x, z))
        roadVisible = roadVisibility(x, z)
        edgePorosity = symmetricRoadNoise(
          tx, ty, 6, 0x589965CC75374CC3'u64)
        gravelDistance = roadDistance - 0.22'f32 * edgePorosity
      var roadDirt = smoothCoverage(
        roadDistance, RoadDirtFullRadius, RoadDirtFadeWidth) * roadVisible
      if roadDirt < 1.0'f32:
        roadDirt *= clamp(
          0.82'f32 + edgePorosity * 0.55'f32, 0.30'f32, 1.0'f32)
      let roadGravel = smoothCoverage(
          gravelDistance, RoadGravelOuterRadius, RoadGravelOuterFade) *
          (1.0'f32 - smoothCoverage(
            gravelDistance, RoadGravelInnerRadius, RoadGravelInnerFade)) *
          roadVisible * clamp(
            0.82'f32 - edgePorosity * 0.48'f32, 0.35'f32, 1.0'f32)
      var quarryDistance = float32.high
      for site in QuarrySites:
        quarryDistance = min(quarryDistance, contourDistance(
          x, z, site[0].float32 + 0.5'f32, site[1].float32 + 0.5'f32))
      let
        quarryDirt = smoothCoverage(
          quarryDistance, QuarryDirtFullRadius, QuarryDirtFadeWidth)
        quarryGravel = smoothCoverage(
          quarryDistance, QuarryGravelFullRadius, QuarryGravelFadeWidth) *
          quarryDirt
        dirt = max(roadDirt, quarryDirt)
        gravel = max(roadGravel, quarryGravel)
        index = (ty * GroundMaskSize + tx) * GroundMaskChannels
      result[index] = toByte(gravel)
      result[index + 1] = toByte(dirt)
