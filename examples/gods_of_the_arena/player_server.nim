## Local GotA player endpoint for neural policies and interactive clients.
##
## The game still executes BASIC for the nine fixed players.  The connected
## player receives the same native feature vector used by the training batch
## and returns one of the eight actions at each hero decision.
import std/[asynchttpserver, asyncdispatch, json, os, strutils]
import ../awm/awmwebsocket
import training
import presets

type
  PlayerServerOptions* = object
    host*: string
    port*: int
    bot*: string
    opponent*: string
    policy*: string
    config*: string
    maxTicks*: int
    seed*: int

proc observationJson(transition: Transition): string =
  var features = newJArray()
  for value in transition.features:
    features.add %value
  $(%*{
    "type": "observation",
    "features": features,
    "tick": transition.tick,
    "seat": transition.seat,
    "reward": transition.reward,
    "terminal": transition.terminal != 0,
    "outcome": transition.outcome,
    "stateHash": toHex(transition.stateHash, 16),
    "xp": transition.xp,
    "structureHp": transition.structureHp,
    "heroXp": transition.heroXp,
    "heroGold": transition.heroGold,
    "heroKills": transition.heroKills,
    "heroDeaths": transition.heroDeaths
  })

proc actionValue(data: JsonNode): int32 =
  let value = if data.kind == JObject and data.hasKey("action"):
    data["action"].getInt
  else:
    -1
  doAssert value in 0 .. 7, "player action must be an integer from 0 through 7"
  int32(value)

proc servePlayer*(options: PlayerServerOptions) {.async.} =
  let config = loadConfig(options.config)
  let listener = newAsyncHttpServer()
  proc requestHandler(request: Request) {.async, gcsafe.} =
    if request.url.path != "/player" or
        request.headers.getOrDefault("Upgrade").toLowerAscii() != "websocket":
      await request.respond(Http404, "GotA player endpoint is /player\n")
      return
    let ws = await upgradeWebSocket(request)
    {.cast(gcsafe).}:
      let batch = newTrainingBatch(config, options.bot, options.opponent,
        options.policy, 1, options.maxTicks)
      defer: batch.close()
      await ws.send(observationJson(batch.lanes[0].transition))
      while not ws.closed:
        let message = await ws.recv()
        if message.opcode == WsClose:
          break
        if message.opcode != WsText:
          continue
        let action = actionValue(parseJson(message.data))
        var transitions: array[1, Transition]
        batch.step([action], transitions)
        await ws.send(observationJson(transitions[0]))
  await listener.serve(Port(options.port), requestHandler, options.host)

when isMainModule:
  let repo = currentSourcePath().parentDir.parentDir.parentDir
  let options = PlayerServerOptions(
    host: "127.0.0.1",
    port: 8080,
    bot: repo / "examples/gods_of_the_arena/players/base.bas",
    opponent: repo / "examples/gods_of_the_arena/players/base.bas",
    policy: repo / "examples/gods_of_the_arena/players/neural.bas",
    config: repo / "examples/gods_of_the_arena/presets/saved.json",
    maxTicks: 28_800,
    seed: 0
  )
  waitFor servePlayer(options)
