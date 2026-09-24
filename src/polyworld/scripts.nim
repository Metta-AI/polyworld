import
  std/importutils,
  bassy, bassy/texts

type ScriptScratch* = ref object
  roots: seq[Value]

proc newScriptScratch*(runtime: Runtime): ScriptScratch =
  ## Allocates string-compaction roots once when binding a runtime.
  privateAccess(Runtime)
  privateAccess(Program)
  result = ScriptScratch()
  if runtime.program.usesStrings:
    result.roots.setLen(
      runtime.globals.len + runtime.memory.len + runtime.hostData.len
    )

proc restartScript*(runtime: var Runtime, scratch: ScriptScratch) =
  ## Reclaims temporary strings while preserving persistent script state.
  privateAccess(Runtime)
  privateAccess(Program)
  if runtime.program.usesStrings:
    # The pinned Bassy version only compacts strings on a full reset.
    # Preserve all live roots with that compactor at decision boundaries.
    let
      globals = runtime.globals.len
      cells = runtime.memory.len
    assert scratch.roots.len == globals + cells + runtime.hostData.len
    for i, value in runtime.globals:
      scratch.roots[i] = value
    for i, value in runtime.memory:
      scratch.roots[globals + i] = value
    for i, value in runtime.hostData:
      scratch.roots[globals + cells + i] = value
    runtime.strings.reset(scratch.roots)
    for i in 0 ..< globals:
      runtime.globals[i] = scratch.roots[i]
    for i in 0 ..< cells:
      runtime.memory[i] = scratch.roots[globals + i]
    for i in 0 ..< runtime.hostData.len:
      runtime.hostData[i] = scratch.roots[globals + cells + i]
    for handle in runtime.stringLiterals.mitems:
      handle = -1
  runtime.restart()

template withScriptText*(
  runtime: Runtime, value: Value, text, body: untyped
) =
  ## Borrows validated BASIC bytes for the duration of a host callback.
  block:
    privateAccess(Runtime)
    privateAccess(TextStorage)
    let
      owner = runtime
      input = value
      length = owner.strings.length(input)
    privateAccess(typeof(owner.strings.spans[0]))
    let start = int(owner.strings.spans[int(input.stringHandle)].start)
    template text: untyped =
      owner.strings.arena.toOpenArray(start, start + length - 1)
    body

proc putScriptText*(runtime: var Runtime, text: openArray[char]): Value =
  ## Copies bytes directly into BASIC's preallocated string arena.
  privateAccess(Runtime)
  privateAccess(TextStorage)
  privateAccess(typeof(runtime.strings.spans[0]))
  if text.len == 0:
    return runtime.strings.empty
  if runtime.strings.owner == 0:
    raise newException(BasicError, "BASIC program has no string storage")
  if text.len > runtime.strings.maxLength:
    raise newException(BasicError, "BASIC string length limit exceeded")
  if runtime.strings.spans.len >= runtime.strings.maxCount:
    raise newException(BasicError, "BASIC string count limit exceeded")
  if text.len > runtime.strings.maxBytes - runtime.strings.arena.len:
    raise newException(BasicError, "BASIC string byte limit exceeded")
  let handle = runtime.strings.spans.len
  runtime.strings.spans.setLen(handle + 1)
  runtime.strings.spans[handle].start = int32(runtime.strings.arena.len)
  runtime.strings.spans[handle].length = int32(text.len)
  for character in text:
    runtime.strings.arena.add character
  stringValue(runtime.strings.owner, int32(handle))
