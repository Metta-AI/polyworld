import gltf, vmath
import polyworld/animblend

proc fixture(): tuple[root: Node, player: ClipPlayer] =
  result.root = Node(visible: true, baseVisible: true,
    scale: vec3(1), baseScale: vec3(1), rot: quat(), baseRot: quat())
  for i in 0 .. 1:
    result.root.animations.add AnimationClip(name: "clip" & $i, duration: 10,
      channels: @[AnimationChannel(target: result.root, path: AnimTranslation,
        interpolation: aiLinear, times: @[0'f32, 10'f32],
        valuesVec3: @[vec3(i.float32 * 20, 0, 0), vec3(i.float32 * 20 + 10, 0, 0)])])
  result.player = newClipPlayer(result.root)
  result.player.play(0, fade = 0)

echo "Default playback and frame-rate independent time scaling"
block:
  let normal = fixture()
  let fast = fixture()
  doAssert normal.player.timeScale == 1
  fast.player.timeScale = 2
  normal.player.update(2)
  fast.player.update(1)
  doAssert abs(normal.root.pos.x - 2) < 1e-6
  doAssert length(normal.root.pos - fast.root.pos) < 1e-6
  let slow = fixture()
  slow.player.timeScale = 0.5
  for i in 0 ..< 40:
    slow.player.update(0.1)
  doAssert abs(slow.root.pos.x - 2) < 1e-5

echo "Pause reapplies the frozen pose and resumes without a jump"
block:
  let f = fixture()
  f.player.update(1)
  f.player.paused = true
  f.root.pos = vec3(99)
  f.player.update(5)
  doAssert f.player.currentTime == 1
  doAssert abs(f.root.pos.x - 1) < 1e-6
  f.player.paused = false
  f.player.update(1)
  doAssert abs(f.root.pos.x - 2) < 1e-6
  f.player.timeScale = 0
  f.player.update(5)
  doAssert f.player.currentTime == 2
  f.player.timeScale = 0.5
  f.player.update(2)
  doAssert abs(f.root.pos.x - 3) < 1e-6

echo "Outgoing clip, incoming clip and crossfade share one scaled clock"
block:
  let normal = fixture()
  let fast = fixture()
  normal.player.update(1)
  fast.player.update(1)
  normal.player.play(1, fade = 2)
  fast.player.play(1, fade = 2)
  fast.player.timeScale = 2
  normal.player.update(0.5)
  fast.player.update(0.25)
  doAssert length(normal.root.pos - fast.root.pos) < 1e-6
  let frozen = fast.root.pos
  fast.player.paused = true
  fast.player.update(100)
  doAssert fast.player.fading
  doAssert length(fast.root.pos - frozen) < 1e-6
  fast.player.paused = false
  fast.player.update(0.75)
  doAssert not fast.player.fading
  doAssert abs(fast.root.pos.x - 22) < 1e-6

echo "One-shot chaining uses scaled presentation time"
block:
  let f = fixture()
  f.player.setRule("clip0", ClipRule(loop: false, next: "clip1"))
  f.player.timeScale = 2
  f.player.update(4)
  doAssert f.player.current == 0
  f.player.update(1)
  doAssert f.player.current == 1

echo "Invalid rates fail without changing the active playback rate"
block:
  let f = fixture()
  for invalid in [-1'f32, NaN.float32, Inf.float32, NegInf.float32]:
    doAssertRaises(ValueError):
      f.player.timeScale = invalid
    doAssert f.player.timeScale == 1

echo "Seeking samples immediately and preserves pause and speed"
block:
  let f = fixture()
  f.player.timeScale = 0.5
  f.player.paused = true
  f.player.seek(4)
  doAssert f.root.pos.x == 4
  doAssert f.player.currentTime == 4
  doAssert f.player.paused and f.player.timeScale == 0.5
  f.player.seek(12)
  doAssert abs(f.root.pos.x - 2) < 1e-6
  f.player.setRule("clip0", ClipRule(loop: false, next: "clip1"))
  f.player.seek(20)
  doAssert f.root.pos.x == 10
  doAssert f.player.current == 0 and f.player.currentTime == 10
  f.player.update(1)
  doAssert f.player.current == 0 and f.root.pos.x == 10
  f.player.paused = false
  f.player.update(0)
  doAssert f.player.current == 0
  for invalid in [-1'f32, NaN.float32, Inf.float32]:
    doAssertRaises(ValueError):
      f.player.seek(invalid)
    doAssert f.player.currentTime == 10
  f.player.update(0.1)
  doAssert f.player.current == 1

echo "Interrupted transitions preserve the displayed composite pose"
block:
  let f = fixture()
  f.player.update(1)
  f.player.play(1, fade = 2)
  f.player.update(0.5)
  let composed = f.root.pos
  doAssert abs(composed.x - 6.25) < 1e-6
  f.player.play(0, fade = 1)
  f.player.update(0)
  doAssert length(f.root.pos - composed) < 1e-6
  f.player.update(0.5)
  doAssert abs(f.root.pos.x - 3.375) < 1e-6
  f.player.play(-1, fade = 1)
  f.player.update(0)
  doAssert abs(f.root.pos.x - 3.375) < 1e-6
  f.player.update(0.5)
  let fadingToBind = f.root.pos
  f.player.play(1, fade = 1)
  f.player.update(0)
  doAssert length(f.root.pos - fadingToBind) < 1e-6
  f.player.seek(2)
  doAssert not f.player.fading and f.root.pos.x == 22

echo "Invalid playback deltas and fades leave the pose unchanged"
block:
  let f = fixture()
  f.player.update(1)
  for invalid in [-1'f32, NaN.float32, Inf.float32]:
    doAssertRaises(ValueError):
      f.player.update(invalid)
    doAssert f.player.currentTime == 1
    doAssertRaises(ValueError):
      f.player.play(0, fade = invalid)
    doAssert f.player.currentTime == 1

echo "Shared models cannot leak another player's pose into transitions"
for next in ["", "clip0"]:
  let shared = fixture()
  let isolated = fixture()
  for f in [shared, isolated]:
    f.root.animations[1].duration = 0.4
    f.root.animations[1].channels[0].times[1] = 0.4
    f.player.setRule("clip1", ClipRule(loop: false, next: next))
    f.player.update(1)
    f.player.play(1, fade = 2)
    f.player.update(0.1)
  let other = newClipPlayer(shared.root)
  other.play(1, fade = 0)
  other.update(0)
  doAssert shared.root.pos != isolated.root.pos
  for dt in [0.4'f32, 0.1, 0.2]:
    shared.player.update(dt)
    isolated.player.update(dt)
    doAssert shared.player.current == 0
    doAssert length(shared.root.pos - isolated.root.pos) < 1e-6
    other.update(0)
block:
  let shared = fixture()
  let isolated = fixture()
  for f in [shared, isolated]:
    f.player.update(1)
    f.player.play(1, fade = 2)
    f.player.update(0.5)
  let other = newClipPlayer(shared.root)
  other.play(1, fade = 0)
  other.update(0)
  for f in [shared, isolated]:
    f.player.play(0, fade = 1)
    f.player.update(0)
  doAssert length(shared.root.pos - isolated.root.pos) < 1e-6,
    "explicit transitions must sample their own player, not a shared tree's last writer"

echo "Animation playback control tests passed"
