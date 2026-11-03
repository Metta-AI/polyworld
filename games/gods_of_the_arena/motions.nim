import
  fixxy,
  polyworld/bodies

proc reverse(vector: FixedVec2): bool =
  ## Chooses one half-plane so opposite vectors share the same rounded math.
  vector.y > FixedZero or (vector.y == FixedZero and vector.x < FixedZero)

proc angle*(vector: FixedVec2): Fixed =
  ## Measures headings with an exact integer half turn between opposites.
  if vector.reverse:
    wrapAngle(fixxy.angle(-vector) + FixedPi)
  else:
    fixxy.angle(vector)

proc direction*(angle: Fixed): FixedVec2 =
  ## Evaluates opposite headings through the same trigonometric table entry.
  let wrapped = wrapAngle(angle)
  if wrapped > FixedZero:
    -fixxy.direction(wrapped - FixedPi)
  else:
    fixxy.direction(wrapped)

proc scaled(vector: FixedVec2, distance: Fixed): FixedVec2 =
  ## Rounds a normalized displacement once and reflects its opposite exactly.
  if vector.reverse:
    -(normalize(-vector) * distance)
  else:
    normalize(vector) * distance

proc normalized*(vector: FixedVec2): FixedVec2 =
  ## Returns opposite unit vectors with exactly opposite rounded components.
  scaled(vector, FixedOne)

proc step*(toward: FixedVec2, speed: Fixed): FixedVec2 =
  ## Advances toward a destination without overshoot or directional rounding.
  let distance = length(toward)
  if distance <= FixedZero or speed <= FixedZero:
    FixedVec2Zero
  elif distance <= speed:
    toward
  else:
    scaled(toward, speed)

proc steer*(
    body: var Body,
    toward: FixedVec2,
    speed, turnRate: Fixed,
    walkable: Walkable
) =
  ## Finishes a turn before taking a step with exact half-turn symmetry.
  if toward == FixedVec2Zero:
    return
  let target = angle(toward)
  turnToward(body.facing, target, turnRate)
  if shortestTurn(body.facing, target) == FixedZero and speed > FixedZero:
    slide(body.pos, step(toward, speed), walkable)

proc separation*(
    first, second: Body,
    firstFixed = false,
    secondFixed = false
): FixedVec2 =
  ## Computes a pair's separation without changing either input position.
  if (firstFixed and secondFixed) or not needsSeparation(first, second):
    return FixedVec2Zero
  let
    offset = second.pos - first.pos
    distance = length(offset)
    overlap = first.radius + second.radius - distance
  scaled(offset, if firstFixed or secondFixed: overlap else: overlap / 2)

proc separatePair*(
    first, second: var Body,
    walkable: Walkable,
    firstFixed = false,
    secondFixed = false
) =
  ## Separates overlapping bodies with mirrored, equally rounded displacements.
  let
    push = separation(first, second, firstFixed, secondFixed)
    oldFirst = first.pos
    oldSecond = second.pos
  if push == FixedVec2Zero:
    return
  if not firstFixed:
    first.pos -= push
  if not secondFixed:
    second.pos += push
  clampWalkable(first.pos, oldFirst, walkable)
  clampWalkable(second.pos, oldSecond, walkable)
