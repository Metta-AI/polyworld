import
  std/[os, strutils],
  mummy

proc handleRequest(request: Request) {.gcsafe.} =
  if request.path != "/healthz":
    request.respond(404, body = "Not found\n")
  elif request.httpMethod != "GET":
    request.respond(405, @[("Allow", "GET")], "Method not allowed\n")
  else:
    request.respond(200, @[("Content-Type", "text/plain; charset=utf-8")], "ok\n")

when isMainModule:
  let
    host = getEnv("FAST_XP_HOST", "127.0.0.1")
    port = parseInt(getEnv("FAST_XP_PORT", "8080"))
  if port < 1 or port > 65535:
    raise newException(ValueError, "FAST_XP_PORT must be between 1 and 65535")
  let server = newServer(handleRequest, workerThreads = 2)
  echo "Fast XP server listening on http://", host, ":", port
  server.serve(Port(port), host)
