## Fits an object's pose to a sampled surface.
import std/math

type
  SurfaceSample* = proc(x, z: float32): float32 {.closure.}
  FloatBounds* = object
    minX*, minZ*, maxX*, maxZ*: float32
  FloatingPose* = object
    heave*, roll*, pitch*: float32
    centerX*, centerZ*: float32

proc floatingPose*(bounds: FloatBounds, sample: SurfaceSample,
    padding = 1'f32, maxRoll = 0.18'f32, maxPitch = 0.16'f32): FloatingPose =
  let
    minX = bounds.minX - padding
    maxX = bounds.maxX + padding
    minZ = bounds.minZ - padding
    maxZ = bounds.maxZ + padding
    stepX = (maxX - minX) / 4
    stepZ = (maxZ - minZ) / 4
  result.centerX = (minX + maxX) / 2
  result.centerZ = (minZ + maxZ) / 2
  var samples: array[25, float32]
  var total: float32
  for row in 0..4:
    for column in 0..4:
      let value = sample(minX + column.float32 * stepX,
        minZ + row.float32 * stepZ)
      samples[row * 5 + column] = value
      total += value
  var left, right, front, back: float32
  for i in 0..4:
    left += samples[i * 5]
    right += samples[i * 5 + 4]
    front += samples[i]
    back += samples[20 + i]
  result.roll = clamp(arctan((right - left) / (5 * (maxX - minX))), -maxRoll, maxRoll)
  result.pitch = clamp(-arctan((back - front) / (5 * (maxZ - minZ))), -maxPitch, maxPitch)
  result.heave = total / 25
  for row in 0..4:
    for column in 0..4:
      let x = minX + column.float32 * stepX
      let z = minZ + row.float32 * stepZ
      result.heave = max(result.heave,
        samples[row * 5 + column] - (x - result.centerX) * tan(result.roll) -
        (z - result.centerZ) * tan(-result.pitch))
