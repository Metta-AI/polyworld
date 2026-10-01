## Optional policy telemetry. Only the writer thread touches output files.
import std/[json, math, tables], bassy, jsony

const
  AnnotationEventLimit* = 16 * 1024
  AnnotationFileLimit* = 64 * 1024 * 1024
  AnnotationQueueLimit* = 256
  NativeAnnotations* = compileOption("threads") and
    not defined(emscripten) and not defined(js)

type
  AnnotationStatus* = enum
    AnnotationAccepted, AnnotationDisabled, AnnotationInvalid,
    AnnotationTooLarge, AnnotationBudgetExceeded, AnnotationQueueFull,
    AnnotationWriteFailed, AnnotationClosed

when NativeAnnotations:
  import std/[atomics, os]
  type
    AnnotationRequest = object
      path, line: string
      failure: ptr Atomic[bool]
      stop: bool
    AnnotationQueue = object
      requests: Channel[AnnotationRequest]
    AnnotationWriter* = ref object
      queue: ptr AnnotationQueue
      thread: Thread[ptr AnnotationQueue]
      sinks: seq[AnnotationSink]
    AnnotationSink* = ref object
      writer: AnnotationWriter
      failure: ptr Atomic[bool]
      path: string
      bytes: int
      status: AnnotationStatus
else:
  type AnnotationSink* = ref object
    status: AnnotationStatus

proc annotationStatus*(sink: AnnotationSink): AnnotationStatus =
  ## Reports asynchronous output failures as well as the last call's result.
  if sink == nil:
    return AnnotationDisabled
  when NativeAnnotations:
    if sink.failure != nil and sink.failure[].load():
      return AnnotationWriteFailed
  sink.status

proc annotationMessage*(status: AnnotationStatus): string =
  ## Stable status codes carry short, policy-readable explanations.
  case status
  of AnnotationAccepted: ""
  of AnnotationDisabled: "No annotation destination"
  of AnnotationInvalid: "Invalid annotation: expected numeric time, kind, function and a JSON object"
  of AnnotationTooLarge: "Annotation exceeds 16 KiB"
  of AnnotationBudgetExceeded: "Annotations exceed 64 MiB per seat"
  of AnnotationQueueFull: "Annotation queue full; event not accepted"
  of AnnotationWriteFailed: "Annotation output could not be written"
  of AnnotationClosed: "Annotation output closed"

when NativeAnnotations:
  proc writeAnnotations(queue: ptr AnnotationQueue) {.thread.} =
    ## Owns all file handles; batches available records before flushing.
    var outputs: Table[string, tuple[file: File, failure: ptr Atomic[bool]]]
    var stopped = false
    while not stopped:
      var request = queue.requests.recv()
      while true:
        if request.stop:
          stopped = true
          break
        if not request.failure[].load():
          try:
            if request.path notin outputs:
              createDir(request.path.parentDir)
              outputs[request.path] = (open(request.path, fmWrite), request.failure)
            outputs[request.path].file.write(request.line)
          except IOError, OSError:
            request.failure[].store(true)
        let next = queue.requests.tryRecv()
        if not next.dataAvailable:
          break
        request = next.msg
      for output in outputs.values:
        if not output.failure[].load():
          try:
            output.file.flushFile()
          except IOError:
            output.failure[].store(true)
    for output in outputs.values:
      try:
        output.file.close()
      except IOError:
        output.failure[].store(true)

  proc newAnnotationWriter*(): AnnotationWriter =
    ## Starts one bounded writer for an episode, before policies execute.
    result = AnnotationWriter(queue: createShared(AnnotationQueue))
    result.queue.requests.open(AnnotationQueueLimit)
    createThread(result.thread, writeAnnotations, result.queue)

  proc newAnnotationSink*(writer: AnnotationWriter, path: string): AnnotationSink =
    ## Binds a private destination once; policies cannot choose filesystem paths.
    result = AnnotationSink(writer: writer, path: path,
      failure: createShared(Atomic[bool]))
    writer.sinks.add result

  proc close*(writer: AnnotationWriter) =
    ## Drains accepted events at existing episode cleanup, never during actions.
    if writer.queue == nil:
      return
    writer.queue.requests.send(AnnotationRequest(stop: true))
    joinThread(writer.thread)
    writer.queue.requests.close()
    deallocShared(writer.queue)
    writer.queue = nil
    for sink in writer.sinks:
      sink.status = if sink.failure[].load(): AnnotationWriteFailed else: AnnotationClosed
      deallocShared(sink.failure)
      sink.failure = nil
      sink.writer = nil
    writer.sinks.setLen(0)

proc validParameters(value: JsonNode, depth = 0): bool =
  ## Bounds nesting and excludes non-finite numbers rejected by the platform.
  if depth > 64:
    return false
  case value.kind
  of JFloat:
    result = value.getFloat().classify notin {fcNan, fcInf, fcNegInf}
  of JObject:
    result = true
    for child in value.fields.values:
      if not validParameters(child, depth + 1): return false
  of JArray:
    result = true
    for child in value.elems:
      if not validParameters(child, depth + 1): return false
  else: result = true

proc annotate*(sink: AnnotationSink, time: int32, kind, function, args: string): AnnotationStatus =
  ## Validates bounded input and tries to enqueue; never waits for disk or space.
  if sink == nil:
    return AnnotationDisabled
  when NativeAnnotations:
    if sink.writer == nil or sink.annotationStatus == AnnotationWriteFailed:
      return sink.annotationStatus
    sink.status = AnnotationInvalid
    if kind.len == 0 or kind.len > 128 or function.len == 0 or function.len > 256:
      return sink.status
    if args.len > AnnotationEventLimit:
      sink.status = AnnotationTooLarge
      return sink.status
    var parameters: JsonNode
    try:
      parameters = parseJson(args)
    except JsonParsingError, ValueError:
      return sink.status
    if parameters.kind != JObject or not validParameters(parameters):
      return sink.status
    let line = "{\"schema_version\":1,\"time\":" & $time &
      ",\"kind\":" & kind.toJson() & ",\"function\":" & function.toJson() &
      ",\"args\":" & $parameters & "}\n"
    if line.len > AnnotationEventLimit:
      sink.status = AnnotationTooLarge
    elif sink.bytes + line.len > AnnotationFileLimit:
      sink.status = AnnotationBudgetExceeded
    elif not sink.writer.queue.requests.trySend(AnnotationRequest(
        path: sink.path, line: line, failure: sink.failure)):
      sink.status = AnnotationQueueFull
    else:
      sink.bytes += line.len
      sink.status = AnnotationAccepted
    return sink.status
  else:
    return AnnotationDisabled

proc addAnnotationFunctions*(host: var Host, sink: AnnotationSink = nil) =
  ## Identical API and work costs in schema, hosted, desktop and browser hosts.
  let emit: ContextHostProc = proc(runtime: Runtime, args: openArray[Value]): Value =
    if sink == nil:
      return Value(ord(AnnotationDisabled))
    var status: AnnotationStatus
    try:
      status = sink.annotate(args[0].asInt, runtime.getString(args[1]),
        runtime.getString(args[2]), runtime.getString(args[3]))
    except BasicError:
      status = AnnotationInvalid
      sink.status = status
    Value(ord(status))
  let status: ContextHostProc = proc(runtime: Runtime, args: openArray[Value]): Value =
    Value(ord(sink.annotationStatus))
  let message: ContextHostProc = proc(runtime: Runtime, args: openArray[Value]): Value =
    var runtime = runtime
    runtime.putString(sink.annotationStatus.annotationMessage)
  discard host.addFunction("ANNOTATE", 4, emit, workUnits = 1024)
  discard host.addFunction("ANNOTATE_STATUS", 0, status, workUnits = 1)
  discard host.addFunction("ANNOTATE_ERROR$", 0, message, workUnits = 1)
