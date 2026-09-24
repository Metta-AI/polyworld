import std/[monotimes, times]

const
  NativeRequests* = not defined(emscripten) and not defined(js)
  MaxResponseBytes* = 256 * 1024
  MaxHeaderBytes = 16 * 1024

when NativeRequests:
  import libcurl

  type CurlHandles = object
    multi: PM
    easy: PCurl
    headers: PSlist

  proc close(handles: var CurlHandles) {.raises: [].} =
    ## Cancels a transfer and releases every native handle.
    if handles.multi != nil:
      if handles.easy != nil:
        discard multi_remove_handle(handles.multi, handles.easy)
      discard multi_cleanup(handles.multi)
      handles.multi = nil
    if handles.easy != nil:
      easy_cleanup(handles.easy)
      handles.easy = nil
    if handles.headers != nil:
      slist_free_all(handles.headers)
      handles.headers = nil

  proc `=destroy`(handles: var CurlHandles) =
    ## Cancels abandoned requests when their owner is released.
    handles.close()

  block:
    if global_init(GLOBAL_DEFAULT) != E_OK:
      raise newException(Defect, "Cannot initialize libcurl")

type
  RequestError* = object of CatchableError
  Request* = ref object
    when NativeRequests:
      handles: CurlHandles
    url, verb, payload: string
    body*, error*: string
    status*: int
    finished*: bool
    headerBytes: int
    started: MonoTime
    timeout: int

proc close*(request: Request) {.raises: [].} =
  ## Cancels a request without waiting for the remote endpoint.
  if request == nil:
    return
  when NativeRequests:
    request.handles.close()
  request.finished = true

when NativeRequests:
  proc receive(
    data: pointer, size, count: csize_t, context: pointer
  ): csize_t {.cdecl, raises: [].} =
    ## Aborts before a response can grow past the host's byte limit.
    let
      request = cast[Request](context)
      bytes = size * count
    if bytes > csize_t(MaxResponseBytes - request.body.len):
      request.error = "LLM response exceeds the byte limit"
      return 0
    let start = request.body.len
    request.body.setLen(start + int(bytes))
    if bytes > 0:
      copyMem(addr request.body[start], data, int(bytes))
    bytes

  proc receiveHeader(
    data: pointer, size, count: csize_t, context: pointer
  ): csize_t {.cdecl, raises: [].} =
    ## Bounds response headers without exposing credentials to scripts.
    let
      request = cast[Request](context)
      bytes = size * count
    if bytes > csize_t(MaxHeaderBytes - request.headerBytes):
      request.error = "LLM response headers exceed the byte limit"
      return 0
    request.headerBytes += int(bytes)
    bytes

proc startRequest*(
  url, verb, payload: string,
  headers: openArray[(string, string)],
  timeout = 30_000
): Request {.raises: [RequestError].} =
  ## Starts a bounded HTTP transfer that advances only when polled.
  when not NativeRequests:
    raise newException(RequestError, "LLM requests require a native host")
  else:
    if timeout <= 0:
      raise newException(RequestError, "LLM timeout must be positive")
    if (version_info(VERSION_NOW).features and VERSION_ASYNCHDNS) == 0:
      raise newException(RequestError, "libcurl needs asynchronous DNS")
    result = Request(
      url: url, verb: verb, payload: payload,
      started: getMonoTime(), timeout: timeout
    )
    result.handles.multi = multi_init()
    result.handles.easy = easy_init()
    if result.handles.multi == nil or result.handles.easy == nil:
      result.close()
      raise newException(RequestError, "Cannot allocate HTTP handles")
    for (name, value) in headers:
      let
        header = name & ": " & value
        added = slist_append(result.handles.headers, header.cstring)
      if added == nil:
        result.close()
        raise newException(RequestError, "Cannot allocate HTTP headers")
      result.handles.headers = added
    let easy = result.handles.easy
    template option(name, value: untyped) =
      ## Rejects unsupported options instead of making a partial request.
      if easy_setopt(easy, name, value) != E_OK:
        result.close()
        raise newException(RequestError, "Cannot configure HTTP request")
    option(OPT_URL, result.url.cstring)
    option(OPT_CUSTOMREQUEST, result.verb.cstring)
    option(OPT_HTTPHEADER, result.handles.headers)
    option(OPT_POSTFIELDSIZE, clong(result.payload.len))
    if result.payload.len > 0:
      option(OPT_POSTFIELDS, result.payload.cstring)
    option(OPT_NOSIGNAL, 1.clong)
    option(OPT_FOLLOWLOCATION, 0.clong)
    option(OPT_TIMEOUT, clong((timeout + 999) div 1000))
    option(OPT_WRITEFUNCTION, receive)
    option(OPT_WRITEDATA, cast[pointer](result))
    option(OPT_HEADERFUNCTION, receiveHeader)
    option(OPT_HEADERDATA, cast[pointer](result))
    if multi_add_handle(result.handles.multi, easy) != M_OK:
      result.close()
      raise newException(RequestError, "Cannot start HTTP request")

proc poll*(request: Request) {.raises: [].} =
  ## Advances ready socket work without waiting for network activity.
  if request == nil or request.finished:
    return
  when NativeRequests:
    if (getMonoTime() - request.started).inMilliseconds >= request.timeout:
      request.error = "LLM request timed out"
      request.close()
      return
    var running: int32
    let code = multi_perform(request.handles.multi, running)
    if code notin {M_OK, M_CALL_MULTI_PERFORM}:
      request.error = "HTTP transport failed: " & $multi_strerror(code)
      request.close()
      return
    var remaining: int32
    let message = multi_info_read(request.handles.multi, remaining)
    if message != nil and message.msg == MSG_DONE:
      var
        status: clong
        error: cint
      copyMem(addr error, addr message.whatever, sizeof(error))
      discard easy_getinfo(
        request.handles.easy, INFO_RESPONSE_CODE, addr status
      )
      request.status = int(status)
      if error != 0 and request.error.len == 0:
        request.error = "HTTP transfer failed: " & $easy_strerror(Code(error))
      request.close()
