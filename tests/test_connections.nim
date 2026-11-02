import polyworld/[connections, rooms]

doAssert serverUrl(" host.test:9911 ") == "ws://host.test:9911/ws"
doAssert serverUrl("ws://localhost:9911/") == "ws://localhost:9911/ws"
doAssert serverUrl("wss://host.test") == "wss://host.test/ws"
doAssert serverUrl("ws://[::1]:9911") == "ws://[::1]:9911/ws"
doAssert serverUrl("wss://host.test/custom?key=value") ==
  "wss://host.test/custom?key=value"
for address in ["", "http://host.test", "ws:///ws", "host.test:abc",
  "host.test:0", "host.test:65536", "host name:9911", "ws://user@host"]:
    var rejected = false
    try:
      discard serverUrl(address)
    except RoomsError:
      rejected = true
    doAssert rejected, address
echo "Server address normalization and validation passed"
