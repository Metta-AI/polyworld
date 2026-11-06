## Every argument Coworld supplies reaches AWM.
##
## The Coworld server takes no command line: the runner stages a JSON config
## (`tokens`, `players`, `seed`, `max_ticks` and an optional `classes`) and
## the files it names. The headless runner takes the shared Polyworld flags
## and `--classes`; the replay viewer passes `--replay`, and the browser's
## URL parameters become session flags. The built server's file handoff is
## checked by `coworld/tools/test_runtime.nim awm`.
import std/[json, os, sequtils, sets, strutils, unittest]
import jsony
import polyworld/cli
import ../src/core/[sim, sessions, bots, match, replays]
import ../src/modes/headless

const
  Root = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  ArcherBot = staticRead("../players/archer.bas")
  WarriorBot = staticRead("../players/warrior.bas")

let
  manifest = parseFile(Root / "coworld/awm/coworld_manifest_template.json")
  schema = manifest["game"]["config_schema"]

proc staged(players: int, seed = 2026, maxTicks = 28_800,
    classes: seq[string] = @[]): string =
  ## A config as the runner stages it: one token and one name per seat.
  var config = %*{"tokens": [], "players": [], "seed": seed,
    "max_ticks": maxTicks}
  for slot in 0 ..< players:
    config["tokens"].add %("token-" & $slot)
    config["players"].add %*{"name": "Seat " & $slot}
  if classes.len > 0:
    config["classes"] = %classes
  $config

proc play(text: string, sources: seq[string]): (BotMatch, ReplayData) =
  ## Plays a config as `runCoworld` does: the classes override or each
  ## script's setup, then the seed and tick limit.
  let
    config = text.fromJson(GameConfig)
    names = text.configClasses()
    bots = loadBots(sources)
    seated =
      if names.len > 0: seatClasses(names, config.players.len)
      else: setupBotSeats(bots, config.seed.int64)
    recorder = initReplayRecorder(
      matchSetup(seated, config.seed, config.maxTicks.uint32), config)
  var played = initBotMatch(seated, config.seed.int64, bots,
    config.maxTicks.uint32, recorder)
  played.run()
  (played, recorder.data)

suite "Coworld config":
  test "the schema's fields are exactly the ones AWM reads":
    var fields: HashSet[string]
    for name, _ in schema["properties"]:
      fields.incl name
    check fields == toHashSet(["tokens", "players", "seed", "max_ticks",
      "classes"])
    check schema["required"].mapIt(it.getStr).toHashSet ==
      toHashSet(["tokens", "players", "seed", "max_ticks"])
    check not schema["additionalProperties"].getBool

  test "tokens, players and classes hold one entry per seat, 2 to 7":
    for field in ["tokens", "players", "classes"]:
      check schema["properties"][field]["minItems"].getInt == PlayerCount
      check schema["properties"][field]["maxItems"].getInt == MaxPlayers
    for seats in PlayerCount .. MaxPlayers:
      let config = staged(seats).fromJson(GameConfig)
      check config.players.len == seats
      check config.players[^1].name == "Seat " & $(seats - 1)

  test "player names reach the replay and tokens never do":
    let (_, data) = play(staged(3, maxTicks = 20),
      @[ArcherBot, WarriorBot, ArcherBot])
    check data.config.players.mapIt(it.name) == @["Seat 0", "Seat 1", "Seat 2"]
    let path = getTempDir() / "awm-test-coworld.replay"
    saveReplay(path, data)
    let bytes = readFile(path)
    let loaded = loadReplay(path)
    removeFile(path)
    check loaded.config.players == data.config.players
    check "token-" notin bytes

  test "seed: the whole int32 range deals a repeatable match":
    check schema["properties"]["seed"]["minimum"].getInt == int32.low
    check schema["properties"]["seed"]["maximum"].getInt == int32.high
    for seed in [int32.low.int, -1, 0, 1, 2026, int32.high.int]:
      let text = staged(2, seed, maxTicks = 60)
      check text.fromJson(GameConfig).seed == seed
      let
        (first, firstData) = play(text, @[ArcherBot, WarriorBot])
        (_, secondData) = play(text, @[ArcherBot, WarriorBot])
      check first.tick > 0
      check firstData.header.setup.seed == seed
      check firstData.hashes == secondData.hashes
    let
      (_, one) = play(staged(2, 1, 60), @[ArcherBot, WarriorBot])
      (_, two) = play(staged(2, 2, 60), @[ArcherBot, WarriorBot])
    check one.hashes != two.hashes

  test "max_ticks bounds the match":
    check schema["properties"]["max_ticks"]["minimum"].getInt == 1
    check schema["properties"]["max_ticks"]["maximum"].getInt ==
      DefaultDurationTicks
    for limit in [1, 7]:
      let text = staged(2, maxTicks = limit)
      check text.fromJson(GameConfig).maxTicks == limit
      let (played, data) = play(text, @[ArcherBot, WarriorBot])
      check played.tick == limit.uint32
      check played.outcomeLabel == "timeout"
      check played.scores == @[0, 0]
      check data.header.setup.maximumTicks == limit.uint32

  test "classes override every script's choice and deck":
    let enumerated = schema["properties"]["classes"]["items"]["enum"]
    check enumerated.mapIt(parseHeroClass(it.getStr)) == @[Archer, Warrior, Mage]
    # Without the override, each script's setup picks.
    let (picked, _) = play(staged(2, maxTicks = 1), @[ArcherBot, WarriorBot])
    check picked.game.players.mapIt(it.heroClass) == @[Archer, Warrior]
    check staged(2).configClasses().len == 0
    # With it, every seat plays its class's precon, in slot order.
    let text = staged(3, maxTicks = 1, classes = @["mage", "archer", "mage"])
    check text.configClasses() == @["mage", "archer", "mage"]
    let (played, data) = play(text, @[ArcherBot, WarriorBot, WarriorBot])
    check played.game.players.mapIt(it.heroClass) == @[Mage, Archer, Mage]
    check data.header.setup.heroClasses() == @[Mage, Archer, Mage]
    check seatClasses(@["warrior", "mage"], 2) ==
      @[precon(Warrior), precon(Mage)]

  test "a classes override must name one known class per seat":
    for (names, seats) in [(@["archer"], 2), (@["archer", "mage", "mage"], 2),
        (@["archer", "rogue"], 2), (@["archer", ""], 2)]:
      expect ValueError:
        discard seatClasses(names, seats)

  test "every config the manifest ships parses":
    var configs: seq[JsonNode]
    for variant in manifest["variants"]:
      configs.add variant["game_config"]
    configs.add manifest["certification"]["game_config"]
    for shipped in configs:
      var config = shipped.copy()
      config["tokens"] = newJArray()
      for slot in 0 ..< shipped["players"].len:
        config["tokens"].add %("token-" & $slot)
      let parsed = ($config).fromJson(GameConfig)
      check parsed.players.len in PlayerCount .. MaxPlayers
      check parsed.seed == shipped["seed"].getInt
      check parsed.maxTicks == shipped["max_ticks"].getInt
      check parsed.maxTicks in 1 .. DefaultDurationTicks
      check ($config).configClasses() == shipped{"classes"}.getElems.mapIt(
        it.getStr)

suite "headless runner flags":
  test "defaults":
    let parsed = parseHeadlessArgs(@[])
    check parsed.options.seed == DefaultSessionSeed.int32
    check parsed.options.maximumTicks == DefaultDurationTicks
    check parsed.options.botGroups.len == 0
    check parsed.classNames.len == 0

  test "--bot takes a path, a count, and repeats":
    let parsed = parseHeadlessArgs(@["--bot", "a.bas", "--bot", "b.bas:3",
      "--bot:c.bas", "--", "--bot", "C:/d.bas"])
    check parsed.options.botGroups == @[BotGroup(path: "a.bas", count: 1),
      BotGroup(path: "b.bas", count: 3), BotGroup(path: "c.bas", count: 1),
      BotGroup(path: "C:/d.bas", count: 1)]
    check parsed.options.botGroups.botCount == 6

  test "--seed over the int32 range":
    check parseHeadlessArgs(@["--seed", "-2147483648"]).options.seed == int32.low
    check parseHeadlessArgs(@["--seed", "2147483647"]).options.seed == int32.high
    check parseHeadlessArgs(@["--seed", "0"]).options.seed == 0

  test "--ticks, --seconds and --minutes set the tick limit":
    check parseHeadlessArgs(@["--ticks", "50"]).options.maximumTicks == 50
    check parseHeadlessArgs(@["--ticks=7"]).options.maximumTicks == 7
    check parseHeadlessArgs(@["--seconds", "2"]).options.maximumTicks ==
      2 * SharedTickRate
    check parseHeadlessArgs(@["--minutes=1"]).options.maximumTicks ==
      60 * SharedTickRate

  test "--classes, both forms":
    check parseHeadlessArgs(@["--classes", "archer,mage"]).classNames ==
      @["archer", "mage"]
    check parseHeadlessArgs(@["--classes=warrior,mage,archer"]).classNames ==
      @["warrior", "mage", "archer"]

  test "--record and --replay":
    let recorded = parseHeadlessArgs(@["--bot", "a.bas:2", "--record",
      "m.replay"])
    check recorded.options.recordPath == "m.replay"
    check parseHeadlessArgs(@["--replay", "m.replay"]).options.replayPath ==
      "m.replay"

suite "browser and replay viewer flags":
  test "the replay viewer passes --replay, or nothing":
    let page = readFile(Root / "src/polyworld/replay.html")
    check "arguments: replayUri ? ['--replay', '/episode.replay'] : []," in page
    check parseSessionOptions(["--replay", "/episode.replay"]).replayPath ==
      "/episode.replay"
    check parseSessionOptions([]).replayPath == ""

  test "the browser's URL parameters become session flags":
    # webinputs.js: replay=URL, bot=URL, seed=N; web/inputs.js: human=1,
    # players=N.
    let options = parseSessionOptions(["--replay", "/web/replay.replay",
      "--bot", "/web/bot0/archer.bas", "--bot", "/web/bot1/mage.bas",
      "--seed", "-42", "--human", "true", "--players", "4"])
    check options.replayPath == "/web/replay.replay"
    check options.botPaths == @["/web/bot0/archer.bas", "/web/bot1/mage.bas"]
    check options.seed == -42
    check options.human
    check options.playerCount == 4
    let inputs = readFile(currentSourcePath().parentDir.parentDir /
      "web/inputs.js")
    check "\"class\"" notin inputs
    check "\"opponent\"" notin inputs
