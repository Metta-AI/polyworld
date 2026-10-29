## FX mesh builder tests that do not need a GPU context.

import
  vmath,
  polyworld/clickmarks,
  polyworld/fxmeshes

echo "Testing effect fades preserve wrapped seams"
block:
  var settings = defaultFxSettings()
  settings.shape = RingShape
  let ring = fxEdgeFade(settings)
  doAssert ring.x == 0 and ring.y == 0
  doAssert ring.z > 0 and ring.w > 0
  settings.shape = AoeConeShape
  settings.arcDegrees = 90
  settings.innerRadius = 0
  let cone = fxEdgeFade(settings)
  doAssert cone.x > 0 and cone.y > 0 and cone.w > 0
  doAssert cone.z == 0

echo "Testing fx life"
doAssert fxLife(0, 1, false) == 0
doAssert fxLife(1, 1, false) == 1
doAssert fxLife(0.5'f32, 1, false) > 0
doAssert fxLife(0.5'f32, 1, false) < 1
doAssert fxLife(1.25'f32, 1, true) > 0
doAssert fxLife(1.25'f32, 1, true) < 1

echo "Testing click cylinder mesh"
let
  settings = clickMarkSettings()
  mesh = buildFxMesh(settings)
doAssert settings.shape == CylinderShape
doAssert settings.expandStart == ClickMarkStartScale
doAssert settings.expandEnd == ClickMarkEndScale
doAssert mesh.vertices.len > 0
doAssert mesh.indices.len > 0
doAssert mesh.vertices.len mod 12 == 0
doAssert mesh.indices.len mod 3 == 0
