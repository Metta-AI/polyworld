## Spatial shortlists use floats internally; combat still checks integer ranges.

import spacy, vmath

type TargetSpace* = object
  space: HashSpace

proc reset*(targets: var TargetSpace, cellWidth: int32) =
  ## Reuses a spatial index for the next simultaneous planning phase.
  if targets.space == nil:
    targets.space = newHashSpace(cellWidth.float)
  else:
    targets.space.clear()

proc insert*(targets: TargetSpace, index: int, x, z: int32) =
  ## Stores an actor array index at its integer world position.
  targets.space.insert Entry(
    id: uint32(index + 1),
    pos: vec2(x.float32, z.float32)
  )

iterator nearby*(targets: TargetSpace, x, z, radius: int32,
    count: int): int =
  ## Shortlists array indices, or scans all actors without a planning index.
  if targets.space == nil:
    for i in 0 ..< count:
      yield i
  else:
    # Padding protects candidates on bucket edges from float overlap rounding.
    for entry in targets.space.findInRangeApprox(
      Entry(pos: vec2(x.float32, z.float32)),
      radius.float + 1
    ):
      yield int(entry.id) - 1
