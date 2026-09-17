import std/[math, unittest]
import polyworld/floatingpose

suite "floating pose":
  let bounds = FloatBounds(minX: 3, minZ: 3, maxX: 17, maxZ: 35)
  test "follows a flat surface":
    let pose = bounds.floatingPose(proc(x, z: float32): float32 = 0.65)
    check abs(pose.heave - 0.65) < 0.0001
    check abs(pose.roll) < 0.0001
    check abs(pose.pitch) < 0.0001
  test "limits tilt and clears sampled crests":
    let pose = bounds.floatingPose(proc(x, z: float32): float32 =
      sin(x * 0.19 + z * 0.07) * 0.8)
    check pose.roll in -0.18'f32..0.18'f32
    check pose.pitch in -0.16'f32..0.16'f32
    check pose.heave >= 0.6
