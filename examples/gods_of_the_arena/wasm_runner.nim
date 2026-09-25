import jsony, game, sim, scores, replays
import polyworld/[coworld_wasm, metrics]

type Inputs = object
  config: string
  policies: seq[string]

var
  initialized, finalized: bool
  outputs: array[4, string]

proc pw_alloc(length: cint): pointer {.exportc, cdecl.} =
  if length < 0 or length > 4 * 1024 * 1024:
    return nil
  alloc(length)

proc pw_free(buffer: pointer) {.exportc, cdecl.} =
  dealloc(buffer)

proc pw_initialize(buffer: pointer, length: cint): cint {.exportc, cdecl.} =
  try:
    if initialized:
      raise newException(ValueError, "An instance can initialize only one attempt")
    initialized = true
    if buffer == nil or length <= 0 or length > 4 * 1024 * 1024:
      raise newException(ValueError, "Invalid input buffer")
    var bytes = newString(length)
    copyMem(bytes[0].addr, buffer, length)
    let inputs = bytes.fromJson(Inputs)
    initializeHosted(inputs.config, inputs.policies)
    startReplayRecording(uint32(options.maximumTicks))
    return 0
  except CatchableError as error:
    outputs[3] = error.msg
    return -1

proc pw_advance(ticks: cint): cint {.exportc, cdecl.} =
  try:
    if not initialized or finalized or outputs[3].len > 0 or ticks < 1 or ticks > 256:
      raise newException(ValueError, "Invalid advance")
    for _ in 0 ..< ticks:
      if run.finished():
        return 1
      advanceGame()
      if run.recordingError.len > 0:
        raise newException(ValueError, run.recordingError)
    return (if run.finished(): 1 else: 0)
  except CatchableError as error:
    outputs[3] = error.msg
    return -1

proc pw_finalize(): cint {.exportc, cdecl.} =
  try:
    if not initialized or finalized or outputs[3].len > 0 or not run.finished():
      raise newException(ValueError, "Invalid finalize")
    finalized = true
    run.sampleMetrics(true)
    run.recorder.data.metrics = run.history.replayMetrics()
    outputs[1] = encodeReplay(run.recorder.data)
    let xp = run.world.totalXp()
    outputs[0] = "{\"scores\":" & scores(xp, int(run.world.tick)).toJson() &
      ",\"ticks\":" & $run.world.tick & ",\"seed\":" & $options.seed &
      ",\"outcome\":" & run.world.outcome().toJson() &
      ",\"banked_gold\":[],\"returned\":[],\"total_xp\":" & xp.toJson() & "}"
    finishLogs()
    return 0
  except CatchableError as error:
    outputs[3] = error.msg
    return -1

proc pw_output(kind: cint): pointer {.exportc, cdecl.} =
  if kind == 2:
    outputs[2] = logs.toJson()
  if kind >= 0 and kind < outputs.len and outputs[kind].len > 0:
    outputs[kind][0].addr
  else:
    nil

proc pw_output_length(kind: cint): cint {.exportc, cdecl.} =
  if kind >= 0 and kind < outputs.len:
    cint(outputs[kind].len)
  else:
    0
