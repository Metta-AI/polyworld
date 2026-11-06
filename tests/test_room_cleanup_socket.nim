## Real binary WebSocket regression. Run only against an isolated candidate.
## ROOM_CLEANUP_SERVER defaults to loopback port 19951; never use the live relay.
import std/[asyncdispatch, os]
import ws
import polyworld/rooms

type Client = ref object
  socket: WebSocket
  id: uint32
  token: string

proc send(c: Client, m: RoomMessage) {.async.} =
  await c.socket.send(m.encode(), Binary)

proc next(c: Client): Future[RoomMessage] {.async.} =
  let receive = c.socket.receivePacket()
  doAssert await withTimeout(receive, 3000), "Timed out waiting for relay"
  let (opcode, bytes) = receive.read()
  doAssert opcode == Binary
  result = decode(bytes)
  if result.delivery != 0:
    await c.send(RoomMessage(kind: Received, sequence: result.delivery))

proc until(c: Client, kind: MessageKind, emptyRoom = false): Future[RoomMessage] {.async.} =
  for i in 0 ..< 100:
    let m = await c.next()
    if m.kind == kind and (not emptyRoom or m.room == ""): return m
    doAssert m.kind != Failure, m.detail
  doAssert false, "Expected packet never arrived"

proc connect(url: string, token = ""): Future[Client] {.async.} =
  result = Client(socket: await newWebSocket(url))
  await result.send(RoomMessage(kind: Hello, name: "Cleanup socket QA", token: token,
    identity: GameIdentity(game: "cleanup-socket-test", gameplay: 1, protocol: 1)))
  let welcome = await result.until(Welcome)
  result.id = welcome.participant
  result.token = welcome.token

proc listings(c: Client): Future[seq[RoomListing]] {.async.} =
  await c.send(RoomMessage(kind: ListRooms))
  return (await c.until(RoomList)).rooms

proc create(c: Client): Future[string] {.async.} =
  await c.send(RoomMessage(kind: CreateRoom, name: "Room cleanup socket QA",
    number: 2, tickRate: 24, flag: true))
  return (await c.until(RoomState)).room

proc main() {.async.} =
  let url = getEnv("ROOM_CLEANUP_SERVER", "ws://127.0.0.1:19951/ws")
  doAssert url == "ws://127.0.0.1:19951/ws", "Use the isolated loopback candidate"
  let observer = await connect(url)
  var host = await connect(url)
  let token = host.token
  let invite = await host.create()
  doAssert (await observer.listings()).len == 1
  let watcher = await connect(url)
  await watcher.send(RoomMessage(kind: JoinRoom, room: invite))
  discard await watcher.until(RoomState)
  host.socket.hangup()
  await sleepAsync(100)
  doAssert (await observer.listings()).len == 1, "Seatless watcher must retain room"
  await watcher.send(RoomMessage(kind: LeaveRoom))
  discard await watcher.until(RoomState, emptyRoom = true)
  doAssert (await observer.listings()).len == 0, "Deleted room must vanish from listing"
  await observer.send(RoomMessage(kind: JoinRoom, room: invite))
  doAssert (await observer.until(Failure)).detail.len > 0
  host = await connect(url, token)
  doAssert host.token == token
  await host.send(RoomMessage(kind: ReturnLobby))
  doAssert (await host.until(Failure)).detail == "Join a room first"
  doAssert (await observer.listings()).len == 0, "Reconnect must not resurrect room"
  let secondInvite = await host.create()
  host.socket.hangup()
  await sleepAsync(100)
  doAssert (await observer.listings()).len == 0, "Last disconnect must delete room"
  await observer.send(RoomMessage(kind: JoinRoom, room: secondInvite))
  discard await observer.until(Failure)
  host = await connect(url, token)
  discard await host.create()
  # Leave the sole participant completely inactive; keep the outside observer alive.
  for second in 0 ..< 17:
    await sleepAsync(1000)
    await observer.send(RoomMessage(kind: Keepalive))
    discard await observer.until(Keepalive)
  doAssert (await observer.listings()).len == 0, "15-second timeout must delete room"
  observer.socket.hangup()
  watcher.socket.hangup()
  host.socket.hangup()
  echo "Socket cleanup passed: spectator retention, Leave, disconnect, timeout, listing disappearance, stale invites and reconnect non-resurrection"

waitFor main()
