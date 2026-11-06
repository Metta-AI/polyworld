# Local soft bodies (gameplay 32)

This replaces the gameplay-31 rigid-friendly-contact behavior, not the global router. It is a bounded fixed-point rubber-circle approximation, not a claim to reproduce Dota's algorithm.

## Causal trace and rules

Previously `standingOccupant` made idle friends hard A* walls, also in string pulling; `steerUnit` rejected every dense cell envelope; `separatePair` removed all penetration immediately and ignored exactly coincident circles. Thus alternate routes/yield reservations did not implement pushing through idle friends, and overflow could freeze an entire friendly cell.

Now same-owner occupancy is not a movement wall. Terrain A*, occupancy entry penalties and resource-ring preference remain. Bodies are still radius 0.22 tile. Friendly penetration is corrected gradually at 35% of depth, with a summed per-body correction capped at 0.08 tile per tick. A moving body takes 10% contact share against an idle friend; the idle friend receives full pressure plus a deterministic lateral component. Commands, queues and cargo are never replaced by contact. Coincident pairs get stable ID-based directions. Active constructors and interior construction occupants do not receive pressure; inside miners are absent from the grid.

The gather uses a frozen spatial grid: at most 16 entries per neighboring cell, nine cells, stable index/ID order. Every actor gathers, including actors omitted from the prefix, so dense same-owner cells are not frozen. This is bounded directed sampling, not exhaustive all-pairs and not exact momentum conservation. Foreign/mixed overflowing cells retain conservative envelopes; ordinary foreign bodies still block swept movement. Different-owner allies currently retain foreign-body treatment. The single-owner fast path skips body checks, not terrain checks. Scratch resets between worlds and is not authoritative replay state.

Ordinary movement, yielding and pressure validate radius-offset corners and short swept segments. Ordinary steering axis-slides when the radius clips a corner, fixing the center-only-path versus body-radius mismatch. Hard map/terrain/building occupancy is unchanged. Optional stable lateral yield remains, but its reciprocal peer wait was removed: with soft contact it locked crowds behind blocked sidesteps. Friendly circles can compress and pass in a one-tile corridor.

## Mine failure

Mine admission itself already allowed adjacent peons until `MinersPerMine` capacity. The demonstrated deadlock was `handleInMine` requiring an entirely empty exit tile: a friendly ring could trap all inside miners forever, so incoming miners correctly saw full capacity and never entered. Exit now prefers the original empty tile; only if the ring is full it may emerge at a terrain-legal, foreign-body-clear friendly ring center and push outward. It does not increase capacity, mint cargo early, erase successors, or admit a loaded worker. The interior→exit transition retains the existing discrete placement model; normal world movement does not teleport.

## Verification

`test_soft_bodies.nim` first failed the idle displacement assertion before the change. The occupied mine ring then independently failed repeated deposits before the exit fix. The choke test failed completion before removing reciprocal waiting. Logs are under `tmp/lvd-soft-bodies/`.

New regressions cover visible transient penetration, idle pushing/cargo preservation, capped displacement, 40 coincident friendly actors recovering with alternating clone hashes, hard-wall footprint safety, constructor anchoring, choke completion, and actual mine admission/full waiting/exit/deposit cycles. The full mine fixture produced `[5,5,5,5,5,5,1]` deposits: the last peon executes its Shift successor only after its single deposit. The occupied idle exit ring produced three deposits. Existing head-on miners produced `[8,8]`, and queued miners `[1,1]`; wood entrance workers `[4,4]` and queued workers `[1,1]`.

Updated former rigid-body assertions intentionally no longer demand zero penetration or an idle friend's tile remaining a movement wall. Enemy dense-cell test re-pins its fabricated stack every tick, because coincident bodies now actually disperse.

Native LvD suite and root suite pass, including formation arrivals/Shift/attack formation submissions, construction interior/interrupt/release, research movement, two-human packets and serialized replay hashes. Gameplay version is 32; archived clients remain required for older replays. No UI, graphics, network API or protocol changes. No browser tests, WASM builds, server changes, deployment or commit.

## Profiling provenance and limits

`tmp/lvd-soft-bodies/before/source.tar.gz` and `before/bench` freeze the dirty incoming source/binary before edits. Original before measurements remain `before/raw.json`. `final/raw.json` measures the final implementation. The identical existing harness runs 16 scenarios × five repetitions × 900 complete `tickWorld(nil)` calls; setup, overlap metrics and hashes remain outside the timer. Each artifact has 80 records and 900 raw samples per record, with matching hashes across its five repetitions.

The first before capture had conspicuously noisy timing (e.g. 300 crossing median 334.8 µs versus 152.3 µs in a later frozen-binary repeat). Therefore the table uses `before/repeat-raw.json`, a repeat of the **unchanged frozen executable**, not a rebuilt baseline. Both original and repeat are preserved; this is not a controlled-machine performance claim. `report.py` and `verified-summary.json` retain all three measurements and binary SHA256s. Separate phase diagnostics capture eighteen 50-tick chunks per workload, each below the 10,000-event cap, and verify exactly 900 tick spans. Phase times overlap nested work and must not be summed with their children.

The result is not a universal performance/throughput win: 100 crossing completion decreases 86→74; 300 choke 201→200. The 300 crossing/choke/opposing p95 regresses to about 2.55 ms, dominated by recurring full-budget A* searches toward the fixture's unchanged blocked mine destinations. Crossing search expansions grow 98,572→284,605; choke 222,015→441,610. Softer crowds now make different partial-route progress and request more searches. No budget or scenario was silently changed to conceal this. The existing blocked-goal cooldown remains. Further path-budget optimization is left explicit rather than conflating it with soft collision. 300 miners now deposit 1700 instead of zero, but individual fairness/saturation is not guaranteed.

Tables below use median of the five per-run medians/p95s, not browser timings. Miner `completed` is proximity to the fixture's unused movement goals, not mining throughput; use gold/deposits instead.

|Scenario|Units|Median µs B→F|p95 µs B→F|Complete B→F|Gold B→F|
|---|---:|---:|---:|---:|---:|
|opposing|2|2.2→2.2|2.4→2.9|2→2|0→0|
|opposing|20|4.2→4.4|30.6→34.5|20→20|0→0|
|opposing|100|44.4→21.9|100.7→82.5|83→98|0→0|
|opposing|300|154.8→174.1|273.1→2560.2|166→217|0→0|
|crossing|2|2.2→2.2|2.5→2.6|2→2|0→0|
|crossing|20|4.2→4.3|30.8→34.5|20→20|0→0|
|crossing|100|44.4→21.9|77.6→82.7|86→74|0→0|
|crossing|300|152.3→166.7|262.8→2549.3|183→195|0→0|
|choke|2|2.2→2.2|2.5→2.9|2→2|0→0|
|choke|20|4.1→4.4|31.6→32.2|20→20|0→0|
|choke|100|42.2→49.7|90.2→87.3|88→93|0→0|
|choke|300|156.4→193.3|267.0→2541.5|201→200|0→0|
|miners|2|2.4→2.5|20.1→20.1|0→0|200→200|
|miners|20|25.1→27.2|67.6→82.2|0→0|1700→2000|
|miners|100|80.2→72.1|233.3→245.3|0→0|2300→2500|
|miners|300|307.5→195.3|399.9→559.1|6→1|0→1700|

|Workload|Vision ms B→F|Path ms B→F|Units ms B→F|Separation ms B→F|Total ms B→F|
|---|---:|---:|---:|---:|---:|
|crossing-100|17.38→13.43|3.18→3.06|13.78→13.06|6.97→8.04|41.56→37.82|
|crossing-300|48.13→46.38|78.30→220.53|74.62→68.77|24.60→30.24|226.03→366.30|
|choke-100|15.60→17.67|23.34→23.27|14.28→15.32|8.05→10.98|61.53→67.49|
|choke-300|45.01→46.25|186.01→347.68|74.05→76.03|28.97→44.77|334.43→515.12|
|miners-100|24.82→25.50|42.85→40.57|25.36→15.19|22.33→21.13|115.61→102.66|
|miners-300|36.92→41.64|88.60→116.51|102.81→43.11|111.84→89.52|340.54→291.19|
