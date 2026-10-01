## The same policy surface with absent, bounded, and failing output destinations.
import std/[os, strutils, tempfiles, times], bassy
import polyworld/[annotations, policyhosts]

const Source = """
code = ANNOTATE(123, "intent", "selectTarget", "{""target"":7}")
status = ANNOTATE_STATUS()
message$ = ANNOTATE_ERROR$()
after = 42
"""

block:
  let schema = initPolicyHost()
  let program = compile(Source, schema)
  var runtime = initRuntime(program, schema)
  discard runtime.run()
  doAssert runtime.getGlobal("code") == ord(AnnotationDisabled)
  doAssert runtime.getGlobal("status") == ord(AnnotationDisabled)
  doAssert runtime.getGlobal("after") == 42
  echo "Annotation API works without an output destination"

when NativeAnnotations:
  block:
    let directory = createTempDir("annotation-bindings-", "")
    defer: removeDir(directory)
    let writer = newAnnotationWriter()
    defer: writer.close()
    let first = writer.newAnnotationSink(directory / "first.jsonl")
    let second = writer.newAnnotationSink(directory / "second.jsonl")
    discard writer.newAnnotationSink(directory / "unused.jsonl")
    let program = compile(Source, initPolicyHost())
    for sink in [first, second]:
      var host = initHost()
      host.addAnnotationFunctions(sink)
      var runtime = initRuntime(program, host)
      for i in 0 .. 1:
        runtime.restart()
        discard runtime.run()
        doAssert runtime.getGlobal("code") == ord(AnnotationAccepted)
        doAssert runtime.getGlobal("after") == 42
    writer.close()
    doAssert readFile(directory / "first.jsonl") == readFile(directory / "second.jsonl")
    doAssert readFile(directory / "first.jsonl").count('\n') == 2
    doAssert not fileExists(directory / "unused.jsonl")
    doAssert first.annotate(0, "intent", "f", "{}") == AnnotationClosed
    echo "Shared program, private destinations, unused output and drain passed"

  block:
    let directory = createTempDir("annotation-errors-", "")
    defer: removeDir(directory)
    let writer = newAnnotationWriter()
    defer: writer.close()
    let sink = writer.newAnnotationSink(directory / "events.jsonl")
    var host = initHost()
    host.addAnnotationFunctions(sink)
    for args in ["[1,2]", "5", "{}}", "{", "{\"x\":}", "{\"x\":1e9999}"]:
      let source = "code = ANNOTATE(123, \"intent\", \"f\", \"" &
        args.replace("\"", "\"\"") & "\")\nafter = 42\n"
      var runtime = initRuntime(compile(source, host), host)
      discard runtime.run()
      doAssert runtime.getGlobal("code") == ord(AnnotationInvalid)
      doAssert runtime.getGlobal("after") == 42
    var runtime = initRuntime(compile("""
code = ANNOTATE(1, 99, "f", "{}")
after = 42
""", host), host)
    discard runtime.run()
    doAssert runtime.getGlobal("code") == ord(AnnotationInvalid)
    doAssert runtime.getGlobal("after") == 42
    doAssert sink.annotate(0, "", "f", "{}") == AnnotationInvalid
    doAssert sink.annotate(0, "intent", repeat('x', 257), "{}") == AnnotationInvalid
    doAssert sink.annotate(0, "intent", "f",
      "{\"nested\":" & repeat('[', 65) & "0" & repeat(']', 65) & "}") == AnnotationInvalid
    doAssert sink.annotate(0, "intent", "f", repeat('x', AnnotationEventLimit + 1)) == AnnotationTooLarge
    doAssert sink.annotate(0, "intent", "f", "{}") == AnnotationAccepted
    writer.close()
    doAssert readFile(directory / "events.jsonl").count('\n') == 1
    echo "Invalid input and event limit do not disable the VM or poison later events"

  block:
    let directory = createTempDir("annotation-budget-", "")
    defer: removeDir(directory)
    let writer = newAnnotationWriter()
    defer: writer.close()
    let sink = writer.newAnnotationSink(directory / "events.jsonl")
    let args = "{\"payload\":\"" & repeat('x', 16000) & "\"}"
    var accepted = 0
    while true:
      case sink.annotate(0, "intent", "f", args)
      of AnnotationAccepted: inc accepted
      of AnnotationQueueFull: sleep(1)
      of AnnotationBudgetExceeded: break
      else: doAssert false
    # Exhaust the remaining space with small events before exercising the VM.
    while true:
      case sink.annotate(123, "intent", "selectTarget", "{\"target\":7}")
      of AnnotationAccepted: discard
      of AnnotationQueueFull: sleep(1)
      of AnnotationBudgetExceeded: break
      else: doAssert false
    var host = initHost()
    host.addAnnotationFunctions(sink)
    var runtime = initRuntime(compile(Source, host), host)
    discard runtime.run()
    doAssert runtime.getGlobal("code") == ord(AnnotationBudgetExceeded)
    doAssert runtime.getGlobal("after") == 42
    writer.close()
    doAssert getFileSize(directory / "events.jsonl") <= AnnotationFileLimit
    doAssert accepted > 4000
    echo "64 MiB budget rejects events without stopping the policy"

  block:
    let directory = createTempDir("annotation-io-", "")
    defer: removeDir(directory)
    let writer = newAnnotationWriter()
    defer: writer.close()
    # Opening a directory as an output file fails on the worker thread.
    let sink = writer.newAnnotationSink(directory)
    discard sink.annotate(0, "intent", "f", "{}")
    let deadline = epochTime() + 5
    while sink.annotationStatus != AnnotationWriteFailed:
      doAssert epochTime() < deadline
      sleep(1)
    var host = initHost()
    host.addAnnotationFunctions(sink)
    var runtime = initRuntime(compile(Source, host), host)
    discard runtime.run()
    doAssert runtime.getGlobal("code") == ord(AnnotationWriteFailed)
    doAssert runtime.getGlobal("after") == 42
    echo "Asynchronous I/O failure is policy-readable and nonfatal"

  when defined(posix):
    import std/posix
    proc drainPipe(path: string) {.thread.} =
      let input = open(path, fmRead)
      defer: input.close()
      discard input.readAll()

    block:
      let directory = createTempDir("annotation-pressure-", "")
      defer: removeDir(directory)
      let path = directory / "blocked-pipe"
      doAssert mkfifo(path.cstring, Mode(0o600)) == 0
      let writer = newAnnotationWriter()
      let sink = writer.newAnnotationSink(path)
      let started = epochTime()
      var rejected = false
      for i in 0 .. AnnotationQueueLimit + 1:
        if sink.annotate(0, "intent", "f", "{}") == AnnotationQueueFull:
          rejected = true
      doAssert rejected
      doAssert epochTime() - started < 1
      # No reader existed, so the writer was blocked in open throughout enqueue.
      var reader: Thread[string]
      createThread(reader, drainPipe, path)
      writer.close()
      joinThread(reader)
      echo "Blocked storage cannot block policy enqueue; queue pressure is bounded"
