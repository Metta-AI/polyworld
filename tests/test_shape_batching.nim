## Invoked by tools/verify_shape_batching.py with the preceding source oracle.
import std/[importutils, times, strformat, algorithm]
import chroma, vmath
import polyworld/shapes as current
import shape_reference as previous
privateAccess(current.ShapeRenderer)
privateAccess(previous.ShapeRenderer)

template emit(renderer: untyped; i: int) =
  mixin addTriangle, addQuad, addSquare, addPolygon, addCircle, addHexagon, addPolyline, addLine
  let
    a = vec3(i.float32 * 0.25, -0.0'f32, (i mod 19).float32)
    b = a + vec3(0.7, 0.2, -0.3)
    c = a + vec3(-0.3, 1.4, 0.9)
    d = a + vec3(-1.0, -0.3, 1.1)
    color = rgbx((i mod 256).uint8, ((i*7) mod 256).uint8,
      ((i*23) mod 256).uint8, [0'u8, 1, 128, 254, 255][i mod 5])
  case i mod 9
  of 0: addTriangle(renderer, a,b,c,color,vec2(-0.3,0.8),vec2(2,-1),vec2(0,1))
  of 1: addQuad(renderer,a,b,c,d,color,vec2(0.4,0.2),vec2(3,2),vec2(-1,1),vec2(0.5,0.5))
  of 2: addSquare(renderer,a,1.7,color,i.float32*0.19)
  of 3: addPolygon(renderer,a,0.9,3+i mod 11,color,i.float32*0.07)
  of 4: addCircle(renderer,a,0.8,color)
  of 5: addHexagon(renderer,a,0.5,color,i.float32*0.11)
  of 6: addPolyline(renderer,[a,a,b,c,d,a],color,0.15)
  of 7: addLine(renderer,a,b,color,0.07)
  else:
    addPolyline(renderer,[a,a],color)
    addPolygon(renderer,a,-1,2,color)
    addPolyline(renderer,[a,b],color,-1)

var oldMesh: previous.ShapeRenderer
var newMesh: current.ShapeRenderer
for i in 0..<2048:
  oldMesh.emit(i)
  newMesh.emit(i)
  doAssert oldMesh.vertices.len == newMesh.vertices.len
  for v in 0..<oldMesh.vertices.len:
    when defined(js):
      doAssert oldMesh.vertices[v] == newMesh.vertices[v]
    else:
      doAssert cast[uint32](oldMesh.vertices[v]) == cast[uint32](newMesh.vertices[v])
  if i mod 127 == 0:
    previous.clear(oldMesh)
    current.clear(newMesh)
echo "PASS: 2048 mixed primitive cases, alpha/UV/winding/clear/reuse and invalid inputs"

when defined(js):
  proc sampleTime(): float64 {.importjs: "(performance.now() / 1000)".}
else:
  proc sampleTime(): float64 = cpuTime()

proc oldRun(): float64 =
  let started = sampleTime()
  for frame in 0..<12:
    previous.clear(oldMesh)
    for i in 0..<4096: oldMesh.emit(i)
  sampleTime()-started
proc newRun(): float64 =
  let started = sampleTime()
  for frame in 0..<12:
    current.clear(newMesh)
    for i in 0..<4096: newMesh.emit(i)
  sampleTime()-started

discard oldRun()
discard newRun()
var oldTimes,newTimes: seq[float64]
for iteration in 0..<10:
  if iteration mod 2 == 0:
    oldTimes.add(oldRun()); newTimes.add(newRun())
  else:
    newTimes.add(newRun()); oldTimes.add(oldRun())
  doAssert oldMesh.vertices.len == newMesh.vertices.len
  for v in 0..<oldMesh.vertices.len:
    when defined(js):
      doAssert oldMesh.vertices[v] == newMesh.vertices[v]
    else:
      doAssert cast[uint32](oldMesh.vertices[v]) == cast[uint32](newMesh.vertices[v])
oldTimes.sort(); newTimes.sort()
echo &"Median 12x4096 mixed primitives: old={oldTimes[5]*1000:.3f}ms new={newTimes[5]*1000:.3f}ms ratio={oldTimes[5]/newTimes[5]:.3f}; floats={newMesh.vertices.len}"
