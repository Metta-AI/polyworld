import
  chroma, gltf, vmath,
  shapes

const
  TrailLifetime* = 0.16'f
  TrailSamples = 32

type
  WeaponTrailError* = object of CatchableError
  WeaponTip* = object
    joint*: Node
    point*: Vec3
  TrailSample* = object
    tip*, inner*: Vec3
    time*: float32
  WeaponTrail* = object
    samples*: array[TrailSamples, TrailSample]
    count*: int
    emitting: bool

proc weaponTip*(
    root: Node,
    names: openArray[string],
    bone: string
): WeaponTip =
  ## Finds the blade's farthest vertex in its attachment bone's local space.
  var farthest = 0.0'f
  for node in root.walkNodes:
    if node.name notin names or node.mesh == nil or node.skin == nil:
      continue
    for primitive in node.mesh.primitives:
      for i, point in primitive.points:
        for slot in 0 ..< 4:
          let weight = primitive.jointWeights[i][slot]
          if weight <= 0:
            continue
          let index = primitive.jointIds[i][slot].int
          if weight < 0.999'f or node.skin.joints[index].name != bone:
            raise newException(
              WeaponTrailError,
              "Weapon is not rigid: " & node.name
            )
          let
            local = node.skin.inverseBindMatrices[index] * point
            distance = dot(local, local)
          if distance > farthest:
            farthest = distance
            result = WeaponTip(joint: node.skin.joints[index], point: local)
  if result.joint == nil:
    raise newException(WeaponTrailError, "Weapon tip not found for " & bone)

proc sample*(marker: WeaponTip, time: float32): TrailSample =
  ## Samples the exact posed bone after preparing this character instance.
  TrailSample(
    tip: marker.joint.mat * marker.point,
    inner: marker.joint.mat * (marker.point * 0.72'f),
    time: time
  )

proc update*(trail: var WeaponTrail, point: TrailSample, emitting: bool) =
  ## Retains a bounded short ribbon and breaks it on new swings or teleports.
  if trail.count > 0 and
    (point.time < trail.samples[trail.count - 1].time or
      (point.tip - trail.samples[trail.count - 1].tip).length > 2):
      trail.count = 0
  var count = 0
  for i in 0 ..< trail.count:
    if point.time - trail.samples[i].time < TrailLifetime:
      trail.samples[count] = trail.samples[i]
      inc count
  trail.count = count
  if emitting and not trail.emitting:
    trail.count = 0
  trail.emitting = emitting
  if not emitting or (trail.count > 0 and
    point.time <= trail.samples[trail.count - 1].time):
      return
  if trail.count == TrailSamples:
    for i in 1 ..< TrailSamples:
      trail.samples[i - 1] = trail.samples[i]
    dec trail.count
  trail.samples[trail.count] = point
  inc trail.count

proc draw*(renderer: var ShapeRenderer, trail: WeaponTrail, time: float32) =
  ## Fades both ribbon edges and its tail with per-vertex transparency.
  for i in 1 ..< trail.count:
    let
      first = trail.samples[i - 1]
      last = trail.samples[i]
      a = mix(first.inner, first.tip, 0.5'f)
      b = mix(last.inner, last.tip, 0.5'f)
      fadeA = clamp(1 - (time - first.time) / TrailLifetime, 0.0'f, 1.0'f)
      fadeB = clamp(1 - (time - last.time) / TrailLifetime, 0.0'f, 1.0'f)
      colorA = rgbx(255, 237, 196, uint8(fadeA * 150))
      colorB = rgbx(255, 237, 196, uint8(fadeB * 150))
      clear = rgbx(255, 237, 196, 0)
    renderer.addTriangle([first.inner, last.inner, b], [clear, clear, colorB])
    renderer.addTriangle([first.inner, b, a], [clear, colorB, colorA])
    renderer.addTriangle([a, b, last.tip], [colorA, colorB, clear])
    renderer.addTriangle([a, last.tip, first.tip], [colorA, clear, clear])
