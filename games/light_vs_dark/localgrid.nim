## Deterministic bounded broad phase. Derived scratch; never replay state.
## One-tile buckets, ascending insertion order. Queries retain a bounded prefix;
## overflow has an owner summary: foreign/mixed cells conservatively block,
## friendly cells remain soft. Every body gathers pressure, including omitted IDs.
import fixxy

const LocalBucketLimit* = 16

type LocalGrid* = object
  side: int32
  heads, next: seq[int32]
  touched: seq[int32]
  counts: seq[int32]
  owners: seq[int32]
  hasOverflow*: bool
  commonOwner: int32

proc reset*(grid: var LocalGrid, side: int32, count: int) =
  if grid.side != side:
    grid.side = side
    grid.heads.setLen(side.int * side.int)
    grid.counts = newSeq[int32](side.int * side.int)
    grid.owners = newSeq[int32](side.int * side.int)
    for head in grid.heads.mitems: head = -1
  else:
    for cell in grid.touched:
      grid.heads[cell] = -1
      grid.counts[cell] = 0
  grid.hasOverflow = false
  grid.commonOwner = -1
  grid.touched.setLen(0)
  grid.next.setLen(count)
  for next in grid.next.mitems: next = -1

proc insert*(grid: var LocalGrid, index: int32, pos: FixedVec2, owner = 0'i32) =
  let x = whole(pos.x)
  let y = whole(pos.y)
  if x < 0 or y < 0 or x >= grid.side or y >= grid.side: return
  if grid.commonOwner == -1: grid.commonOwner = owner
  elif grid.commonOwner != owner: grid.commonOwner = -2
  let cell = y * grid.side + x
  if grid.heads[cell] < 0:
    grid.touched.add cell
    grid.owners[cell] = owner
  elif grid.owners[cell] != owner:
    grid.owners[cell] = -2
  inc grid.counts[cell]
  if grid.counts[cell] > LocalBucketLimit: grid.hasOverflow = true
  grid.next[index] = grid.heads[cell]
  grid.heads[cell] = index

proc crowded*(grid: LocalGrid, pos: FixedVec2, radius: Fixed): bool =
  ## Dense-cell envelope, never silently treat omitted bodies as empty space.
  if not grid.hasOverflow: return false
  let x = whole(pos.x)
  let y = whole(pos.y)
  for row in max(0'i32, y-1) .. min(grid.side-1, y+1):
    for col in max(0'i32, x-1) .. min(grid.side-1, x+1):
      if grid.counts[row*grid.side+col] <= LocalBucketLimit: continue
      if pos.x + radius >= fixed(col) and pos.x - radius <= fixed(col+1) and
          pos.y + radius >= fixed(row) and pos.y - radius <= fixed(row+1):
        return true
  false

proc crowdedForeign*(grid: LocalGrid, pos: FixedVec2, radius: Fixed,
    owner: int32): bool =
  ## Overflow is a wall only when omitted actors could be foreign bodies.
  if not grid.hasOverflow: return false
  let x = whole(pos.x)
  let y = whole(pos.y)
  for row in max(0'i32, y-1) .. min(grid.side-1, y+1):
    for col in max(0'i32, x-1) .. min(grid.side-1, x+1):
      let cell = row*grid.side+col
      if grid.counts[cell] <= LocalBucketLimit or grid.owners[cell] == owner:
        continue
      if pos.x + radius >= fixed(col) and pos.x - radius <= fixed(col+1) and
          pos.y + radius >= fixed(row) and pos.y - radius <= fixed(row+1):
        return true
  false

proc onlyOwner*(grid: LocalGrid, owner: int32): bool {.inline.} =
  grid.commonOwner == owner or grid.commonOwner == -1

iterator neighbors*(grid: LocalGrid, pos: FixedVec2): int32 =
  let x = whole(pos.x)
  let y = whole(pos.y)
  for row in max(0'i32, y-1) .. min(grid.side-1, y+1):
    for col in max(0'i32, x-1) .. min(grid.side-1, x+1):
      var index = grid.heads[row*grid.side+col]
      var visited = 0
      while index >= 0 and visited < LocalBucketLimit:
        yield index
        index = grid.next[index]
        inc visited
