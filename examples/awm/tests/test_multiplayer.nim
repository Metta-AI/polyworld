## The multiplayer preview is a scene harness: these checks need no window.
import std/[math, random, unittest]
import vmath
import ../[awmcourtyard, awmmultiplayer]

const Tolerance = 0.0002'f32

proc finite(v: Vec3): bool =
  for value in [v.x, v.y, v.z]:
    if value.classify in {fcNan, fcInf, fcNegInf}: return false
  true

proc horizontalRadius(v: Vec3): float32 =
  sqrt(v.x * v.x + v.z * v.z)

proc insideBalcony(layout: MultiplayerLayout, balcony: PlayerBalcony,
    local: Vec3): bool =
  let
    world = balcony.toWorld(local)
    radial = horizontalRadius(world)
    forward = normalize(vec2(balcony.center.x, balcony.center.z))
    direction = normalize(vec2(world.x, world.z))
  radial >= layout.innerRadius - Tolerance and
    radial <= layout.outerRadius + Tolerance and
    dot(forward, direction) >= cos(layout.balconyHalfAngle) - Tolerance

proc rectangleFits(layout: MultiplayerLayout, balcony: PlayerBalcony,
    zone: Vec3, halfWidth, halfDepth: float32): bool =
  for x in [-halfWidth, halfWidth]:
    for z in [-halfDepth, halfDepth]:
      if not layout.insideBalcony(balcony, zone + vec3(x, 0, z)):
        return false
  true

proc onScreen(point: Vec3, viewProjection: Mat4): bool =
  let clip = viewProjection * vec4(point.x, point.y, point.z, 1)
  clip.w > 0 and abs(clip.x) <= clip.w and abs(clip.y) <= clip.w and
    abs(clip.z) <= clip.w

iterator handCorners(balcony: PlayerBalcony): Vec3 =
  ## Use the rendered fan's card dimensions, yaw and tilt. The complete fan
  ## must belong to the balcony even when its cards are raised off the floor.
  for slot in 0 ..< 5:
    let
      offset = slot.float32 - 2
      center = balcony.handZone + vec3(offset * 0.59,
        -abs(offset) * 0.035, abs(offset) * 0.10)
    for x in [-0.725'f32, 0.725'f32]:
      for z in [-1.025'f32, 1.025'f32]:
        let
          yawed = rotateSeat(vec3(x, 0.034, z), -offset * 0.10)
          tilted = vec3(yawed.x,
            yawed.y * cos(0.55'f32) - yawed.z * sin(0.55'f32),
            yawed.y * sin(0.55'f32) + yawed.z * cos(0.55'f32))
        yield center + tilted

suite "Multiplayer battlefield layout":
  test "the multiplayer layout rejects duel and invalid seat counts":
    for count in [-1, 0, 1, 2]:
      expect ValueError:
        discard buildMultiplayerLayout(count)

  test "every requested seat has its own separated radial balcony":
    for count in [3, 4, 5, 6, 8, 12, 24, 64]:
      let layout = buildMultiplayerLayout(count)
      check layout.playerCount == count
      check layout.balconies.len == count
      check layout.centerRadius > 0
      check layout.centerRadius < layout.innerRadius
      check layout.innerRadius < layout.outerRadius
      check layout.balconyHalfAngle > 0
      check layout.balconyHalfAngle * 2 < (2 * PI / count.float).float32
      let radius = horizontalRadius(layout.balconies[0].center)
      for index, balcony in layout.balconies:
        check balcony.playerIndex == index
        check balcony.center.finite
        check balcony.yaw.classify notin {fcNan, fcInf, fcNegInf}
        check abs(horizontalRadius(balcony.center) - radius) < Tolerance
        for other in index + 1 ..< count:
          let cosine = dot(normalize(balcony.center),
            normalize(layout.balconies[other].center))
          check cosine < cos(layout.balconyHalfAngle * 2) + Tolerance

  test "all five zones follow their balcony transform":
    for count in [3, 4, 5, 6, 8, 12, 24, 64]:
      let layout = buildMultiplayerLayout(count)
      for balcony in layout.balconies:
        let zones = [balcony.heroZone, balcony.deckZone,
          balcony.discardZone, balcony.handZone, balcony.boardZone]
        for index, zone in zones:
          let world = balcony.toWorld(zone)
          check world.finite
          check layout.insideBalcony(balcony, zone)
          check length(balcony.toLocal(world) - zone) < Tolerance
          for other in index + 1 ..< zones.len:
            check length(zone - zones[other]) > 1.0
        # A full size pile needs its entire footprint on the floor, not
        # merely an anchor that happens to fit in the stone sector.
        check layout.rectangleFits(balcony, balcony.deckZone, 0.725, 1.025)
        check layout.rectangleFits(balcony, balcony.discardZone, 0.725, 1.025)
        check layout.rectangleFits(balcony, balcony.heroZone, 0.65, 0.65)
        # Four 1.45-wide cards at 1.65-unit spacing are fully visible.
        check layout.rectangleFits(balcony, balcony.boardZone, 3.2, 1.025)
        for corner in balcony.handCorners:
          check layout.insideBalcony(balcony, corner)

  test "adding seats preserves usable radial depth":
    let reference = buildMultiplayerLayout(3)
    var previousInner = reference.innerRadius
    for count in 4 .. 24:
      let layout = buildMultiplayerLayout(count)
      check layout.innerRadius >= previousInner
      check abs((layout.outerRadius - layout.innerRadius) -
        (reference.outerRadius - reference.innerRadius)) < Tolerance
      previousInner = layout.innerRadius

suite "Multiplayer battlefield geometry and framing":
  for count in [3, 4, 6, 8]:
    let
      layout = buildMultiplayerLayout(count)
      mesh = buildMultiplayerCourtyardMesh(layout)

    test $count & " seats have complete finite textured geometry":
      check mesh.vertices.len > 0
      check mesh.vertices.len mod 3 == 0
      check mesh.commonCount + mesh.backdropCount * 2 == mesh.vertices.len
      check mesh.vertices.len < 200_000 * count
      var
        valid = true
        inside = true
        materials: set[0 .. 5]
      for vertex in mesh.vertices:
        if not vertex.position.finite or not vertex.normal.finite or
            not vertex.color.finite:
          valid = false
        for value in [vertex.uv.x, vertex.uv.y, vertex.material]:
          if value.classify in {fcNan, fcInf, fcNegInf}: valid = false
        if abs(length(vertex.normal) - 1) > 0.0001: valid = false
        if horizontalRadius(vertex.position) > layout.outerRadius + 0.9 or
            vertex.position.y < -2.8 or vertex.position.y > 3.0:
          inside = false
        if vertex.material >= 0 and vertex.material <= 5:
          materials.incl vertex.material.int
      check valid
      check inside
      # Stone, metal, vines, banners, and lantern flames all use the same
      # material categories as the original courtyard renderer.
      for material in 0 .. 4:
        check material in materials

    test $count & " seats stay fully framed in landscape and portrait":
      for aspect in [0.45'f32, 0.75'f32, 1.0'f32, 1.6'f32, 2.4'f32]:
        let
          eye = layout.cameraEye(aspect, 42.0)
          target = layout.cameraTarget()
          farPlane = max(100.0'f32, length(eye) * 3)
          view = lookAt(eye, target, vec3(0, 1, 0))
          projection = perspective(42.0'f32, aspect, 0.1'f32, farPlane)
          viewProjection = projection * view
        check eye.finite
        check target.finite
        var framed = true
        for vertex in mesh.vertices:
          if not vertex.position.onScreen(viewProjection): framed = false
        for balcony in layout.balconies:
          # Include upright hero and hand silhouettes above the floor.
          for point in [balcony.heroZone + vec3(0, 2.8, 0),
              balcony.handZone + vec3(-2.8, 1.05, 0),
              balcony.handZone + vec3(2.8, 1.05, 0)]:
            if not balcony.toWorld(point).onScreen(viewProjection):
              framed = false
          for corner in balcony.handCorners:
            if not balcony.toWorld(corner).onScreen(viewProjection):
              framed = false
        check framed

    test $count & " seats keep raised scenery out of the visible card row":
      for balcony in layout.balconies:
        var clear = true
        for vertex in mesh.vertices:
          let local = balcony.toLocal(vertex.position) - balcony.boardZone
          if abs(local.x) < 3.2 and abs(local.z) < 1.025 and
              local.y > 0.025:
            clear = false
        check clear

    test $count & " seats have upward facing stone floors":
      var
        floorTriangles = 0
        upward = true
      for offset in countup(0, mesh.vertices.high - 2, 3):
        let
          a = mesh.vertices[offset]
          b = mesh.vertices[offset + 1]
          c = mesh.vertices[offset + 2]
        if a.material == 0 and abs(a.position.y - 0.006) < 0.00001 and
            abs(b.position.y - 0.006) < 0.00001 and
            abs(c.position.y - 0.006) < 0.00001:
          inc floorTriangles
          if a.normal.y < 0.999: upward = false
      check floorTriangles > count * 30
      check upward

    test $count & " seats rebuild deterministically without changing the RNG":
      randomize(42)
      let expected = rand(1_000_000)
      randomize(42)
      let rebuilt = buildMultiplayerCourtyardMesh(count)
      check rand(1_000_000) == expected
      check rebuilt.vertices == mesh.vertices
      check rebuilt.commonCount == mesh.commonCount
      check rebuilt.backdropCount == mesh.backdropCount

  test "the fitted camera reproduces the auto-fit view as absolute values":
    for count in [3, 4, 8, 24]:
      let layout = buildMultiplayerLayout(count)
      for aspect in [0.6'f32, 1.0, 16.0 / 9.0, 3.0]:
        let
          camera = layout.fittedCamera(aspect)
          fitted = layout.cameraEye(aspect)
          forward = normalize(layout.cameraTarget - fitted)
        check length(camera.eye - fitted) < Tolerance * 10
        check length(normalize(camera.target - camera.eye) - forward) <
          Tolerance
        check camera.pitch > 0 and camera.pitch < PI.float32 / 2

  test "tuned views interpolate between the 3 and 7 seat extremes":
    let
      three = buildMultiplayerLayout(3).multiplayerView(1.6)
      seven = buildMultiplayerLayout(7).multiplayerView(1.6)
    check abs(three.camera.height - 23.67) < Tolerance
    check abs(seven.camera.distance - 28.24) < Tolerance
    var previous = three
    for count in 4 .. 7:
      let view = buildMultiplayerLayout(count).multiplayerView(1.6)
      check view.camera.height > previous.camera.height
      check view.camera.distance > previous.camera.distance
      check view.camera.pitch < previous.camera.pitch
      check view.farHandDistance > previous.farHandDistance
      check view.nearHandHeight == three.nearHandHeight
      previous = view

  test "tuned views frame every balcony in a 16:10 window":
    for count in 3 .. 7:
      let
        layout = buildMultiplayerLayout(count)
        camera = layout.multiplayerView(1.6).camera
        viewProjection = perspective(42.0'f32, 1.6'f32, 0.1'f32, 200.0'f32) *
          lookAt(camera.eye, camera.target, vec3(0, 1, 0))
      var framed = true
      for balcony in layout.balconies:
        for point in [balcony.heroZone + vec3(0, 2.8, 0), balcony.deckZone,
            balcony.discardZone, balcony.boardZone]:
          if not balcony.toWorld(point).onScreen(viewProjection):
            framed = false
      check framed

  test "views above 7 seats keep fitting the camera":
    let layout = buildMultiplayerLayout(12)
    check layout.multiplayerView(1.6).camera == layout.fittedCamera(1.6)
