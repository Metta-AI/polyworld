## Deterministic integer line of sight over a flat tile grid.
##
## Tile steps along each ray are a precomputed kernel. Height along the
## ray still uses the same integer lerp so visibility matches the live
## formula.

import
  std/[bitops, tables],
  profiles

const
  MaxVisionRadius* = 16
    ## Largest sight radius the kernel stores. Forts use 14.
  VisionKernelSide = MaxVisionRadius * 2 + 1
  VisionKernelCells = VisionKernelSide * VisionKernelSide

type
  VisionSource* = object
    ## Describes one observer and its circular sight range in tiles.
    x*, z*: int32
    radius*: int32
    eyeHeight*: int16
    units*, range*, offsetX*, offsetZ*: int32
      ## Optional exact circle in sub-tile units, relative to the source center.
  VisionRayStep = object
    ox, oz: int8
  VisionOffset* = object
    ## One tile in a precomputed sight circle, relative to the observer.
    dx*, dz*: int8
  VisionProfile* = object
    ## Describes a common sight shape stored in a bounded per-tile cache.
    radius*: int32
    eyeHeight*: int16
    rows: seq[uint64]
    versions, seen: seq[uint32]
  VisionCells = object
    cells: seq[int32]
    seen: uint32
  VisionCache* = object
    width, height: int32
    terrain, blockers: seq[int16]
    profiles: seq[VisionProfile]
    sources: Table[VisionSource, VisionCells]
    counts: seq[uint16]
    previous, next: seq[VisionSource]
    version, serial: uint32
    changedCells*: seq[int32]
      ## Tiles whose current visibility changed in the latest update.

var
  visionRayOffsets: seq[VisionRayStep]
  visionRayStart: array[VisionKernelCells, int32]
  visionRayCount: array[VisionKernelCells, int16]
  visionRaySteps: array[VisionKernelCells, int16]
  visionCircle: array[MaxVisionRadius + 1, seq[VisionOffset]]
  visionKernelReady = false

proc roundedDivision(numerator, denominator: int64): int64 =
  ## Divides signed integers with deterministic half-away-from-zero rounding.
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2) div denominator)

proc visionKernelIndex(dx, dz: int): int =
  ## Packs a signed offset into the square kernel table.
  (dz + MaxVisionRadius) * VisionKernelSide + (dx + MaxVisionRadius)

proc initVisionKernel*() =
  ## Builds ray steps and per-radius circles once.
  if visionKernelReady:
    return
  visionRayOffsets.setLen(0)
  for dz in -MaxVisionRadius .. MaxVisionRadius:
    for dx in -MaxVisionRadius .. MaxVisionRadius:
      let
        i = visionKernelIndex(dx, dz)
        steps = max(abs(dx), abs(dz))
      visionRayStart[i] = int32(visionRayOffsets.len)
      visionRaySteps[i] = int16(steps)
      if steps <= 1:
        visionRayCount[i] = 0
        continue
      for step in 1 ..< steps:
        visionRayOffsets.add VisionRayStep(
          ox: int8(roundedDivision(
            int64(dx) * int64(step),
            int64(steps)
          )),
          oz: int8(roundedDivision(
            int64(dz) * int64(step),
            int64(steps)
          ))
        )
      visionRayCount[i] = int16(steps - 1)
  for radius in 0 .. MaxVisionRadius:
    visionCircle[radius].setLen(0)
    let limit = radius * radius
    for dz in -radius .. radius:
      for dx in -radius .. radius:
        if dx * dx + dz * dz <= limit:
          visionCircle[radius].add VisionOffset(
            dx: int8(dx),
            dz: int8(dz)
          )
  visionKernelReady = true

iterator visionCircleTiles*(radius: int32): VisionOffset =
  ## Yields every in-range offset for one sight radius.
  initVisionKernel()
  if radius >= 0 and radius <= MaxVisionRadius:
    for offset in visionCircle[radius]:
      yield offset

proc sameVisionKeys*(a, b: openArray[int32]): bool =
  ## Returns whether two skip signatures are identical.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc copyVisionKeys*(dest: var seq[int32], src: openArray[int32]) =
  ## Copies one skip signature into a reused buffer.
  dest.setLen(src.len)
  for i, value in src:
    dest[i] = value

proc inVisionRange(source: VisionSource, x, z: int32): bool =
  ## Includes cells intersecting an exact circle when sub-tile units are supplied.
  if source.units <= 0:
    return true
  let
    dx = max(0'i64, abs(int64(x - source.x) * source.units -
      source.offsetX) - source.units div 2)
    dz = max(0'i64, abs(int64(z - source.z) * source.units -
      source.offsetZ) - source.units div 2)
  dx * dx + dz * dz <= int64(source.range) * source.range

proc rayBlocked(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ: int32,
    sourceY,
    targetY: int64,
    rayIndex: int
): bool =
  ## Returns whether a kernel ray hits an occluder before the target.
  let
    start = visionRayStart[rayIndex]
    count = int(visionRayCount[rayIndex])
    steps = int64(visionRaySteps[rayIndex])
    deltaY = targetY - sourceY
    halfSteps = steps div 2
  for i in 0 ..< count:
    let
      cell = visionRayOffsets[start + i]
      x = sourceX + int32(cell.ox)
      z = sourceZ + int32(cell.oz)
      index = z * width + x
      obstacleHeight = int64(terrainHeights[index]) +
        int64(blockerHeights[index])
      relativeHeight = obstacleHeight - sourceY
      numerator = deltaY * int64(i + 1)
    # Compare against the rounded ray height without division per ray cell.
    # Negative heights round away from zero, so their boundary is inclusive.
    if deltaY >= 0:
      if relativeHeight >= 0 and
          numerator + halfSteps < (relativeHeight + 1) * steps:
        return true
    elif relativeHeight >= 0 or
        -numerator + halfSteps >= -relativeHeight * steps:
      return true
  false

proc offsetVisible*(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ: int32,
    sourceY: int64,
    offset: VisionOffset
): bool =
  ## Tests one kernel circle offset from a known observer height.
  let
    rayIndex = visionKernelIndex(int(offset.dx), int(offset.dz))
    steps = int(visionRaySteps[rayIndex])
  if steps <= 1:
    return true
  let
    x = sourceX + int32(offset.dx)
    z = sourceZ + int32(offset.dz)
    index = z * width + x
    targetY = int64(terrainHeights[index]) + 3
  not rayBlocked(
    width,
    terrainHeights,
    blockerHeights,
    sourceX,
    sourceZ,
    sourceY,
    targetY,
    rayIndex
  )

proc liveRayBlocked(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ,
    deltaX,
    deltaZ: int32,
    sourceY,
    targetY: int64
): bool =
  ## Walks one ray with the live rounding formula. Used past the kernel.
  let steps = max(abs(deltaX), abs(deltaZ))
  if steps <= 1:
    return false
  for step in 1'i32 ..< steps:
    let
      x = sourceX + int32(roundedDivision(
        int64(deltaX) * int64(step),
        int64(steps)
      ))
      z = sourceZ + int32(roundedDivision(
        int64(deltaZ) * int64(step),
        int64(steps)
      ))
      index = z * width + x
      rayHeight = sourceY + roundedDivision(
        (targetY - sourceY) * int64(step),
        int64(steps)
      )
      obstacleHeight = int64(terrainHeights[index]) +
        int64(blockerHeights[index])
    if obstacleHeight >= rayHeight:
      return true
  false

proc lineVisible*(
    width,
    height: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ,
    targetX,
    targetZ,
    radius: int32,
    eyeHeight = 14'i16,
    targetHeight = 3'i16
): bool =
  ## Tests range and occlusion using the ray kernel when the offset fits.
  if sourceX < 0 or sourceX >= width or sourceZ < 0 or sourceZ >= height or
      targetX < 0 or targetX >= width or targetZ < 0 or targetZ >= height:
    return false
  let
    deltaX = targetX - sourceX
    deltaZ = targetZ - sourceZ
  if deltaX * deltaX + deltaZ * deltaZ > radius * radius:
    return false
  let steps = max(abs(deltaX), abs(deltaZ))
  if steps <= 1:
    return true
  let
    sourceIndex = sourceZ * width + sourceX
    targetIndex = targetZ * width + targetX
    sourceY = int64(terrainHeights[sourceIndex]) + int64(eyeHeight)
    targetY = int64(terrainHeights[targetIndex]) + int64(targetHeight)
  if abs(deltaX) <= MaxVisionRadius and abs(deltaZ) <= MaxVisionRadius:
    initVisionKernel()
    return not rayBlocked(
      width,
      terrainHeights,
      blockerHeights,
      sourceX,
      sourceZ,
      sourceY,
      targetY,
      visionKernelIndex(int(deltaX), int(deltaZ))
    )
  not liveRayBlocked(
    width,
    terrainHeights,
    blockerHeights,
    sourceX,
    sourceZ,
    deltaX,
    deltaZ,
    sourceY,
    targetY
  )

proc revealVision*(
    visible: var seq[uint8],
    width,
    height: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sources: openArray[VisionSource]
) =
  ## Rebuilds a byte-per-tile visibility map from a set of observers.
  initVisionKernel()
  let cellCount = int(width * height)
  if visible.len != cellCount:
    visible = newSeq[uint8](cellCount)
  else:
    for value in visible.mitems:
      value = 0
  for source in sources:
    if source.radius <= 0:
      continue
    if source.radius > MaxVisionRadius:
      let
        minimumX = max(source.x - source.radius, 0)
        maximumX = min(source.x + source.radius, width - 1)
        minimumZ = max(source.z - source.radius, 0)
        maximumZ = min(source.z + source.radius, height - 1)
      for z in minimumZ .. maximumZ:
        for x in minimumX .. maximumX:
          let index = z * width + x
          if visible[index] != 0 or not source.inVisionRange(x, z):
            continue
          if lineVisible(
            width,
            height,
            terrainHeights,
            blockerHeights,
            source.x,
            source.z,
            x,
            z,
            source.radius,
            source.eyeHeight
          ):
            visible[index] = 255
      continue
    let
      sourceIndex = source.z * width + source.x
      sourceY = int64(terrainHeights[sourceIndex]) + int64(source.eyeHeight)
    for offset in visionCircle[source.radius]:
      let
        x = source.x + int32(offset.dx)
        z = source.z + int32(offset.dz)
      if x < 0 or x >= width or z < 0 or z >= height:
        continue
      if not source.inVisionRange(x, z):
        continue
      let index = z * width + x
      if visible[index] != 0:
        continue
      let
        rayIndex = visionKernelIndex(int(offset.dx), int(offset.dz))
        steps = int(visionRaySteps[rayIndex])
      if steps <= 1:
        visible[index] = 255
        continue
      let targetY = int64(terrainHeights[index]) + 3
      if not rayBlocked(
        width,
        terrainHeights,
        blockerHeights,
        source.x,
        source.z,
        sourceY,
        targetY,
        rayIndex
      ):
        visible[index] = 255

proc sameHeights(a, b: seq[int16]): bool =
  ## Compares two height grids with one memory comparison.
  a.len == b.len and (a.len == 0 or
    equalMem(a[0].unsafeAddr, b[0].unsafeAddr, a.len * sizeof(int16)))

proc initVisionCache*(profiles: openArray[VisionProfile]): VisionCache =
  ## Configures dense ray-mask storage for common observer shapes.
  for profile in profiles:
    doAssert profile.radius > 0 and profile.radius <= MaxVisionRadius
  result.profiles = @profiles

proc profileIndex(cache: VisionCache, source: VisionSource): int =
  ## Finds a dense profile for a source without fractional range limits.
  if source.units <= 0:
    for i in 0 ..< cache.profiles.len:
      let profile {.cursor.} = cache.profiles[i]
      if profile.radius == source.radius and
        profile.eyeHeight == source.eyeHeight:
          return i
  -1

proc resetVisionCache(
    cache: var VisionCache,
    width, height: int32,
    terrainHeights, blockerHeights: seq[int16]
): bool =
  ## Invalidates masks and coverage when terrain or blockers change.
  inc cache.serial
  result = cache.width != width or cache.height != height or
    not sameHeights(cache.terrain, terrainHeights) or
    not sameHeights(cache.blockers, blockerHeights)
  if result:
    inc cache.version
    cache.sources.clear()
    cache.previous.setLen(0)
    cache.next.setLen(0)
    if cache.width != width or cache.height != height:
      cache.counts = newSeq[uint16](width * height)
      for profile in cache.profiles.mitems:
        profile.rows = newSeq[uint64](
          width * height * (profile.radius * 2 + 1)
        )
        profile.versions = newSeq[uint32](width * height)
        profile.seen = newSeq[uint32](width * height)
    else:
      for count in cache.counts.mitems:
        count = 0
    cache.width = width
    cache.height = height
    cache.terrain = terrainHeights
    cache.blockers = blockerHeights

proc fillVisionRows(
    cache: var VisionCache,
    profile: int,
    source: VisionSource
) {.measure.} =
  ## Computes one local bitmask with the unchanged integer ray kernel.
  let
    side = source.radius * 2 + 1
    index = source.z * cache.width + source.x
    base = index * side
    sourceY = int64(cache.terrain[index]) + int64(source.eyeHeight)
  for row in 0 ..< side:
    cache.profiles[profile].rows[base + row] = 0
  for offset in visionCircleTiles(source.radius):
    let
      x = source.x + int32(offset.dx)
      z = source.z + int32(offset.dz)
    if x < 0 or x >= cache.width or z < 0 or z >= cache.height:
      continue
    if offsetVisible(
      cache.width,
      cache.terrain,
      cache.blockers,
      source.x,
      source.z,
      sourceY,
      offset
    ):
      let row = base + int32(offset.dz) + source.radius
      cache.profiles[profile].rows[row] =
        cache.profiles[profile].rows[row] or
          (1'u64 shl (int32(offset.dx) + source.radius))
  cache.profiles[profile].versions[index] = cache.version

proc fillVisionCells(
    cache: VisionCache,
    source: VisionSource
): seq[int32] {.measure.} =
  ## Computes masks for structures and less common sight shapes.
  if source.radius <= MaxVisionRadius:
    let sourceY = int64(cache.terrain[source.z * cache.width + source.x]) +
      int64(source.eyeHeight)
    for offset in visionCircleTiles(source.radius):
      let
        x = source.x + int32(offset.dx)
        z = source.z + int32(offset.dz)
      if x < 0 or x >= cache.width or z < 0 or z >= cache.height:
        continue
      if source.inVisionRange(x, z) and offsetVisible(
        cache.width,
        cache.terrain,
        cache.blockers,
        source.x,
        source.z,
        sourceY,
        offset
      ):
        result.add z * cache.width + x
  else:
    for z in max(0'i32, source.z - source.radius) ..
      min(cache.height - 1, source.z + source.radius):
        for x in max(0'i32, source.x - source.radius) ..
          min(cache.width - 1, source.x + source.radius):
            if source.inVisionRange(x, z) and lineVisible(
              cache.width,
              cache.height,
              cache.terrain,
              cache.blockers,
              source.x,
              source.z,
              x,
              z,
              source.radius,
              source.eyeHeight
            ):
              result.add z * cache.width + x

proc cacheVisionSource(
    cache: var VisionCache,
    source: VisionSource,
    wasActive: var bool
): bool =
  ## Caches a unique observer and reports its previous participation.
  let profile = cache.profileIndex(source)
  if profile >= 0:
    let index = source.z * cache.width + source.x
    if cache.profiles[profile].seen[index] == cache.serial:
      return false
    wasActive = cache.profiles[profile].seen[index] == cache.serial - 1
    cache.profiles[profile].seen[index] = cache.serial
    if cache.profiles[profile].versions[index] != cache.version:
      cache.fillVisionRows(profile, source)
  elif cache.sources.hasKey(source):
    if cache.sources[source].seen == cache.serial:
      return false
    wasActive = cache.sources[source].seen == cache.serial - 1
    cache.sources[source].seen = cache.serial
  else:
    cache.sources[source] = VisionCells(
      cells: cache.fillVisionCells(source),
      seen: cache.serial
    )
  true

proc sourceActive(cache: var VisionCache, source: VisionSource): bool =
  ## Checks whether an old observer still contributes to visibility.
  let profile = cache.profileIndex(source)
  if profile >= 0:
    cache.profiles[profile].seen[source.z * cache.width + source.x] ==
      cache.serial
  else:
    cache.sources[source].seen == cache.serial

proc changeVisibility(
    cache: var VisionCache,
    visible: var seq[uint8],
    index: int32,
    added: bool
) =
  ## Changes one coverage count without losing overlapping observers.
  if added:
    doAssert cache.counts[index] < uint16.high
    inc cache.counts[index]
    if cache.counts[index] == 1:
      visible[index] = 255
      cache.changedCells.add index
  else:
    doAssert cache.counts[index] > 0
    dec cache.counts[index]
    if cache.counts[index] == 0:
      visible[index] = 0
      cache.changedCells.add index

proc applyVisionSource(
    cache: var VisionCache,
    visible: var seq[uint8],
    source: VisionSource,
    added: bool
) {.measure.} =
  ## Adds or removes the cached footprint of one observer.
  let profile = cache.profileIndex(source)
  if profile >= 0:
    let
      side = source.radius * 2 + 1
      base = (source.z * cache.width + source.x) * side
    for row in 0 ..< side:
      let z = source.z - source.radius + row
      var bits = cache.profiles[profile].rows[base + row]
      while bits != 0:
        let
          x = source.x - source.radius + int32(countTrailingZeroBits(bits))
          index = z * cache.width + x
        cache.changeVisibility(visible, index, added)
        bits = bits and (bits - 1)
  else:
    for index in cache.sources[source].cells:
      cache.changeVisibility(visible, index, added)

proc revealVisionCached*(
    cache: var VisionCache,
    visible: var seq[uint8],
    width, height: int32,
    terrainHeights, blockerHeights: seq[int16],
    sources: openArray[VisionSource]
) {.measure.} =
  ## Updates only changed observer footprints using uint16 coverage counts.
  initVisionKernel()
  let invalid = cache.resetVisionCache(
    width,
    height,
    terrainHeights,
    blockerHeights
  )
  visible.setLen(int(width * height))
  cache.changedCells.setLen(0)
  if invalid:
    for i in 0 ..< visible.len:
      if visible[i] != 0:
        cache.changedCells.add int32(i)
        visible[i] = 0
  cache.next.setLen(0)
  for source in sources:
    if source.radius <= 0 or source.x < 0 or source.x >= width or
      source.z < 0 or source.z >= height:
        continue
    var wasActive = false
    if not cache.cacheVisionSource(source, wasActive):
      continue
    cache.next.add source
    if invalid or not wasActive:
      cache.applyVisionSource(visible, source, true)
  for source in cache.previous:
    if not cache.sourceActive(source):
      cache.applyVisionSource(visible, source, false)
      if cache.profileIndex(source) < 0:
        cache.sources.del(source)
  swap(cache.previous, cache.next)

proc blurVisibility*(visible: openArray[uint8], width, height: int32): seq[uint8] =
  ## Softens only presentation edges with one deterministic box-blur pass.
  result = newSeq[uint8](visible.len)
  for z in 0 ..< height:
    for x in 0 ..< width:
      var
        total = 0'i32
        count = 0'i32
      for offsetZ in -1'i32 .. 1:
        for offsetX in -1'i32 .. 1:
          let
            sampleX = x + offsetX
            sampleZ = z + offsetZ
          if sampleX < 0 or sampleX >= width or
              sampleZ < 0 or sampleZ >= height:
            continue
          total += int32(visible[sampleZ * width + sampleX])
          inc count
      result[z * width + x] = uint8(total div max(count, 1))
