## Attack clips the character library lacks, posed at load time on the
## hero's own rig: the Ranger's bow shot, the Arcanist's staff cast, the
## Fighter's blazing slash and taunt, and the Druid's hammer slam.
##
## The library has no bow or staff clip. The stand-ins were a pistol recoil
## and a one-handed spell flick that leaves the staff hanging at the side,
## and neither reads from the camera. Each clip here is a handful of key
## poses over the first frame of the hero's idle, pushed past life so it
## still reads from above, with the blow landing on `AttackImpactTime`.
##
## The bow shot: the body turns side-on, the bow arm locks out at the
## target, the string hand pulls back past the jaw, and on release the arrow
## is gone, the empty hand flies back and the bow kicks up.
##
## The staff cast: the staff rises and cocks far behind the head as the
## caster leans back, then whips forward over the target with a lunge while
## the orb hand flings back, overshoots low, and settles.
##
## The blazing slash: the sword comes back low past the right hip as the
## body coils away, then whips flat across the front in one wide sweep that
## ends far out on the left, so the blade draws its whole arc on the floor
## of the view.
##
## The taunt: he hunches over, then rears back with his chest thrown open,
## the sword flung out to one side and the off arm to the other, the widest
## shape a body makes seen from above.
##
## The hammer slam: the staff goes up over the head and cocks far behind it
## as the body rears back, then comes straight down over the top onto the
## target with a lunge and a crouch, the orb hand flung back behind.
##
## Model space has +Z toward the target, +X on the hero's left and +Y up.
## Both props sit in the right hand.

import
  std/tables,
  gltf, gltf/animations, vmath,
  polyworld/characters,
  assets

const
  AttackClipDuration* = 1.0'f32
  AttackImpactTime* = 0.6'f32
    ## The clip time the blow lands: the string lets go, the staff points.
    ## The renderer lands it on the hit tick.
  BowKeys = [0.0'f32, 0.2, 0.5, AttackImpactTime, 0.66, 0.82, 1.0]
  StaffKeys = [0.0'f32, 0.25, 0.5, AttackImpactTime, 0.75, 1.0]
  SlashKeys = [0.0'f32, 0.2, 0.5, 0.55, AttackImpactTime, 0.75, 1.0]
  RoarKeys = [0.0'f32, 0.5, AttackImpactTime, 0.8, 1.0]
  SlamKeys = [0.0'f32, 0.25, 0.5, AttackImpactTime, 0.75, 1.0]
  BladeSamples = 60
  BladeRoot = 0.2'f32
    ## How far up the blade its edge starts, past the hand and the guard.
  Up = vec3(0, 1, 0)
  Side = vec3(1, 0, 0)

type
  BladePose* = object
    ## Where a held blade is at one moment of a clip, in the model's frame.
    root*, tip*: Vec3

  Rig = object
    ## The skeleton the idle clip animates, with each bone's parent.
    bones: Table[string, Node]
    parents: Table[pointer, Node]

proc mapParents(rig: var Rig, node: Node) =
  ## Records the parent of every node under `node`.
  for child in node.nodes:
    rig.parents[cast[pointer](child)] = node
    rig.mapParents(child)

proc global(rig: Rig, start: Node): (Vec3, Quat) =
  ## Returns a node's model-space origin and rotation. The rig is unscaled.
  var
    chain: seq[Node]
    node = start
  while true:
    chain.add node
    let key = cast[pointer](node)
    if key notin rig.parents:
      break
    node = rig.parents[key]
  var
    pos = vec3(0, 0, 0)
    rot = quat(0, 0, 0, 1)
  for i in countdown(chain.high, 0):
    pos = pos + quatRotate(rot, chain[i].pos)
    rot = quatMultiply(rot, chain[i].rot)
  (pos, rot)

proc at(rig: Rig, name: string): Vec3 =
  ## Returns a bone's model-space origin.
  rig.global(rig.bones[name])[0]

proc rotation(rig: Rig, name: string): Quat =
  ## Returns a bone's model-space rotation.
  rig.global(rig.bones[name])[1]

proc rotateTo(rig: Rig, name: string, worldRot: Quat) =
  ## Gives a bone a model-space rotation, keeping its origin in place.
  let
    node = rig.bones[name]
    parentRot =
      if cast[pointer](node) in rig.parents:
        rig.global(rig.parents[cast[pointer](node)])[1]
      else:
        quat(0, 0, 0, 1)
  node.rot = quatMultiply(quatInverse(parentRot), worldRot).normalize()

proc turn(rig: Rig, name: string, axis: Vec3, angle: float32) =
  ## Rotates a bone about a model-space axis through its own origin.
  rig.rotateTo(
    name, quatMultiply(fromAxisAngle(axis, angle), rig.rotation(name)))

proc point(rig: Rig, name, child: string, direction: Vec3) =
  ## Swings a bone so the way to its child runs along `direction`.
  let current = normalize(rig.at(child) - rig.at(name))
  rig.rotateTo(name, quatMultiply(
    fromTwoVectors(current, normalize(direction)), rig.rotation(name)))

proc reach(rig: Rig, arm, forearm, hand: string, target, pole: Vec3) =
  ## Two-bone reach: puts the hand on `target` with the elbow bent toward
  ## `pole`, stopping just short when the target is out of reach.
  let
    shoulder = rig.at(arm)
    upper = length(rig.at(forearm) - shoulder)
    lower = length(rig.at(hand) - rig.at(forearm))
    offset = target - shoulder
    distance = clamp(length(offset), 0.01'f32, (upper + lower) * 0.999'f32)
    along = normalize(offset)
    bend = normalize(pole - along * dot(pole, along))
    a = (upper * upper - lower * lower + distance * distance) /
      (2 * distance)
    elbow = shoulder + along * a + bend * sqrt(max(upper * upper - a * a, 0))
  rig.point(arm, forearm, elbow - shoulder)
  rig.point(forearm, hand, shoulder + along * distance - elbow)

proc stance(rig: Rig, yaw, lean, crouch, recoil: float32) =
  ## Turns the body so the left shoulder leads by `yaw` (negative leads with
  ## the right), leans back by `lean`, sinks by `crouch`, shifts back from
  ## the target by `recoil`, and keeps the head looking at the target.
  rig.bones["Hips"].pos = rig.bones["Hips"].pos + vec3(0, -crouch, -recoil)
  rig.turn("Hips", Up, -yaw * 0.35)
  for name in ["Spine", "Spine1", "Spine2"]:
    rig.turn(name, Up, -yaw * 0.65 / 3)
  rig.turn("Spine1", Side, -lean)
  rig.turn("Neck", Up, yaw * 0.5)
  rig.turn("Head", Up, yaw * 0.5)
  rig.turn("Head", Side, lean)

proc leftHand(rig: Rig, target, pole: Vec3) =
  ## Puts the left hand on `target`.
  rig.reach("LeftArm", "LeftForeArm", "LeftHand", target, pole)

proc rightHand(rig: Rig, target, pole: Vec3) =
  ## Puts the right hand on `target`.
  rig.reach("RightArm", "RightForeArm", "RightHand", target, pole)

## The bow shot

proc bowArm(rig: Rig, lift, extension: float32): Vec3 =
  ## Locks the bow arm out at the target, raised by `lift`, and returns the
  ## bow hand.
  let
    shoulder = rig.at("LeftArm")
    span = length(rig.at("LeftForeArm") - shoulder) +
      length(rig.at("LeftHand") - rig.at("LeftForeArm"))
  rig.leftHand(
    shoulder + normalize(vec3(0, 0.1'f32 + lift, 1)) * span * extension,
    vec3(0.4, -1, 0)
  )
  rig.at("LeftHand")

proc bowPose(rig: Rig, key: int) =
  ## Poses one key of the shot over the idle stance. Keys run: ready, nock,
  ## full draw, anchor at the impact time, release, follow-through, ready.
  ## The camera looks down on a big hood, so the string hand works well
  ## clear of the head and the release flings it straight back.
  case key
  of 1:
    rig.stance(0.9, -0.06, 0.04, 0)
    let bow = rig.bowArm(0.05, 0.92)
    rig.rightHand(bow + vec3(-0.06, -0.04, -0.2), vec3(-0.6, -0.8, -0.3))
  of 2:
    rig.stance(1.2, 0.18, 0.08, 0)
    discard rig.bowArm(0.15, 1.0)
    rig.rightHand(
      rig.at("Head") + vec3(-0.12, 0.0, -0.42), vec3(-0.2, 0.5, -1))
  of 3:
    rig.stance(1.25, 0.2, 0.09, 0)
    discard rig.bowArm(0.16, 1.0)
    rig.rightHand(
      rig.at("Head") + vec3(-0.13, 0.0, -0.47), vec3(-0.2, 0.5, -1))
  of 4:
    rig.stance(1.2, 0.32, 0, 0.12)
    discard rig.bowArm(0.55, 0.97)
    rig.rightHand(
      rig.at("Head") + vec3(-0.15, 0.05, -0.9), vec3(-0.6, -0.2, -0.6))
  of 5:
    rig.stance(1.05, 0.15, 0.02, 0.06)
    discard rig.bowArm(0.25, 0.93)
    rig.rightHand(
      rig.at("Head") + vec3(-0.2, -0.05, -0.75), vec3(-0.6, 0, -1))
  else:
    discard

proc hideArrows(shot: AnimationClip, node: Node, arrows: openArray[string]) =
  ## Hides the nocked arrow from the release until the shot resets, so the
  ## string hand flies back empty.
  if node.name in arrows:
    shot.channels.add AnimationChannel(
      target: node,
      path: AnimVisibility,
      interpolation: aiStep,
      times: @[0.0'f32, AttackImpactTime + 0.01, AttackClipDuration],
      valuesFloat: @[1.0'f32, 0, 1]
    )
  for child in node.nodes:
    shot.hideArrows(child, arrows)

## The staff cast

proc collectHeld(
    node: Node, held: openArray[string], bone: string, points: var seq[Vec3]
) =
  ## Gathers the held props' vertices in the holding bone's own frame.
  if node.name in held and node.mesh != nil and node.skin != nil:
    for i, joint in node.skin.joints:
      if joint.name == bone and i < node.skin.inverseBindMatrices.len:
        for primitive in node.mesh.primitives:
          for vertex in primitive.points:
            points.add node.skin.inverseBindMatrices[i] * vertex
  for child in node.nodes:
    child.collectHeld(held, bone, points)

proc heldAxis(root: Node, held: openArray[string], bone: string): Vec3 =
  ## Measures a held prop's long axis in the holding bone's frame, pointing
  ## from its plain end to its ornate one, the end most vertices crowd.
  var points: seq[Vec3]
  root.collectHeld(held, bone, points)
  if points.len == 0:
    return vec3(0, 0, 1)
  var middle = vec3(0, 0, 0)
  for vertex in points:
    middle = middle + vertex
  middle = middle / points.len.float32
  var a = points[0]
  for vertex in points:
    if length(vertex - middle) > length(a - middle):
      a = vertex
  var b = points[0]
  for vertex in points:
    if length(vertex - a) > length(b - a):
      b = vertex
  let span = length(b - a)
  var nearA, nearB = 0
  for vertex in points:
    if length(vertex - a) < span * 0.2:
      inc nearA
    if length(vertex - b) < span * 0.2:
      inc nearB
  if nearB >= nearA: normalize(b - a) else: normalize(a - b)

proc wield(rig: Rig, grip, pole, direction, staff: Vec3) =
  ## Puts the right hand on `grip` and turns it so the staff, which runs
  ## along `staff` in the hand's frame, points its head along `direction`.
  rig.rightHand(grip, pole)
  let current = quatRotate(rig.rotation("RightHand"), staff)
  rig.rotateTo("RightHand", quatMultiply(
    fromTwoVectors(current, normalize(direction)), rig.rotation("RightHand")))

proc staffPose(rig: Rig, key: int, staff: Vec3) =
  ## Poses one key of the cast over the idle stance. Keys run: ready, raise,
  ## wind-up, strike at the impact time, follow-through, ready. The staff is
  ## taller than its caster, so the head sweeps a wide, flat arc from far
  ## behind to high over the target, which is what reads from above: cocked
  ## upright it would hide under the health bars.
  case key
  of 1:
    rig.stance(0.3, 0.12, 0.02, 0)
    rig.wield(
      rig.at("RightArm") + vec3(-0.12, 0.45, -0.15),
      vec3(-1, 0, 0), vec3(0, 1, -0.6), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.25, -0.45, -0.15), vec3(1, 0, 0))
  of 2:
    rig.stance(0.6, 0.28, -0.05, 0.05)
    rig.wield(
      rig.at("RightArm") + vec3(-0.1, 0.3, -0.45),
      vec3(-1, 0.2, 0), vec3(0, 0.35, -1), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.1, -0.05, 0.55), vec3(1, -1, 0))
  of 3:
    rig.stance(-0.35, -0.25, 0.1, -0.15)
    rig.wield(
      rig.at("RightArm") + vec3(0.12, 0.0, 0.62),
      vec3(-1, -0.5, 0), vec3(0, 0.7, 1), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.5, -0.15, -0.3), vec3(0, -1, 0))
  of 4:
    rig.stance(-0.4, -0.3, 0.12, -0.18)
    rig.wield(
      rig.at("RightArm") + vec3(0.15, -0.12, 0.6),
      vec3(-1, -0.5, 0), vec3(0, 0.45, 1), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.5, -0.25, -0.2), vec3(0, -1, 0))
  else:
    discard

## The blazing slash

proc heldTip(root: Node, held: openArray[string], bone: string): Vec3 =
  ## Finds a held blade's point in the holding bone's own frame: whatever
  ## of it lies farthest from the hand.
  var points: seq[Vec3]
  root.collectHeld(held, bone, points)
  for vertex in points:
    if length(vertex) > length(result):
      result = vertex

proc slashPose(rig: Rig, key: int, sword: Vec3) =
  ## Poses one key of the slash over the idle stance. Keys run: ready, draw,
  ## full coil, the sweep's middle, its end at the impact time, the
  ## follow-through, ready. The sword stays nearly flat all the way round
  ## and passes well clear of the body, which is what reads from above.
  let wrist = rig.at("RightArm")
  case key
  of 1:
    rig.stance(-0.5, 0.05, 0.05, 0.04)
    rig.wield(wrist + vec3(-0.22, -0.2, -0.12),
      vec3(-1, -0.2, -0.3), vec3(-0.9, 0.3, -0.6), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(0.2, -0.3, 0.3), vec3(1, -1, 0))
  of 2:
    rig.stance(-1.1, 0.1, 0.12, 0.1)
    rig.wield(wrist + vec3(-0.34, -0.26, -0.34),
      vec3(-1, -0.2, -0.3), vec3(-0.75, 0.22, -0.75), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(0.3, -0.2, 0.45), vec3(1, -1, 0))
  of 3:
    rig.stance(-0.1, -0.12, 0.16, -0.14)
    rig.wield(wrist + vec3(-0.02, -0.16, 0.62),
      vec3(-1, -0.6, 0), vec3(-0.08, 0.02, 1), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(0.42, -0.2, -0.1), vec3(1, -1, 0))
  of 4:
    rig.stance(1.0, -0.18, 0.16, -0.16)
    rig.wield(wrist + vec3(0.52, -0.2, 0.34),
      vec3(-0.2, -1, -0.2), vec3(0.92, 0.02, 0.4), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(0.3, -0.25, -0.34), vec3(1, -1, 0))
  of 5:
    rig.stance(1.15, -0.12, 0.12, -0.1)
    rig.wield(wrist + vec3(0.46, -0.28, 0.18),
      vec3(-0.2, -1, -0.2), vec3(0.95, -0.08, 0.1), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(0.22, -0.3, -0.3), vec3(1, -1, 0))
  else:
    discard

proc roarPose(rig: Rig, key: int, sword: Vec3) =
  ## Poses one key of the taunt over the idle stance. Keys run: ready, the
  ## hunch, the roar at the impact time, its hold, ready.
  case key
  of 1:
    rig.stance(0, -0.3, 0.14, 0)
    rig.wield(rig.at("RightArm") + vec3(0.12, -0.34, 0.26),
      vec3(-1, -0.4, 0), vec3(0.5, -0.5, 0.7), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(-0.12, -0.34, 0.26), vec3(1, -0.4, 0))
  of 2:
    rig.stance(0, 0.34, -0.02, 0.1)
    rig.wield(rig.at("RightArm") + vec3(-0.44, 0.2, 0.04),
      vec3(-0.4, -1, 0), vec3(-0.85, 0.5, 0.1), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(0.46, 0.2, 0.04), vec3(0.4, -1, 0))
  of 3:
    rig.stance(0, 0.26, 0, 0.08)
    rig.wield(rig.at("RightArm") + vec3(-0.42, 0.14, 0.04),
      vec3(-0.4, -1, 0), vec3(-0.9, 0.38, 0.1), sword)
    rig.leftHand(rig.at("LeftArm") + vec3(0.44, 0.14, 0.04), vec3(0.4, -1, 0))
  else:
    discard

## The hammer slam

proc slamPose(rig: Rig, key: int, staff: Vec3) =
  ## Poses one key of the slam over the idle stance. Keys run: ready, raise,
  ## full cock, the blow at the impact time, its hold, ready. The head goes
  ## from far behind the caster, over the top, to the floor in front of it,
  ## the longest stroke a staff makes seen from above.
  case key
  of 1:
    rig.stance(0.15, 0.15, 0, 0)
    rig.wield(
      rig.at("RightArm") + vec3(-0.05, 0.5, -0.05),
      vec3(-1, 0, 0), vec3(0, 1, -0.3), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.3, -0.35, 0.1), vec3(1, 0, 0))
  of 2:
    rig.stance(0.1, 0.32, -0.06, 0.06)
    rig.wield(
      rig.at("RightArm") + vec3(0.05, 0.55, -0.25),
      vec3(-1, 0.3, 0), vec3(0, 0.45, -1), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.2, -0.1, 0.45), vec3(1, -1, 0))
  of 3:
    rig.stance(0, -0.38, 0.15, -0.14)
    rig.wield(
      rig.at("RightArm") + vec3(0.12, -0.22, 0.58),
      vec3(-1, -0.5, 0), vec3(0, -0.6, 1), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.35, -0.3, -0.35), vec3(0, -1, 0))
  of 4:
    rig.stance(0, -0.32, 0.13, -0.12)
    rig.wield(
      rig.at("RightArm") + vec3(0.12, -0.3, 0.52),
      vec3(-1, -0.5, 0), vec3(0, -0.75, 1), staff)
    rig.leftHand(rig.at("LeftArm") + vec3(0.32, -0.32, -0.3), vec3(0, -1, 0))
  else:
    discard

proc measureBlade*(
    model: CharacterModel, clip: int, held: openArray[string]
): seq[BladePose] =
  ## Follows a held blade through a clip, so the client can light it, and
  ## the whole arc behind it, from nothing but the time into the clip.
  let
    root = model.file.root
    tip = root.heldTip(held, "RightHand")
    duration = model.clipDuration(clip)
  var hand: Node
  for node in root.walkNodes:
    if node.name == "RightHand":
      hand = node
  root.activeClips.setLen(1)
  root.activeClips[0] = clip
  for sample in 0 ..< BladeSamples:
    root.animTime = duration * sample.float32 / BladeSamples.float32
    root.updateAnimation(0)
    root.updateTransforms(model.baseTransform)
    result.add BladePose(root: hand.mat * (tip * BladeRoot), tip: hand.mat * tip)

proc bladeAt*(track: openArray[BladePose], fraction: float32): BladePose =
  ## Where a blade measured by `measureBlade` is, a fraction of the way
  ## through its clip.
  let
    place = clamp(fraction, 0, 1) * (track.len - 1).float32
    first = min(place.int, track.len - 2)
    blend = place - first.float32
  BladePose(
    root: mix(track[first].root, track[first + 1].root, blend),
    tip: mix(track[first].tip, track[first + 1].tip, blend)
  )

## Building

proc addAttackClip*(
    model: CharacterModel,
    clip, stanceClip: string,
    held: openArray[string]
): int =
  ## Builds one of the `AuthoredClips` over the first frame of `stanceClip`,
  ## with `held` naming the right hand's prop nodes, adds it to the model,
  ## and returns its clip index.
  doAssert clip in AuthoredClips, "no authored attack clip " & clip
  let
    root = model.file.root
    stance = root.animations[model.clipIndex(stanceClip)]
    keys =
      case clip
      of BowShotClip: @BowKeys
      of StaffCastClip: @StaffKeys
      of TauntRoarClip: @RoarKeys
      of HammerSlamClip: @SlamKeys
      else: @SlashKeys
    staff = root.heldAxis(held, "RightHand")
    sword = normalize(root.heldTip(held, "RightHand"))
  var rig: Rig
  rig.mapParents(root)
  for channel in stance.channels:
    rig.bones[channel.target.name] = channel.target
  var attack = AnimationClip(name: clip, duration: AttackClipDuration)
  for channel in stance.channels:
    if channel.path in {AnimTranslation, AnimRotation, AnimScale}:
      attack.channels.add AnimationChannel(
        target: channel.target,
        path: channel.path,
        interpolation: aiLinear,
        times: keys
      )
  for key in 0 ..< keys.len:
    root.resetToBase()
    stance.applyClipAt(0)
    case clip
    of BowShotClip: rig.bowPose(key)
    of StaffCastClip: rig.staffPose(key, staff)
    of TauntRoarClip: rig.roarPose(key, sword)
    of HammerSlamClip: rig.slamPose(key, staff)
    else: rig.slashPose(key, sword)
    for channel in attack.channels:
      case channel.path
      of AnimTranslation: channel.valuesVec3.add channel.target.pos
      of AnimScale: channel.valuesVec3.add channel.target.scale
      else: channel.valuesQuat.add channel.target.rot
  root.resetToBase()
  if clip == BowShotClip:
    attack.hideArrows(root, held)
  root.animations.add attack
  result = root.animations.high
  model.clips[clip] = result
