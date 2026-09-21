## Local GotA player endpoint for neural policies and interactive clients.
##
## One client supplies actions for all five heroes on one team. The opposing
## team continues to run BASIC. Observations match the native training batch.
import std/[asynchttpserver, asyncdispatch, json, strutils]
import ws
when isMainModule:
    import std/os
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
    $(%*{
        "type": "observation",
        "features": transition.features,
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
        "heroDeaths": transition.heroDeaths,
        "maxWork": transition.maxWork,
        "maxInstructions": transition.maxInstructions
    })

proc servePlayer*(options: PlayerServerOptions) {.async.} =
    let config = loadConfig(options.config)
    let policy = readFile(options.policy)
    let listener = newAsyncHttpServer()
    proc requestHandler(request: Request) {.async, gcsafe.} =
        if request.url.path != "/player" or
                request.headers.getOrDefault("Upgrade").toLowerAscii() != "websocket":
            await request.respond(Http404, "GotA player endpoint is /player\n")
            return
        let ws = await newWebSocket(request)
        defer: ws.close()
        try:
            {.cast(gcsafe).}:
                let batch = newTrainingBatch(config, options.bot, options.opponent,
                    policy, 1, options.maxTicks)
                defer: batch.close()
                batch.reset(options.seed)
                await ws.send(observationJson(batch.lanes[0].transition))
                while ws.readyState == Open:
                    let (opcode, message) = await ws.receivePacket()
                    case opcode
                    of Text: discard
                    of Ping:
                        await ws.send(message, Pong)
                        continue
                    of Pong: continue
                    else: break
                    let data = parseJson(message)
                    if data.kind != JObject or not data.hasKey("action") or
                            data["action"].kind != JInt:
                        break
                    let action = data["action"].getInt
                    if action notin 0 ..< GotaActionCount:
                        break
                    var transitions: array[1, Transition]
                    batch.step([int32(action)], transitions)
                    await ws.send(observationJson(transitions[0]))
                    if transitions[0].terminal != 0:
                        await ws.send(observationJson(batch.lanes[0].transition))
        except CatchableError:
            discard

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
