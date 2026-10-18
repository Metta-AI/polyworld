import
  vmath,
  polyworld/[player, replaycontrols]

proc flatGround(x, z: float32): float32 =
  0.5'f32

echo "Testing projection round-trips through the drawn ground"
block:
  let
    viewport = vec2(1280, 576)
    viewProjection =
      perspective(45.0'f32, viewport.x / viewport.y, 0.1'f32, 1000.0'f32) *
      lookAt(vec3(0, 30, 20), vec3(0, 0, 0), vec3(0, 1, 0))
  for screen in [vec2(640, 288), vec2(100, 500), vec2(1200, 90)]:
    var
      point: Vec3
      back: Vec2
    doAssert unprojectToGround(screen, viewProjection, viewport, flatGround, point)
    doAssert abs(point.y - 0.5) < 1e-5
    doAssert projectToScreen(point, viewProjection, viewport, back)
    doAssert (back - screen).length < 0.01
  var behind: Vec2
  doAssert not projectToScreen(vec3(0, 60, 60), viewProjection, viewport, behind)

echo "Testing control exports drive the transport and game hooks"
block:
  var
    transport = initPlayer(live = false, durationTicks = 0, playing = true)
    camera: ReplayCameraRequest
  doAssert polyworld_replay_ready() == 0
  doAssert polyworld_replay_tick() == -1
  transport.sync(400, 1000, false)
  installReplayControl(transport, ReplayControlHooks(
    groundY: flatGround,
    pick: proc(screen: Vec2, viewProjection: Mat4): int32 = 7,
    unit: proc(id: int32): ReplayUnit =
      ReplayUnit(found: id == 7, alive: false, position: vec3(1, 2, 3), seat: 4),
    camera: proc(request: ReplayCameraRequest) = camera = request
  ))
  doAssert polyworld_replay_ready() == 1
  doAssert polyworld_replay_tick() == 400
  doAssert polyworld_replay_end_tick() == 1000
  polyworld_replay_pause()
  polyworld_replay_seek(100, 5)
  doAssert transport.restoreTick == 100 and transport.targetTick == 100
  doAssert not transport.playing
  polyworld_replay_cancel_seek()
  doAssert transport.restoreTick == -1 and transport.targetTick == -1
  doAssert polyworld_replay_set_speed(8) == 4
  polyworld_replay_set_loop(0)
  doAssert not transport.repeating
  polyworld_replay_set_seek_slice(12)
  doAssert abs(transport.catchUpSeconds - 0.012) < 1e-6
  doAssert polyworld_replay_pick(10, 10) == 7
  doAssert polyworld_replay_unit(8) == 0
  doAssert polyworld_replay_unit(7) == 1
  doAssert polyworld_replay_result(2) == 3
  doAssert polyworld_replay_result(3) == 4
  doAssert polyworld_replay_result(4) == 0
  polyworld_replay_camera(3, 0, 0, 0, 0)
  doAssert camera.mode == FrozenCamera
  polyworld_replay_camera(1, 0, 5, 6, 30)
  doAssert camera.mode == FixedCamera and camera.target == vec2(5, 6)
  doAssert camera.distance == 30
  polyworld_replay_camera(9, 0, 0, 0, 0)
  doAssert camera.mode == FixedCamera

echo "Replay control tests passed"
