import
  fixxy,
  polyworld/[bodies, rngs],
  ../examples/gods_of_the_arena/motions

proc openGround(point: FixedVec2): bool =
  ## Leaves movement unobstructed for exact arithmetic checks.
  true

proc checkDirection(toward: FixedVec2, speed: Fixed) =
  ## Verifies every heading, step, and turning tick against its half turn.
  let
    firstAngle = motions.angle(toward)
    secondAngle = motions.angle(-toward)
  doAssert shortestTurn(wrapAngle(firstAngle + FixedPi), secondAngle) ==
    FixedZero
  doAssert motions.direction(firstAngle) == -motions.direction(secondAngle)
  doAssert motions.step(toward, speed) == -motions.step(-toward, speed)
  doAssert motions.normalized(toward) == -motions.normalized(-toward)
  var
    first = Body(facing: wrapAngle(firstAngle - 1'fx))
    second = Body(facing: wrapAngle(first.facing + FixedPi))
  for tick in 0 ..< 5:
    motions.steer(first, toward, speed, 0.35'fx, openGround)
    motions.steer(second, -toward, speed, 0.35'fx, openGround)
    doAssert first.pos == -second.pos
    doAssert shortestTurn(wrapAngle(first.facing + FixedPi), second.facing) ==
      FixedZero

echo "Testing exact half-turn symmetry of headings and movement"
block:
  var rng = initRng(2026)
  for i in 0 ..< 100_000:
    let
      toward = fixedVec2(
        Fixed(rng.between(-2_000_000, 2_000_000)),
        Fixed(rng.between(-2_000_000, 2_000_000))
      )
      speed = Fixed(rng.between(1, 20_000))
    if toward != FixedVec2Zero:
      checkDirection(toward, speed)
  for x in -1'i32 .. 1'i32:
    for y in -1'i32 .. 1'i32:
      if x != 0 or y != 0:
        checkDirection(fixedVec2(fixed(x), fixed(y)), 0.1'fx)

echo "Testing exact half-turn symmetry of collision displacement"
block:
  var rng = initRng(8)
  for sample in 0 ..< 10_000:
    let
      firstPosition = fixedVec2(
        Fixed(rng.between(-100_000, 100_000)),
        Fixed(rng.between(-100_000, 100_000))
      )
      secondPosition = fixedVec2(
        Fixed(rng.between(-100_000, 100_000)),
        Fixed(rng.between(-100_000, 100_000))
      )
    for firstFixed in [false, true]:
      for secondFixed in [false, true]:
        var
          first = Body(pos: firstPosition, radius: 0.5'fx)
          second = Body(pos: secondPosition, radius: 0.5'fx)
          oppositeFirst = Body(pos: -firstPosition, radius: 0.5'fx)
          oppositeSecond = Body(pos: -secondPosition, radius: 0.5'fx)
        motions.separatePair(first, second, openGround,
          firstFixed, secondFixed)
        motions.separatePair(oppositeFirst, oppositeSecond, openGround,
          firstFixed, secondFixed)
        doAssert first.pos == -oppositeFirst.pos
        doAssert second.pos == -oppositeSecond.pos
