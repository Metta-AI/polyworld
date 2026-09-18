import gltf, vmath
import polyworld/animblend

proc fixture(): tuple[root: Node, player: ClipPlayer] =
  ## Makes two linear clips for deterministic playback checks.
  result.root = Node(visible: true, baseVisible: true,
    scale: vec3(1), baseScale: vec3(1), rot: quat(), baseRot: quat())
  for i in 0 .. 1:
    result.root.animations.add AnimationClip(name: "clip" & $i, duration: 10,
      channels: @[AnimationChannel(target: result.root, path: AnimTranslation,
        interpolation: aiLinear, times: @[0'f32, 10],
        valuesVec3: @[vec3(i.float32 * 20, 0, 0),
          vec3(i.float32 * 20 + 10, 0, 0)])])
  result.player = newClipPlayer(result.root)
  result.player.play(0, fade = 0)

echo "Pause, speed and seek control one playback clock"
block:
  let f = fixture()
  f.player.timeScale = 2
  f.player.update(1)
  doAssert f.player.currentTime == 2 and f.root.pos.x == 2
  f.player.paused = true
  f.root.pos = vec3(99)
  f.player.update(5)
  doAssert f.player.currentTime == 2 and f.root.pos.x == 2
  f.player.seek(12)
  doAssert f.player.currentTime == 12 and f.root.pos.x == 2

echo "Interrupted fades continue from the displayed pose"
block:
  let f = fixture()
  f.player.update(1)
  f.player.play(1, fade = 2)
  f.player.update(0.5)
  let displayed = f.root.pos
  f.player.play(0, fade = 1)
  f.player.update(0)
  doAssert length(f.root.pos - displayed) < 1e-6

echo "One-shots hold their final pose and chain on the next update"
block:
  let f = fixture()
  f.player.setRule("clip0", ClipRule(loop: false, next: "clip1"))
  f.player.paused = true
  f.player.seek(20)
  doAssert f.root.pos.x == 10 and f.player.current == 0
  f.player.paused = false
  f.player.update(0.1)
  doAssert f.player.current == 1

echo "Shared models do not leak another player's pose into a transition"
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
  doAssert length(shared.root.pos - isolated.root.pos) < 1e-6

echo "Held actions stay at their last frame after a looping action"
block:
  let f = fixture()
  f.player.setRule("clip1", ClipRule(loop: false, hold: true))
  f.player.update(1)
  f.player.play("clip1", 0)
  f.player.update(25)
  doAssert f.player.current == 1
  doAssert f.root.pos.x == 30
  f.player.update(10)
  doAssert f.player.current == 1 and f.root.pos.x == 30

echo "Animation playback control tests passed"
