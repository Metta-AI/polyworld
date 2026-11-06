## nim c -d:release -d:headless --opt:speed tests/bench_local_avoidance.nim
## Binary args: output.json [ticks=900] [runs=5]. Timing excludes metrics/setup.
import std/[algorithm, json, monotimes, times, os, strutils]
import trafficfixture

let ticks = if paramCount() >= 2: parseInt(paramStr(2)) else: 900
let runs = if paramCount() >= 3: parseInt(paramStr(3)) else: 5
var output = newJArray()
for run in 0 ..< runs:
  for scenario in ["opposing", "crossing", "choke", "miners"]:
    for count in [2, 20, 100, 300]:
      let f = trafficFixture(count, scenario)
      let w = f.world
      var samples = newSeq[int64]()
      var last = f.starts
      var stallTicks, overlapSamples, deposits: int
      var peakOverlap = 0
      pathSearches = 0
      pathExpansions = 0
      for tick in 0 ..< ticks:
        let gold = w.players[0].goldGathered
        let start = getMonoTime()
        w.tickWorld(nil)
        samples.add (getMonoTime() - start).inNanoseconds
        if w.players[0].goldGathered > gold: inc deposits
        for i, unit in w.units:
          if unit.hasGoal and unit.body.pos == last[i]: inc stallTicks
          last[i] = unit.body.pos
        if tick mod 30 == 0:
          var overlaps = 0
          for i in 0 ..< w.units.len:
            if w.units[i].state in {UnitDying, UnitInMine}: continue
            for j in i+1 ..< w.units.len:
              if w.units[j].state in {UnitDying, UnitInMine}: continue
              if length(w.units[i].body.pos-w.units[j].body.pos) <
                  w.units[i].body.radius+w.units[j].body.radius-0.01'fx:
                inc overlaps
          overlapSamples += overlaps
          peakOverlap = max(peakOverlap, overlaps)
      var complete = 0
      var displacement = 0'i64
      for i, unit in w.units:
        if length(unit.body.pos - f.goals[i]) <= 0.4'fx: inc complete
        displacement += int32(length(unit.body.pos - f.starts[i])).int64
      let raw = samples
      samples.sort()
      output.add %*{"run": run, "scenario": scenario, "count": count,
        "ticks": ticks, "seed": 73021, "median_ns": samples[samples.len div 2],
        "p95_ns": samples[samples.len*95 div 100], "completed": complete,
        "displacement_q16": displacement, "stall_unit_ticks": stallTicks,
        "overlap_pair_samples": overlapSamples, "peak_overlap_pairs": peakOverlap,
        "deposit_ticks": deposits, "gold_gathered": w.players[0].goldGathered,
        "path_searches": pathSearches, "path_expansions": pathExpansions,
        "hash": $Game(world:w).stateHash(), "raw_tick_ns": raw}
      writeFile(paramStr(1), $output)
      echo run, " ", scenario, " ", count, " median=", samples[samples.len div 2],
        " p95=", samples[samples.len*95 div 100], " complete=", complete,
        " gold=", w.players[0].goldGathered
