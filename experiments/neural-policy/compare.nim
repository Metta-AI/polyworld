import
  std/[os, strutils],
  ../../examples/gods_of_the_arena/replays

let paths = commandLineParams()
doAssert paths.len == 2, "pass the original and converted replay paths"
let
  original = loadReplay(paths[0])
  converted = loadReplay(paths[1])
doAssert original.header == converted.header, "match setup differs"
doAssert original.actions == converted.actions, "action tapes differ"
doAssert original.hashes == converted.hashes, "per-tick state hashes differ"
doAssert original.metrics.tickRate == converted.metrics.tickRate
doAssert original.metrics.interval == converted.metrics.interval
doAssert original.metrics.frames.len == converted.metrics.frames.len
doAssert original.metrics.final.len == converted.metrics.final.len
for i, frame in original.metrics.frames:
  doAssert frame.tick == converted.metrics.frames[i].tick
  doAssert frame.rows.len == converted.metrics.frames[i].rows.len
var comparable = converted
comparable.config.players = original.config.players
comparable.metrics = original.metrics
doAssert original == comparable, "unexpected non-telemetry difference"
echo "Identical actions: ", original.actions.len
echo "Identical per-tick hashes: ", original.hashes.len
echo "Final state hash: ", original.hashes[^1].toHex(16)
echo "Only player labels and instruction telemetry may differ."
echo "Original final CPU percentages: ", original.metrics.final
echo "Converted final CPU percentages: ", converted.metrics.final
