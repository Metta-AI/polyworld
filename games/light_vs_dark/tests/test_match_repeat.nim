## Run the exact graphics transport initialization against the real scheduler.
import std/[macros, times, unittest]
import polyworld/player
import ../[game, sim, multiplayer]

macro initRenderedTransport(): untyped =
  let source = parseStmt(staticRead("../graphics.nim"))
  for node in source:
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkAsgn and child[0].repr == "transport":
          return child
  error("Missing graphics transport initialization")

suite "LvD end-of-match transport":
  test "local humans stay at the final tick without a checkpoint restore":
    run = Game(maximumTicks: 100)
    options.playerSlot = 1
    var network: NetworkMatch
    var transport: player.Player
    initRenderedTransport()
    check not transport.repeating
    for ended in [false, true]:
      transport.sync(100, 100, ended)
      transport.startFrame(0.1, 30)
      check not transport.shouldTick(epochTime())
      check transport.takeRestore() == -1
      check transport.targetTick == -1
      check not transport.playing
      check transport.tick == 100

  test "network humans and bot-only owners never repeat":
    for slot in [0'i32, 1'i32]:
      run = Game(maximumTicks: 100, networked: true)
      options.playerSlot = slot
      var network = NetworkMatch()
      var transport: player.Player
      initRenderedTransport()
      check not transport.repeating
      transport.sync(100, 100, true)
      transport.startFrame(0.1, 30)
      check not transport.shouldTick(epochTime())
      check transport.takeRestore() == -1
      check transport.targetTick == -1

  test "file replays and local unowned watches keep their automatic loop":
    for replay in [false, true]:
      run = Game(maximumTicks: 100, replayMode: replay)
      options.playerSlot = if replay: 1 else: 0
      var network: NetworkMatch
      var transport: player.Player
      initRenderedTransport()
      check transport.repeating
      transport.sync(100, 100, true)
      transport.startFrame(0.1, 30)
      check not transport.shouldTick(epochTime())
      check transport.takeRestore() == 0
      check transport.targetTick == 0
      check transport.automaticSeek
    run = nil
    options.playerSlot = 0
