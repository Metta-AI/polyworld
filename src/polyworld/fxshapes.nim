## Shared FX shape identities and deterministic ground footprints.

import fixed

type
  FxShape* = enum
    QuadShape, DiscShape, RingShape, ArcShape, ConeShape,
    CylinderShape, TubeShape, SphereShape, HemisphereShape, TorusShape,
    BoxShape, RibbonShape, CrossPlanesShape, HelixShape,
    AoeCircleShape, AoeLineShape, AoeConeShape, AoeCapsuleShape
  FootprintShape* = enum
    CircleFootprint, RingFootprint, SectorFootprint,
    LineFootprint, CrossFootprint, CapsuleFootprint
  FxArea* = object
    shape*: FootprintShape
    radius*: int32
    innerRadius*: int32
    width*: int32
    length*: int32
    height*: int32
    angle*: int32

const AoeShapes* = {
  AoeCircleShape, AoeLineShape, AoeConeShape, AoeCapsuleShape
}

proc sectorContains(x, z, angle: int32): bool =
  ## Tests a sector facing positive Z using integer trigonometry.
  if angle >= 360 or (x == 0 and z == 0):
    return true
  let
    halfAngle = fixed(clamp(angle, 1'i32, 360'i32)) * FixedPi / fixed(360)
    threshold = int64(int32(cos(halfAngle)))
    distance = integerSqrt(int64(x) * x + int64(z) * z)
  int64(z) * FixedScale >= distance * threshold

proc contains*(area: FxArea, x, z, y: int32): bool =
  ## Tests a local point against the footprint, independent of the visual FX.
  if abs(int64(y)) > max(area.height, 1) div 2:
    return false
  let
    squared = int64(x) * x + int64(z) * z
    radius = int64(max(area.radius, 0))
    inner = int64(max(area.innerRadius, 0))
    halfWidth = int64(max(area.width, 1)) div 2
    length = int64(max(area.length, 1))
  case area.shape
  of CircleFootprint:
    squared <= radius * radius
  of RingFootprint:
    squared <= radius * radius and squared >= inner * inner
  of SectorFootprint:
    squared <= radius * radius and squared >= inner * inner and
      sectorContains(x, z, area.angle)
  of LineFootprint:
    abs(int64(x)) <= halfWidth and z >= 0 and z <= length
  of CrossFootprint:
    (abs(int64(x)) <= halfWidth and abs(int64(z)) <= length div 2) or
      (abs(int64(z)) <= halfWidth and abs(int64(x)) <= length div 2)
  of CapsuleFootprint:
    let beyond = int64(z) - clamp(
      int64(z), halfWidth, max(length - halfWidth, halfWidth)
    )
    int64(x) * x + beyond * beyond <= halfWidth * halfWidth
