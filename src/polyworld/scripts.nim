import
  std/importutils,
  bassy, bassy/texts

proc restartScript*(runtime: var Runtime) =
  ## Reclaims temporary strings while preserving persistent script state.
  privateAccess(Runtime)
  privateAccess(Program)
  if runtime.program.usesStrings:
    # The pinned Bassy version only compacts strings on a full reset.
    # Preserve all live roots with that compactor at decision boundaries.
    let
      globals = runtime.globals.len
      cells = runtime.memory.len
    var roots = newSeq[Value](globals + cells + runtime.hostData.len)
    for i, value in runtime.globals:
      roots[i] = value
    for i, value in runtime.memory:
      roots[globals + i] = value
    for i, value in runtime.hostData:
      roots[globals + cells + i] = value
    runtime.strings.reset(roots)
    for i in 0 ..< globals:
      runtime.globals[i] = roots[i]
    for i in 0 ..< cells:
      runtime.memory[i] = roots[globals + i]
    for i in 0 ..< runtime.hostData.len:
      runtime.hostData[i] = roots[globals + cells + i]
    for handle in runtime.stringLiterals.mitems:
      handle = -1
  runtime.restart()
