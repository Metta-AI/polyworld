## Decides when a browser world needs another frame.
const BackgroundFrameMillis* = 1000'i64

type
  BackdropMode* = enum
    visible, blocking, hidden, unfocused
  WebBackdrop* = object
    initialized: bool
    previous: BackdropMode
    width, height, revision: int
    nextBackgroundFrame: int64

proc drawWorld*(backdrop: var WebBackdrop, mode: BackdropMode,
    width, height: int, invalidated: bool, revision = 0,
    nowMillis = 0'i64): bool =
  result = mode != hidden and (mode == visible or not backdrop.initialized or
    mode != backdrop.previous or width != backdrop.width or height != backdrop.height or
    invalidated or revision != backdrop.revision or
    (mode == unfocused and nowMillis >= backdrop.nextBackgroundFrame))
  backdrop.previous = mode
  if result:
    backdrop.initialized = true
    backdrop.width = width
    backdrop.height = height
    backdrop.revision = revision
    backdrop.nextBackgroundFrame = nowMillis + BackgroundFrameMillis
