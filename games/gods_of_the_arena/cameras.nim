import
  vmath,
  polyworld/[directors, rtscameras],
  sim

proc zoomPitch*(distance: float32): float32 =
  ## Lowers the close-up viewing angle smoothly from 53 to 35 degrees.
  let close = rtsEaseT((8.0'f - distance) / 3.0'f)
  mix(RtsCameraPitch, 0.6108652'f, close)

proc prioritizeHeroes*(world: World, subjects: var seq[Subject]): bool =
  ## Prefers the visible hero nearest the enemy god; reports living heroes.
  var
    closest = -1
    distance = int64.high
  for hero in world.heroes:
    if hero.hp <= 0 or hero.state == Dying:
      continue
    result = true
    let
      god = world.forts[1 - ord(hero.team)].center
      dx = hero.position.x.int64 - god.x.int64
      dz = hero.position.z.int64 - god.z.int64
      squared = dx * dx + dz * dz
    for i, subject in subjects.mpairs:
      if subject.id != hero.id:
        continue
      subject.idleScore = 12
      if subject.visible and squared < distance:
        closest = i
        distance = squared
      break
  if closest >= 0:
    subjects[closest].idleScore = 28
