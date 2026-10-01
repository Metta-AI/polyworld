## Minimal WebSocket server for AWM. Handles upgrade, text frames, and close.
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
import std/[asyncnet, asyncdispatch, asynchttpserver, base64, strutils]

const WsMagic = "258EAFA5-E914-47DA-95CA-5AB9FC085B11"

type
  WsOpcode* = enum
    WsContinuation = 0x0
    WsText = 0x1
    WsBinary = 0x2
    WsClose = 0x8
    WsPing = 0x9
    WsPong = 0xA

  WsMessage* = object
    opcode*: WsOpcode
    data*: string

  WebSocket* = ref object
    socket*: AsyncSocket
    closed*: bool

proc acceptKey(clientKey: string): string =
  let hash = secureHash(clientKey & WsMagic)
  let digest = Sha1Digest(hash)
  var raw = newString(20)
  for i in 0 ..< 20:
    raw[i] = chr(digest[i])
  base64.encode(raw)

proc upgradeWebSocket*(request: Request): Future[WebSocket] {.async, gcsafe.} =
  let key = request.headers.getOrDefault("Sec-WebSocket-Key")
  if key.len == 0:
    raise newException(ValueError, "Missing Sec-WebSocket-Key")
  let response = "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & acceptKey(key) & "\r\n\r\n"
  await request.client.send(response)
  WebSocket(socket: request.client, closed: false)

proc readExact(socket: AsyncSocket, size: int): Future[string] {.async.} =
  var data = newStringOfCap(size)
  while data.len < size:
    let chunk = await socket.recv(size - data.len)
    if chunk.len == 0:
      raise newException(IOError, "WebSocket connection closed")
    data.add chunk
  data

proc sendFrame(ws: WebSocket, opcode: WsOpcode, data: string) {.async, gcsafe.} =
  var frame = newStringOfCap(10 + data.len)
  frame.add chr(0x80'u8 or opcode.uint8)
  if data.len < 126:
    frame.add chr(data.len.uint8)
  elif data.len < 65536:
    frame.add chr(126'u8)
    frame.add chr(((data.len shr 8) and 0xFF).uint8)
    frame.add chr((data.len and 0xFF).uint8)
  else:
    frame.add chr(127'u8)
    for i in countdown(7, 0):
      frame.add chr(((data.len shr (i * 8)) and 0xFF).uint8)
  frame.add data
  await ws.socket.send(frame)

proc send*(ws: WebSocket, text: string) {.async, gcsafe.} =
  if not ws.closed:
    await ws.sendFrame(WsText, text)

proc recv*(ws: WebSocket): Future[WsMessage] {.async, gcsafe.} =
  let header = await ws.socket.readExact(2)
  let rawOpcode = header[0].uint8 and 0x0F
  let opcode = case rawOpcode
    of 0x0: WsContinuation
    of 0x1: WsText
    of 0x2: WsBinary
    of 0x8: WsClose
    of 0x9: WsPing
    of 0xA: WsPong
    else: WsClose
  let masked = (header[1].uint8 and 0x80) != 0
  var payloadLen = (header[1].uint8 and 0x7F).int
  if payloadLen == 126:
    let ext = await ws.socket.readExact(2)
    payloadLen = (ext[0].uint8.int shl 8) or ext[1].uint8.int
  elif payloadLen == 127:
    let ext = await ws.socket.readExact(8)
    payloadLen = 0
    for i in 0 ..< 8:
      payloadLen = (payloadLen shl 8) or ext[i].uint8.int
  var maskKey: array[4, uint8]
  if masked:
    let mk = await ws.socket.readExact(4)
    for i in 0 ..< 4:
      maskKey[i] = mk[i].uint8
  var data = await ws.socket.readExact(payloadLen)
  if masked:
    for i in 0 ..< data.len:
      data[i] = chr(data[i].uint8 xor maskKey[i mod 4])
  if opcode == WsPing:
    await ws.sendFrame(WsPong, data)
    return await ws.recv()
  if opcode == WsClose:
    ws.closed = true
  WsMessage(opcode: opcode, data: data)

proc close*(ws: WebSocket) =
  if not ws.closed:
    ws.closed = true
    try:
      ws.socket.close()
    except CatchableError:
      discard
