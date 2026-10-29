import
  gltf, vmath,
  polyworld/weapontrails

echo "Weapon tip markers follow their posed bones."
let
  joint = Node(mat: translate(vec3(4, 2, 1)) * rotateZ(1.0'f))
  marker = WeaponTip(joint: joint, point: vec3(0, 1, 0))
  point = marker.sample(1)
doAssert point.tip == joint.mat * vec3(0, 1, 0)
doAssert point.inner == joint.mat * vec3(0, 0.72'f, 0)

echo "Trails are bounded and do not connect pauses, seeks, or teleports."
var trail: WeaponTrail
for i in 0 ..< 100:
  trail.update(marker.sample(i.float32 / 1000), true)
doAssert trail.count == trail.samples.len
trail.update(marker.sample(0.099'f), true)
doAssert trail.count == trail.samples.len
trail.update(marker.sample(0.11'f), false)
trail.update(marker.sample(0.12'f), true)
doAssert trail.count == 1
trail.update(marker.sample(0.05'f), true)
doAssert trail.count == 1
joint.mat = translate(vec3(20, 0, 0))
trail.update(marker.sample(0.06'f), true)
doAssert trail.count == 1
trail.update(marker.sample(1), false)
doAssert trail.count == 0
echo "Weapon trail checks passed."
