## Programmatic control of the browser replay viewer for embedding pages.
##
## A game opts in by calling `installReplayControl` once its transport and
## camera exist, then `publishReplayControlFrame` after presenting each frame.
## The C exports below are what `replay.html` wraps as `window.polyworldReplay`
## and its postMessage bridge. They run between frames while the main loop
## waits for the display, so they may change the transport directly.
##
## Screen positions are framebuffer pixels with the origin at the top left.
## World positions are the game's render space. Vector results are read back
## one component at a time through `polyworld_replay_result`.

import
  vmath,
  player, rtscameras

const EmbeddedCatchUpSeconds* = 0.033
  ## Embedded viewers seek in short slices so the host page stays responsive.

type
  ReplayCameraMode* = enum
    DirectorCamera
      ## The game's automatic camera chooses the shots.
    FixedCamera
      ## A still camera over `target` at `distance`.
    FollowCamera
      ## The camera follows unit `id`.
    FrozenCamera
      ## The camera holds its current pose.

  ReplayCameraRequest* = object
    mode*: ReplayCameraMode
    target*: Vec2
      ## Render-space x and z for `FixedCamera`.
    distance*: float32
      ## Camera distance for `FixedCamera`; zero or less keeps the current one.
    id*: int32
      ## Unit for `FollowCamera`.

  ReplayUnit* = object
    found*: bool
      ## Whether the unit exists and is visible in the current view.
    alive*: bool
    position*: Vec3
      ## Drawn render-space position, including interpolation.
    seat*: int32
      ## Zero-based player seat for a player-controlled unit, else -1.

  ReplayControlHooks* = object
    ## Game callbacks for queries that need the game's own scene.
    groundY*: proc(x, z: float32): float32
      ## Drawn ground height at a render-space x and z.
    pick*: proc(screen: Vec2, viewProjection: Mat4): int32
      ## Returns the unit drawn under a framebuffer pixel, or 0.
    unit*: proc(id: int32): ReplayUnit
    camera*: proc(request: ReplayCameraRequest)

  ReplayControl = object
    transport: ptr Player
    hooks: ReplayControlHooks
    viewProjection: Mat4
    viewport: Vec2
    seekId: int32
      ## Caller's identifier for the last seek requested through control.
    seekTick: int32
    seekSerial: int
      ## Transport seek serial of that request, to notice later seeks.

var
  control: ReplayControl
  results: array[8, float32]

when defined(emscripten):
  {.emit: "#include <emscripten.h>".}
  {.pragma: replayExport, exportc, cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".}
else:
  {.pragma: replayExport, exportc, cdecl.}

proc replayEmbedded*(): bool =
  ## Returns whether the page asked for a bare canvas driven by its host.
  ## Embedded viewers hide their HUD; `replay.html` blocks direct input.
  when defined(emscripten):
    var embedded: cint
    {.emit: "`embedded` = EM_ASM_INT({ return Module.polyworldEmbed ? 1 : 0; });".}
    embedded != 0
  else:
    false

proc replayLoopOption(): int32 =
  ## Returns 0 or 1 when the page chose looping, or -1 to keep the default.
  when defined(emscripten):
    var loop: cint
    {.emit: """`loop` = EM_ASM_INT({
      return Module.polyworldLoop === undefined ? -1 : (Module.polyworldLoop ? 1 : 0);
    });""".}
    loop.int32
  else:
    -1

proc installReplayControl*(transport: var Player, hooks: ReplayControlHooks) =
  ## Enables the exports for one viewer. `transport` must outlive the viewer.
  control = ReplayControl(transport: transport.addr, hooks: hooks, seekTick: -1)
  if replayEmbedded():
    transport.catchUpSeconds = EmbeddedCatchUpSeconds
  let loop = replayLoopOption()
  if loop >= 0:
    transport.repeating = loop == 1

proc installed(): bool =
  control.transport != nil

proc projectToScreen*(
    point: Vec3,
    viewProjection: Mat4,
    viewport: Vec2,
    screen: var Vec2
): bool =
  ## Projects a world point to pixels. Returns false behind the camera.
  let clip = viewProjection * vec4(point.x, point.y, point.z, 1)
  if clip.w <= 0:
    return false
  screen = vec2(
    (clip.x / clip.w * 0.5'f32 + 0.5'f32) * viewport.x,
    (0.5'f32 - clip.y / clip.w * 0.5'f32) * viewport.y
  )
  true

proc unprojectToGround*(
    screen: Vec2,
    viewProjection: Mat4,
    viewport: Vec2,
    groundY: proc(x, z: float32): float32,
    point: var Vec3
): bool =
  ## Intersects the pixel's camera ray with the drawn ground.
  ## Each pass re-aims at the height under the previous hit, which converges
  ## quickly on gentle terrain. Returns false for rays parallel to the ground.
  let (origin, dir) = mouseRay(screen, viewport, viewProjection)
  if abs(dir.y) < 1e-6'f32:
    return false
  var y = 0.0'f32
  for i in 0 ..< 6:
    point = origin + dir * ((y - origin.y) / dir.y)
    y = groundY(point.x, point.z)
  point.y = y
  true

proc publishReplayControlFrame*(viewProjection: Mat4, viewport: IVec2) =
  ## Records the presented camera and reports the frame to the page.
  ## Call it after presenting, next to `reportReplayFrame`.
  if not installed():
    return
  control.viewProjection = viewProjection
  control.viewport = viewport.vec2
  when defined(emscripten):
    let
      matrix = cast[ptr UncheckedArray[float32]](control.viewProjection.addr)
      transport = control.transport[]
      tick = transport.tick
      endTick = transport.timelineEnd
      playing = transport.playing
      seeking = transport.targetTick >= 0 or transport.restoreTick >= 0
      speed = transport.speed
      looping = transport.repeating
      width = viewport.x
      height = viewport.y
      current = transport.seekSerial == control.seekSerial
      seekId = if current: control.seekId else: 0'i32
      seekTick = if current: control.seekTick else: -1'i32
    {.emit: """
    EM_ASM({
      if (!Module.polyworldControlFrame) return;
      var viewProjection = Array.from(HEAPF32.subarray($0 >> 2, ($0 >> 2) + 16));
      Module.polyworldControlFrame({
        tick: $1, endTick: $2, playing: !!$3, seeking: !!$4, speed: $5,
        loop: !!$6, width: $7, height: $8, seekId: $9, seekTick: $10,
        viewProjection: viewProjection
      });
    }, `matrix`, `tick`, `endTick`, `playing`, `seeking`, `speed`, `looping`,
      `width`, `height`, `seekId`, `seekTick`);
    """.}

proc polyworld_replay_ready*(): int32 {.replayExport.} =
  ## Returns 1 once the game has installed replay control.
  int32(installed())

proc polyworld_replay_result*(index: int32): float32 {.replayExport.} =
  ## Reads one component written by the last vector-returning call.
  results[clamp(index, 0, results.high)]

proc polyworld_replay_tick*(): int32 {.replayExport.} =
  ## Returns the current simulation tick, or -1 before installation.
  if installed(): control.transport[].tick else: -1

proc polyworld_replay_end_tick*(): int32 {.replayExport.} =
  ## Returns the last tick of the replay, or -1 before installation.
  if installed(): control.transport[].timelineEnd else: -1

proc polyworld_replay_seek*(tick, seekId: int32) {.replayExport.} =
  ## Starts an exact seek, keeping the play state. It lands over later
  ## frames, which report `seekId` until another seek replaces it.
  if not installed():
    return
  let transport = control.transport
  transport[].seekTo(tick, play = transport.playing)
  control.seekId = seekId
  control.seekTick = clamp(tick, 0'i32, transport[].timelineEnd)
  control.seekSerial = transport.seekSerial

proc polyworld_replay_cancel_seek*() {.replayExport.} =
  ## Stops a seek on the last simulated tick, keeping the play state.
  if installed():
    control.transport[].cancelSeek()

proc polyworld_replay_play*() {.replayExport.} =
  ## Starts playback, rewinding first when already at the end.
  if installed():
    control.transport[].play()

proc polyworld_replay_pause*() {.replayExport.} =
  ## Stops playback and any seek in progress.
  if installed():
    control.transport[].pause()

proc polyworld_replay_set_speed*(speed: int32): int32 {.replayExport.} =
  ## Selects the fastest supported multiplier at or below `speed`.
  ## Returns the applied multiplier.
  if not installed():
    return 0
  control.transport[].setSpeed(speedIndexOf(speed))
  control.transport[].speed

proc polyworld_replay_set_loop*(loop: int32) {.replayExport.} =
  ## Turns rewinding to the first tick at the end on or off.
  if installed():
    control.transport.repeating = loop != 0

proc polyworld_replay_set_seek_slice*(milliseconds: float32) {.replayExport.} =
  ## Sets how long each frame may simulate while seeking. Shorter slices keep
  ## the page more responsive; longer ones finish seeks sooner.
  if installed():
    control.transport.catchUpSeconds = clamp(milliseconds, 1, 1000) / 1000

proc polyworld_replay_camera*(
    mode, id: int32,
    x, z, distance: float32
) {.replayExport.} =
  ## Selects the director (0), a fixed view over x and z (1), follows
  ## unit `id` (2), or holds the current view (3).
  if not installed() or mode notin 0'i32 .. ReplayCameraMode.high.ord.int32:
    return
  control.hooks.camera(ReplayCameraRequest(
    mode: ReplayCameraMode(mode),
    target: vec2(x, z),
    distance: distance,
    id: id
  ))

proc polyworld_replay_project*(x, y, z: float32): int32 {.replayExport.} =
  ## Projects a world point to pixels in results 0 and 1. Returns 1 on success.
  var screen: Vec2
  if installed() and projectToScreen(
      vec3(x, y, z), control.viewProjection, control.viewport, screen):
    results[0] = screen.x
    results[1] = screen.y
    return 1

proc polyworld_replay_unproject*(x, y: float32): int32 {.replayExport.} =
  ## Finds the ground point under a pixel in results 0 to 2.
  var point: Vec3
  if installed() and unprojectToGround(vec2(x, y), control.viewProjection,
      control.viewport, control.hooks.groundY, point):
    results[0] = point.x
    results[1] = point.y
    results[2] = point.z
    return 1

proc polyworld_replay_ground_y*(x, z: float32): float32 {.replayExport.} =
  ## Returns the drawn ground height at a world x and z.
  if installed(): control.hooks.groundY(x, z) else: 0

proc polyworld_replay_pick*(x, y: float32): int32 {.replayExport.} =
  ## Returns the unit drawn under a pixel, or 0.
  if installed(): control.hooks.pick(vec2(x, y), control.viewProjection)
  else: 0

proc polyworld_replay_unit*(id: int32): int32 {.replayExport.} =
  ## Writes a unit's drawn position to results 0 to 2, its seat to 3 and
  ## 1 or 0 for alive to 4. Returns 0 when the unit is not found.
  if not installed():
    return 0
  let unit = control.hooks.unit(id)
  if not unit.found:
    return 0
  results[0] = unit.position.x
  results[1] = unit.position.y
  results[2] = unit.position.z
  results[3] = unit.seat.float32
  results[4] = float32(unit.alive)
  1
