## Curved formation geometry and input state, independent of graphics.
import std/[math, algorithm, sets]
import fixxy
import content, controls, maps, sim

type LineDestination* = object
  unitId*: int32
  tile*: Tile2
  offset*: FixedVec2

type LinePoint* = object
  ## Absolute tile-space body coordinates; tile (x,y) is centred at x+.5,y+.5.
  x*, y*: float64

proc linePoint*(x, y: SomeNumber): LinePoint =
  LinePoint(x: x.float64, y: y.float64)

proc distanceSquared(a, b: LinePoint): float64 =
  (a.x-b.x)*(a.x-b.x) + (a.y-b.y)*(a.y-b.y)

proc sampleLine*(stroke: openArray[LinePoint], count: int): seq[LinePoint] =
  ## Uniform arc-length samples, including endpoints (one unit uses midpoint).
  if count <= 0 or stroke.len == 0: return
  var lengths = newSeq[float64](stroke.len)
  for i in 1 ..< stroke.len:
    lengths[i] = lengths[i-1] + sqrt(distanceSquared(stroke[i-1], stroke[i]))
  var segment = 1
  for i in 0 ..< count:
    let at = lengths[^1] * (if count == 1: 0.5 else: i.float64/(count-1).float64)
    while segment < stroke.len-1 and lengths[segment] < at: inc segment
    if stroke.len == 1 or lengths[^1] <= 1e-9:
      result.add stroke[0]
    else:
      let span = lengths[segment] - lengths[segment-1]
      let t = if span <= 1e-9: 0.0 else: (at-lengths[segment-1])/span
      result.add linePoint(stroke[segment-1].x + t*(stroke[segment].x-stroke[segment-1].x),
        stroke[segment-1].y + t*(stroke[segment].y-stroke[segment-1].y))

proc destinationPoint*(target: LineDestination): LinePoint =
  linePoint(target.tile.x.float64 + 0.5 + int32(target.offset.x).float64/65536,
    target.tile.y.float64 + 0.5 + int32(target.offset.y).float64/65536)

proc eligibleLineUnits*(world: World, player: int32,
    selected: openArray[int32]): seq[int32] =
  if world == nil or player < 0 or player >= world.players.len: return
  for id in selected:
    let index = world.unitIndex(id)
    if index < 0: continue
    let unit = world.units[index]
    if unit.owner == player and unit.hp > 0 and
        unit.state notin {UnitDying, UnitInMine} and id notin result:
      result.add id
  result.sort()

proc unitPoint(world: World, id: int32): LinePoint =
  let pos = world.units[world.unitIndex(id)].body.pos
  linePoint(int32(pos.x).float64/65536, int32(pos.y).float64/65536)

type LinePlanWork* = object
  ## Deterministic operation counts for performance regression tests.
  slotCells*, connectivityCells*, validationCells*, assignmentPairs*: int
  connectivityBuilds*: int

var lastLinePlanWork*: LinePlanWork

type LineConnectivity = object
  ## Gesture-owned: never retains another match or leaks across gestures.
  world: World
  side: int
  open: seq[bool]
  blocked: HashSet[int]
  labels, queue: seq[int]

proc refresh(cache: var LineConnectivity, world: World, ids: seq[int32]): bool =
  ## World has no blocker revision. Compare an exact openness snapshot (not a
  ## hash or tick heuristic) so construction, chopped trees, replay edits and
  ## moving nonselected units invalidate connectivity even within the same tick.
  let side = world.map.side.int
  var blocked = initHashSet[int]()
  let selected = ids.toHashSet()
  for unit in world.units:
    if unit.state notin {UnitDying, UnitInMine} and unit.hp > 0 and
        unit.id notin selected and world.map.inGrid(unit.tile):
      blocked.incl world.map.tileIndex(unit.tile).int
  result = cache.world != world or cache.side != side or cache.blocked != blocked
  if cache.open.len != side*side:
    cache.open = newSeq[bool](side*side)
    result = true
  for cell in 0 ..< cache.open.len:
    inc lastLinePlanWork.validationCells
    let isOpen = world.map.passable[cell] == 1 and world.blocker[cell] == 0
    if cache.open[cell] != isOpen:
      cache.open[cell] = isOpen
      result = true
  if not result: return
  cache.world = world
  cache.side = side
  cache.blocked = move(blocked)
  cache.labels.setLen(side*side)
  inc lastLinePlanWork.connectivityBuilds
  for cell in 0 ..< cache.labels.len:
    inc lastLinePlanWork.connectivityCells
    cache.labels[cell] = if cache.open[cell] and cell notin cache.blocked: 0 else: -1
  var component = 0
  for index in 0 ..< cache.labels.len:
    inc lastLinePlanWork.connectivityCells
    if cache.labels[index] != 0: continue
    inc component
    cache.queue.setLen(0)
    cache.queue.add index
    cache.labels[index] = component
    var cursor = 0
    while cursor < cache.queue.len:
      let cell = cache.queue[cursor]
      inc lastLinePlanWork.connectivityCells
      inc cursor
      let x = cell mod side
      let y = cell div side
      for delta in [(-1,0), (1,0), (0,-1), (0,1)]:
        let nx = x + delta[0]
        let ny = y + delta[1]
        if nx >= 0 and ny >= 0 and nx < side and ny < side:
          let next = ny*side+nx
          if cache.labels[next] == 0:
            cache.labels[next] = component
            cache.queue.add next

proc nearestSlot(cache: LineConnectivity, component: int, sample: LinePoint,
    reserved: HashSet[int]): int =
  ## Expand square rings, examining each in-map cell at most once. Once a slot
  ## is found, finish only rings that could improve its Euclidean distance;
  ## equal distances keep the original row-major tie break.
  let side = cache.side
  let cx = floor(clamp(sample.x, 0.0, (side-1).float64)).int
  let cy = floor(clamp(sample.y, 0.0, (side-1).float64)).int
  result = -1
  var bestDistance = Inf
  template examine(x, y: int) =
    let cell = y*side+x
    inc lastLinePlanWork.slotCells
    if cache.labels[cell] == component and cell notin reserved:
      let cost = distanceSquared(linePoint(x.float64+0.5, y.float64+0.5), sample)
      if cost < bestDistance or (cost == bestDistance and cell < result):
        result = cell
        bestDistance = cost
  for radius in 0 .. max(max(cx, side-1-cx), max(cy, side-1-cy)):
    let left = cx-radius
    let right = cx+radius
    let top = cy-radius
    let bottom = cy+radius
    for x in max(0,left) .. min(side-1,right):
      if top >= 0: examine(x, top)
      if bottom < side and bottom != top: examine(x, bottom)
    for y in max(0,top+1) .. min(side-1,bottom-1):
      if left >= 0: examine(left, y)
      if right < side and right != left: examine(right, y)
    # Lower bound for every unvisited cell: it lies beyond one of these edges.
    var outsideDistance = Inf
    if left > 0: outsideDistance = min(outsideDistance, sample.x-(left.float64-0.5))
    if right < side-1: outsideDistance = min(outsideDistance, right.float64+1.5-sample.x)
    if top > 0: outsideDistance = min(outsideDistance, sample.y-(top.float64-0.5))
    if bottom < side-1: outsideDistance = min(outsideDistance, bottom.float64+1.5-sample.y)
    if result >= 0 and bestDistance < outsideDistance*outsideDistance: break

proc planLineMove(world: World, player: int32, selected: openArray[int32],
    stroke: openArray[LinePoint], cache: var LineConnectivity,
    refreshed = false): seq[LineDestination] =
  ## Choose one legal reachable cell per unit; short strokes spread into nearby
  ## free cells instead of collapsing onto one point. No simulation mutation.
  if not refreshed: lastLinePlanWork = LinePlanWork()
  let ids = world.eligibleLineUnits(player, selected)
  let samples = sampleLine(stroke, ids.len)
  if samples.len == 0: return
  let side = world.map.side.int
  if not refreshed: discard cache.refresh(world, ids)
  # Deterministic pair-exchange assignment minimizes total travel length;
  # crossing straight segments can be uncrossed by a cheaper swap.
  var assignment = newSeq[int](ids.len)
  for i in 0 ..< ids.len: assignment[i] = i
  for pass in 0 ..< ids.len:
    var changed = false
    for i in 0 ..< ids.len:
      for j in i+1 ..< ids.len:
        inc lastLinePlanWork.assignmentPairs
        let a = world.unitPoint(ids[i])
        let b = world.unitPoint(ids[j])
        let oldCost = sqrt(distanceSquared(a, samples[assignment[i]])) +
          sqrt(distanceSquared(b, samples[assignment[j]]))
        let newCost = sqrt(distanceSquared(a, samples[assignment[j]])) +
          sqrt(distanceSquared(b, samples[assignment[i]]))
        if newCost + 1e-8 < oldCost:
          swap(assignment[i], assignment[j])
          changed = true
    if not changed: break
  var reserved = initHashSet[int]()
  for i, id in ids:
    let unit = world.units[world.unitIndex(id)]
    let origin = world.map.tileIndex(unit.tile.x.int32, unit.tile.y.int32).int
    if cache.labels[origin] <= 0: continue
    let sample = samples[assignment[i]]
    let best = cache.nearestSlot(cache.labels[origin], sample, reserved)
    if best < 0: continue
    reserved.incl best
    let x = best mod side
    let y = best div side
    # Controls uses integer destination tiles. Preview those exact cell centres,
    # not a fractional position that would be discarded on command submission.
    result.add LineDestination(unitId: id, tile: tile2(x.int32, y.int32),
      offset: FixedVec2Zero)

proc planLineMove*(world: World, player: int32, selected: openArray[int32],
    stroke: openArray[LinePoint]): seq[LineDestination] =
  var cache: LineConnectivity
  world.planLineMove(player, selected, stroke, cache)

type
  LineRelease* = enum
    LineCancelled, LineClick, LineCommitted
  LineGesture* = object
    active*, dragging*, attackMove*: bool
    player*: int32
    selection*: seq[int32]
    stroke*: seq[LinePoint]
    targets*: seq[LineDestination]
    press*: LinePoint
    world: World
    connectivity: LineConnectivity

const LineDragPixels* = 6.0

proc cancelLine*(gesture: var LineGesture) =
  gesture = LineGesture()

proc selectionKey(selected: openArray[int32]): seq[int32] =
  result = @selected
  result.sort()

proc beginLine*(gesture: var LineGesture, world: World, player: int32,
    selected: openArray[int32], ground, screen: LinePoint, attackMove = false) =
  gesture = LineGesture(active: world != nil, world: world, player: player,
    selection: selectionKey(selected), stroke: @[ground], press: screen,
    attackMove: attackMove)

proc validGesture(gesture: LineGesture, world: World, selected: openArray[int32]): bool =
  gesture.active and gesture.world == world and gesture.selection == selectionKey(selected)

proc updateLine*(gesture: var LineGesture, world: World, selected: openArray[int32],
    ground, screen: LinePoint) =
  if not gesture.validGesture(world, selected):
    gesture.cancelLine()
    return
  if distanceSquared(gesture.press, screen) >= LineDragPixels*LineDragPixels:
    gesture.dragging = true
  let moved = distanceSquared(gesture.stroke[^1], ground) > 1e-8
  if moved:
    gesture.stroke.add ground
    # Bound pointer-history work without converting a curve into its chord.
    if gesture.stroke.len > 2048:
      var reduced: seq[LinePoint]
      for i in countup(0, gesture.stroke.high, 2): reduced.add gesture.stroke[i]
      reduced.add gesture.stroke[^1]
      gesture.stroke = reduced
  if gesture.dragging and (moved or gesture.targets.len == 0):
    gesture.targets = world.planLineMove(gesture.player, selected, gesture.stroke,
      gesture.connectivity)
  elif gesture.dragging:
    lastLinePlanWork = LinePlanWork()
    let ids = world.eligibleLineUnits(gesture.player, selected)
    if gesture.connectivity.refresh(world, ids):
      gesture.targets = world.planLineMove(gesture.player, selected, gesture.stroke,
        gesture.connectivity, refreshed = true)

proc targetsReachable(gesture: var LineGesture, world: World): bool =
  ## Validate, but never reassign, the displayed snapshot at release. A newly
  ## blocked route cancels instead of committing stale destinations or unseen ones.
  let ids = world.eligibleLineUnits(gesture.player, gesture.selection)
  lastLinePlanWork = LinePlanWork()
  discard gesture.connectivity.refresh(world, ids)
  for target in gesture.targets:
    if target.unitId notin ids: continue # Dispatch already skips ineligible units.
    let unit = world.units[world.unitIndex(target.unitId)]
    if not world.map.inGrid(unit.tile) or not world.map.inGrid(target.tile): return false
    let origin = world.map.tileIndex(unit.tile).int
    let destination = world.map.tileIndex(target.tile).int
    if gesture.connectivity.labels[origin] <= 0 or
        gesture.connectivity.labels[origin] != gesture.connectivity.labels[destination]:
      return false
  true

proc queueLineTargets*(world: World, player: int32,
    targets: openArray[LineDestination], attackMove = false, append = false): int =
  ## Dispatch through ordinary controls; replay/network share the same path.
  for target in targets:
    if world.eligibleLineUnits(player, [target.unitId]).len == 0: continue
    let unit = world.units[world.unitIndex(target.unitId)]
    if attackMove and unit.kind != PeonUnit:
      queueAttackMove(player, target.unitId, target.tile.x.int32,
        target.tile.y.int32, append = append)
    else:
      queueMove(player, target.unitId, target.tile.x.int32,
        target.tile.y.int32, append = append)
    inc result

proc releaseLine*(gesture: var LineGesture, world: World,
    selected: openArray[int32], inside = true, append = false): LineRelease =
  ## Never resample here: the displayed target snapshot is the committed one.
  ## Off-window release cancels; caller routes LineClick to contextual orders.
  result = LineCancelled
  if inside and gesture.validGesture(world, selected):
    if not gesture.dragging:
      result = LineClick
    elif gesture.targetsReachable(world) and
        world.queueLineTargets(gesture.player, gesture.targets,
        gesture.attackMove, append) > 0:
      result = LineCommitted
  gesture.cancelLine()
