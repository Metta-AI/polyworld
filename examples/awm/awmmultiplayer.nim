## Shared geometry and seat coordinates for the multiplayer scene preview.
## This module deliberately has no game state, graphics or random dependency.
import std/[math, strutils]
import vmath

type
  MultiplayerCamera* = object
    ## An absolute camera on P1's side (+Z), like the duel's: eye height,
    ## eye distance from the ring center, and radians below the horizon.
    height*, distance*, pitch*: float32
  MultiplayerView* = object
    ## Camera and hands. P1's hand is near; every other balcony's is far.
    camera*: MultiplayerCamera
    nearHandHeight*, nearHandDistance*, farHandHeight*, farHandDistance*,
      handRoll*: float32
  PlayerBalcony* = object
    playerIndex*: int
    center*: Vec3
    yaw*: float32
    ## Every zone is a balcony-local anchor. Pile and board Y values are the
    ## top of their supporting surface, before adding the thickness of a card.
    heroZone*, deckZone*, discardZone*, handZone*, boardZone*: Vec3
  MultiplayerLayout* = object
    playerCount*: int
    centerRadius*, innerRadius*, outerRadius*, balconyHalfAngle*: float32
    balconies*: seq[PlayerBalcony]

const
  MultiplayerFovY* = 42.0'f32  ## Degrees, matching vmath.perspective.
  BalconyDepth* = 6.5'f32
  BalconyLampHeight* = 1.25'f32
  MultiplayerHandHeight* = 1.25'f32
  MultiplayerHandDistance* = 1.95'f32
    ## Balcony-local Z of the hand; larger moves it out, away from the center.
  MultiplayerHandPitch* = 0.55'f32
  Tau = 2.0'f32 * PI.float32

proc rotateSeat*(point: Vec3, yaw: float32): Vec3 =
  ## Same rotation convention as AWM's cards and characters.
  vec3(point.x * cos(yaw) - point.z * sin(yaw), point.y,
    point.x * sin(yaw) + point.z * cos(yaw))

proc toWorld*(balcony: PlayerBalcony, local: Vec3): Vec3 =
  balcony.center + rotateSeat(local, balcony.yaw)

proc toLocal*(balcony: PlayerBalcony, world: Vec3): Vec3 =
  rotateSeat(world - balcony.center, -balcony.yaw)

proc buildMultiplayerLayout*(playerCount: int): MultiplayerLayout =
  if playerCount < 3:
    raise newException(ValueError, "A multiplayer battlefield needs at least 3 players")
  result.playerCount = playerCount
  result.centerRadius = 3.0
  # Leave actual sky between the separate islands. Once the angular slice
  # narrows, add radial courses instead of squeezing the hero or card zones.
  result.balconyHalfAngle = min(0.68'f32, PI.float32 / playerCount.float32 * 0.86'f32)
  let tangent = tan(result.balconyHalfAngle)
  result.innerRadius = max(5.0'f32,
    max(3.40'f32 / tangent - 0.40'f32, 4.90'f32 / tangent - 2.20'f32))
  result.outerRadius = result.innerRadius + BalconyDepth
  let centerDistance = result.innerRadius + BalconyDepth * 0.5'f32
  for playerIndex in 0 ..< playerCount:
    let yaw = Tau * playerIndex.float32 / playerCount.float32
    result.balconies.add PlayerBalcony(
      playerIndex: playerIndex,
      center: rotateSeat(vec3(0, 0, centerDistance), yaw), yaw: yaw,
      heroZone: vec3(0, 0.015, 0.45),
      deckZone: vec3(-3.75, 0.155, 0.55),
      discardZone: vec3(3.75, 0.155, 0.55),
      handZone: vec3(0, MultiplayerHandHeight, MultiplayerHandDistance),
      boardZone: vec3(0, 0.015, -1.8))

proc lampRadius*(layout: MultiplayerLayout): float32 =
  layout.outerRadius - 0.52'f32

proc lampHalfAngle*(layout: MultiplayerLayout): float32 =
  layout.balconyHalfAngle * 0.89'f32

proc lampPosition*(layout: MultiplayerLayout, playerIndex: int,
    side: float32): Vec3 =
  let angle = side * layout.lampHalfAngle
  rotateSeat(vec3(sin(angle) * layout.lampRadius, BalconyLampHeight,
    cos(angle) * layout.lampRadius), layout.balconies[playerIndex].yaw)

proc cameraTarget*(layout: MultiplayerLayout): Vec3 = vec3(0, 0, 0)

proc cameraEye*(layout: MultiplayerLayout, aspect: float32,
    verticalFov = MultiplayerFovY): Vec3 =
  ## Fit the entire scene's bounding sphere in the narrower field of view.
  ## This remains safe when a window becomes portrait, or the seat count
  ## requires a larger ring. The steep view keeps every player's zones visible.
  let
    halfVertical = clamp(verticalFov, 10.0'f32, 100.0'f32) * PI.float32 / 360
    halfHorizontal = arctan(tan(halfVertical) * max(0.001'f32, aspect))
    halfFov = min(halfVertical, halfHorizontal)
    radius = sqrt((layout.outerRadius + 0.9'f32) ^ 2 + 3.0'f32 ^ 2)
    distance = radius / sin(halfFov) * 1.08'f32
  layout.cameraTarget + normalize(vec3(0, 1.9, 1)) * distance

proc fittedCamera*(layout: MultiplayerLayout, aspect: float32,
    verticalFov = MultiplayerFovY): MultiplayerCamera =
  ## The auto-fitted view as absolute values, a starting point for tuning.
  let eye = layout.cameraEye(aspect, verticalFov)
  let toTarget = layout.cameraTarget - eye
  MultiplayerCamera(height: eye.y, distance: eye.z,
    pitch: arctan2(-toTarget.y, -toTarget.z))

proc eye*(camera: MultiplayerCamera): Vec3 =
  vec3(0, camera.height, camera.distance)

proc target*(camera: MultiplayerCamera): Vec3 =
  camera.eye + vec3(0, -sin(camera.pitch), -cos(camera.pitch))

const TunedViews: array[3 .. 7, MultiplayerView] = [
  # Hand-tuned for 3 and 7 seats in a 16:10 window; 4-6 interpolate them.
  3: MultiplayerView(camera: MultiplayerCamera(height: 23.67, distance: 18.11,
    pitch: 0.9638), # 55.2 deg down
    nearHandHeight: 1.25, nearHandDistance: 1.95,
    farHandHeight: 1.25, farHandDistance: 1.95, handRoll: 0),
  4: MultiplayerView(camera: MultiplayerCamera(height: 25.05, distance: 20.64,
    pitch: 0.9319), # 53.4 deg down
    nearHandHeight: 1.25, nearHandDistance: 1.95,
    farHandHeight: 1.35, farHandDistance: 2.13, handRoll: 0),
  5: MultiplayerView(camera: MultiplayerCamera(height: 26.44, distance: 23.18,
    pitch: 0.8999), # 51.6 deg down
    nearHandHeight: 1.25, nearHandDistance: 1.95,
    farHandHeight: 1.46, farHandDistance: 2.30, handRoll: 0),
  6: MultiplayerView(camera: MultiplayerCamera(height: 27.82, distance: 25.71,
    pitch: 0.8680), # 49.7 deg down
    nearHandHeight: 1.25, nearHandDistance: 1.95,
    farHandHeight: 1.56, farHandDistance: 2.48, handRoll: 0),
  7: MultiplayerView(camera: MultiplayerCamera(height: 29.20, distance: 28.24,
    pitch: 0.8360), # 47.9 deg down
    nearHandHeight: 1.25, nearHandDistance: 1.95,
    farHandHeight: 1.66, farHandDistance: 2.65, handRoll: 0)]

proc multiplayerView*(layout: MultiplayerLayout, aspect: float32): MultiplayerView =
  ## The tuned view for 3-7 seats. Larger rings keep the 7-seat hands and
  ## fit the camera to the window, since no tuned camera covers them.
  if layout.playerCount <= TunedViews.high:
    return TunedViews[layout.playerCount]
  result = TunedViews[TunedViews.high]
  result.camera = layout.fittedCamera(aspect)

proc tunedRow*(view: MultiplayerView, playerCount: int): string =
  ## One TunedViews row, ready to paste back into the table.
  proc f(value: float32, digits: int): string =
    formatFloat(value, ffDecimal, digits)
  $playerCount & ": MultiplayerView(camera: MultiplayerCamera(height: " &
    f(view.camera.height, 2) & ", distance: " & f(view.camera.distance, 2) &
    ",\n    pitch: " & f(view.camera.pitch, 4) & "), # " &
    f(radToDeg(view.camera.pitch), 1) & " deg down\n" &
    "    nearHandHeight: " & f(view.nearHandHeight, 2) &
    ", nearHandDistance: " & f(view.nearHandDistance, 2) & ",\n" &
    "    farHandHeight: " & f(view.farHandHeight, 2) &
    ", farHandDistance: " & f(view.farHandDistance, 2) &
    ", handRoll: " & f(view.handRoll, 4) & "),"
