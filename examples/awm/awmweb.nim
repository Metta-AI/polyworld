## Browser feeds for the global spectator and player WebSocket connections.
import std/[json, options, times]
import windy
import awmsessions

when defined(emscripten):
  import std/strutils
  {.emit: """
#include <emscripten.h>
EM_JS(void, awm_publish_status, (const char* text), {
  var element = document.getElementById('game-status');
  var value = UTF8ToString(text);
  if (element && element.textContent !== value) element.textContent = value;
});

EM_JS(void, awm_ws_connect, (const char* url), {
  if (window._awmWs) { try { window._awmWs.close(); } catch(e) {} }
  window._awmWsMessages = [];
  window._awmWsConnected = false;
  window._awmWsClosed = false;
  var ws = new WebSocket(UTF8ToString(url));
  window._awmWs = ws;
  ws.onopen = function() { window._awmWsConnected = true; };
  ws.onmessage = function(e) { window._awmWsMessages.push(e.data); };
  ws.onclose = function() { window._awmWsClosed = true; window._awmWsConnected = false; };
  ws.onerror = function() { window._awmWsClosed = true; window._awmWsConnected = false; };
});

EM_JS(int, awm_ws_connected, (), {
  return window._awmWsConnected ? 1 : 0;
});

EM_JS(int, awm_ws_receive, (char* buf, int maxLen), {
  if (!window._awmWsMessages || window._awmWsMessages.length === 0) return 0;
  var msg = window._awmWsMessages.shift();
  var len = lengthBytesUTF8(msg);
  if (len + 1 > maxLen) return -1;
  stringToUTF8(msg, buf, maxLen);
  return len;
});

EM_JS(void, awm_ws_send, (const char* msg), {
  if (window._awmWs && window._awmWs.readyState === 1) {
    window._awmWs.send(UTF8ToString(msg));
  }
});

EM_JS(int, awm_ws_closed, (), {
  return window._awmWsClosed ? 1 : 0;
});

EM_JS(void, awm_ws_get_origin, (char* buf, int maxLen), {
  var origin = window.location.origin;
  stringToUTF8(origin, buf, maxLen);
});
""".}
  proc awmPublishStatus(text: cstring) {.importc: "awm_publish_status", nodecl.}
  proc awmWsConnect(url: cstring) {.importc: "awm_ws_connect", nodecl.}
  proc awmWsConnected(): cint {.importc: "awm_ws_connected", nodecl.}
  proc awmWsReceive(buf: cstring, maxLen: cint): cint
    {.importc: "awm_ws_receive", nodecl.}
  proc awmWsSend(msg: cstring) {.importc: "awm_ws_send", nodecl.}
  proc awmWsClosed(): cint {.importc: "awm_ws_closed", nodecl.}
  proc awmWsGetOrigin(buf: cstring, maxLen: cint)
    {.importc: "awm_ws_get_origin", nodecl.}
  proc publishStatus*(text: cstring) = awmPublishStatus(text)
else:
  proc publishStatus*(text: cstring) = discard

type GlobalFeed* = ref object
  pending*: Option[Snapshot]
  message*: string
  inFlight: bool
  nextPoll: float64

proc newGlobalFeed*(): GlobalFeed =
  GlobalFeed(message: "Connecting to the global match...")

proc poll*(feed: GlobalFeed) =
  if feed.inFlight or epochTime() < feed.nextPoll:
    return
  feed.inFlight = true
  let endpoint = when defined(emscripten): "/api/global"
    else: "http://127.0.0.1:8080/api/global"
  let request = startHttpRequest(endpoint, deadline = 5)
  request.onError = proc(message: string) =
    feed.inFlight = false
    feed.nextPoll = epochTime() + 2
    feed.message = "Connection lost. Reconnecting..."
  request.onResponse = proc(response: HttpResponse) =
    feed.inFlight = false
    feed.nextPoll = epochTime() + 0.5
    try:
      if response.code != 200:
        raise newException(ValueError, "Global match unavailable")
      let body = parseJson(response.body)
      if body.hasKey("waiting"):
        feed.message = "Waiting for game to start..."
      else:
        feed.pending = some(snapshotFromJson(body))
        feed.message = "Watching the shared global match"
    except CatchableError:
      feed.nextPoll = epochTime() + 2
      feed.message = "Global match unavailable. Reconnecting..."

when defined(emscripten):
  type
    PlayerFeedState* = enum
      PfConnecting, PfSelectClass, PfWaiting, PfPlaying, PfDisconnected

    PlayerFeed* = ref object
      state*: PlayerFeedState
      slot*: int
      token*: string
      pending*: Option[GameState]
      revision*: int
      matchId*: string
      yourTurn*: bool
      needsClassSelection*: bool
      message*: string
      reconnectAt: float64
      buf: string

  proc wsUrl(slot: int, token: string): string =
    var origin = newString(512)
    awmWsGetOrigin(origin.cstring, origin.len.cint)
    origin.setLen(origin.cstring.len)
    let wsOrigin = if origin.startsWith("https://"):
      "wss://" & origin[8 .. ^1]
    else:
      "ws://" & origin[7 .. ^1]
    wsOrigin & "/player?slot=" & $slot & "&token=" & token

  proc newPlayerFeed*(slot: int, token: string): PlayerFeed =
    result = PlayerFeed(state: PfConnecting, slot: slot, token: token,
      message: "Connecting to game...",
      buf: newString(262144))
    awmWsConnect(wsUrl(slot, token).cstring)

  proc reconnect(feed: PlayerFeed) =
    feed.state = PfConnecting
    feed.message = "Reconnecting..."
    awmWsConnect(wsUrl(feed.slot, feed.token).cstring)

  proc poll*(feed: PlayerFeed) =
    if feed.state == PfDisconnected:
      if epochTime() >= feed.reconnectAt:
        feed.reconnect()
      return
    if feed.state == PfConnecting:
      if awmWsConnected() != 0:
        feed.state = PfWaiting
        feed.message = "Connected. Waiting..."
      elif awmWsClosed() != 0:
        feed.state = PfDisconnected
        feed.reconnectAt = epochTime() + 2
        feed.message = "Connection failed. Retrying..."
      return
    if awmWsClosed() != 0:
      feed.state = PfDisconnected
      feed.reconnectAt = epochTime() + 2
      feed.message = "Disconnected. Reconnecting..."
      return
    while true:
      let length = awmWsReceive(feed.buf.cstring, feed.buf.len.cint)
      if length <= 0:
        break
      let msg = feed.buf[0 ..< length]
      try:
        let data = parseJson(msg)
        case data.getOrDefault("type").getStr()
        of "selectClass":
          feed.state = PfSelectClass
          feed.needsClassSelection = true
          feed.message = "Choose your class."
        of "waiting":
          if feed.state != PfSelectClass:
            feed.state = PfWaiting
            feed.message = data.getOrDefault("message").getStr(
              "Waiting for opponent...")
        of "observation":
          feed.state = PfPlaying
          feed.pending = some(gameFromJson(data["game"]))
          feed.revision = data["revision"].getInt()
          feed.matchId = data.getOrDefault("matchId").getStr()
          feed.yourTurn = data["yourTurn"].getBool()
          if feed.yourTurn:
            feed.message = "Your turn."
          else:
            feed.message = "Opponent's turn."
        else: discard
      except CatchableError:
        discard

  proc selectClass*(feed: PlayerFeed, heroClass: HeroClass) =
    let msg = $(%*{"type": "selectClass",
      "class": heroClass.className().toLowerAscii()})
    awmWsSend(msg.cstring)
    feed.needsClassSelection = false
    feed.state = PfWaiting
    feed.message = "Waiting for opponent..."

  proc sendPlayCard*(feed: PlayerFeed, handIndex: int, choice: Choice) =
    var msg = %*{"type": "playCard", "handIndex": handIndex}
    if not choice.isCanceled:
      msg["choice"] = choiceToJson(choice)
    awmWsSend(($msg).cstring)

  proc sendEndTurn*(feed: PlayerFeed) =
    awmWsSend("{\"type\":\"endTurn\"}".cstring)
