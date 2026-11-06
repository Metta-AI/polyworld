# Follow-up optimization (gameplay 30)

The incoming candidate is called **candidate1** in the new three-way comparison, not the older scratch file `candidate1.json` from its development. Its exact frozen binary is `candidate-initial`; its original raw results are also preserved as `candidate-initial.json`. Nothing overwrites the original baseline/after artifacts.

## Root cause, not a cheaper workload

The ordinary benchmark is unchanged: same source, seed, scenarios, 2/20/100/300 units, 900 ticks, five runs, full `tickWorld(nil)` timing. Setup, metrics, serialization and final hashing remain outside timing. New raw records are `baseline-final-comparison.json`, `initial-final-comparison.json`, and `final.json` in `tmp/lvd-local-avoidance/`; each contains 80 records and 900 raw nanosecond samples per record. Every workload's five hashes agree. `compare_local_avoidance.py` checks counts, samples and hashes before generating the adjacent results table and `three-way-summary.json`.

The worst recurring searches were **terrain-blocked destinations inside the fixture's actual neutral mine footprint**, not generic crowd replans. For example unit 1000000206 at (58,42) repeatedly searched for (58,41), exhausted 3000 expansions, then retried seven ticks later. Crossing had 74 full-budget searches. These coordinates are unchanged: we did not remove the mine or repair the benchmark to improve numbers. Pathy's eight-neighbor terrain API is integer A*, with walkability, occupied-tile entry penalties, corner restrictions, reusable stamped search arrays/heap, and partial routes. Its separate JPS+ API is not used and has not been substituted. A single exhausted search cost about 2.3ms; a mere per-tick search-count cap would not cure that floor.

Vision was also real extra work: candidate traffic kept more sources active/moving and invalidated the old all-source repaint more often. Global A* already reuses storage; the small returned smoothing sequence was not the measured dominant allocation source and was left alone.

## Targeted changes

- When an exhausted partial route's destination remains **terrain/building blocked**, preserve the goal, partial progress and queued intent, but retain a 30-tick retry cooldown instead of retrying every seven ticks. Open destinations and worker resource-ring recovery retain their existing cadence. Replacement orders clear cooldown normally. This uses already-hashed `repathCooldown`; no wall-clock scheduler or hidden persistent gameplay state was added. Per-search expansion and per-tick search-count budgets are unchanged.
- Reuse the shared exact `VisionCache` implementation, with sparse active-source footprints and full source enumeration. The ray kernel, visibility range, occluders and exploration rules are unchanged. Per-world derived caches avoid alternating-world pollution, invalidate on terrain/blocker changes, and remain absent from authoritative hashes. Sparse profiles were chosen over dense per-tile/per-radius masks to avoid multiplying large-map memory by every radius and player. This does still allocate source footprints when tiles change; it is not an allocation-free promise. The cache-only trial matched all 16 scenario final hashes of its uncached counterpart.
- Dense local buckets still inspect at most 16 entries each, but now expose overflow. Ordinary steering, yield sweeps and separation corrections conservatively reject positions within the full overflowing-cell envelope expanded by body radii. Omitted actors are no longer presumed empty space. This is intentionally conservative: an already-overfull bucket can remain frozen, and it does not guarantee depenetration. Terrain/corner checks remain intact.
- Gameplay version 29→30 for changed retry/overflow behavior. Archived clients are required for older replay versions. Peer/serialized replay agreement, not identical trajectories across gameplay versions, is the deterministic contract.

## Measured result

See `local-avoidance-results.md` for all 16 rows. Key p95s (baseline / candidate1 / final):

- 300 crossing: **389 / 2616 / 264 µs**; completion **124 / 183 / 183**.
- 300 choke: **392 / 2641 / 253 µs**; completion **175 / 202 / 201**.
- 100 crossing: median **30.5 / 82.9 / 45.6 µs**, p95 **101 / 106.5 / 80.8 µs**, completion **79 / 86 / 86**.
- 100 opposing: median **36.3 / 81.5 / 46.7 µs**; completion **0 / 83 / 83**.
- 300 opposing: completion **92 / 167 / 166**; p95 **395 / 341 / 264 µs**.
- Gold remains **200 / 1700 / 2300** for final 2/20/100 miners versus baseline **200 / 1600 / 1800**. 300 miners at one mine still deposit **zero** in every revision.

This meets the severe p95 reduction objective but **not a literal zero-completion-loss gate**: two 300-unit scenarios finish one fewer actor by tick 900 than candidate1. The broad movement improvement is retained; 100-unit medians still exceed the often-stalled baseline. Do not label it a universal no-regression result.

## Phase evidence and profiler correction

`diagnose_local_avoidance.nim` captures the same 900-tick fixture separately from latency measurements. It counts goal-active unit-ticks and actual post-separation position-changing unit-ticks, and records path work. Crucially Fluffy has a **10,000-event cap**: the added nested cache spans overflowed a single trace, and the original frozen baseline profiler executable also ignored the new count/tick arguments and always captured 300 ticks. Those files are not used for these totals. Both archived revisions were rebuilt with the same diagnostic driver; captures are split into eighteen 50-tick chunks, checked below the event cap and for exactly 900 tick spans. `three-way-profiles.json` contains complete totals.

Milliseconds accumulated over 900 ticks (B / C / F):

|Workload|Vision|Path|Units including yields|Separation|Total|
|---|---:|---:|---:|---:|---:|
|100 crossing|20.44 / 31.48 / 18.10|3.12 / 3.22 / 3.11|11.76 / 13.18 / 14.32|15.58 / 6.77 / 7.06|51.12 / 54.89 / 42.85|
|300 crossing|58.70 / 112.83 / 48.53|84.48 / 196.77 / 80.13|74.48 / 72.33 / 75.68|119.48 / 23.92 / 24.10|337.51 / 406.23 / 228.81|
|300 choke|68.26 / 106.38 / 48.25|186.15 / 310.16 / 189.65|77.21 / 73.59 / 79.10|118.44 / 28.08 / 30.07|450.45 / 518.59 / 347.47|

300 crossing active unit-ticks are 107791 / 138668 / 138694; actual moving unit-ticks 111312 / 120074 / 120074. Total instrumented µs per active unit-tick are 3.13 / 2.93 / 1.65; per moving unit-tick 3.03 / 3.38 / 1.91. An idle actor can be shoved, so moving counts need not be below goal-active counts. Normalization is descriptive, not a replacement for total latency or completion. Crossing searches/expansions fall from candidate1 469/248694 to final 344/98572. Choke falls 441/381047→344/222015. Initial search bursts and individual 3000-expansion failures remain possible; p95 is not a maximum-tick guarantee.

## Verification

- Retry regression first failed with 99 searches; passes with fewer than 30 and later replacement completion.
- Overflow-envelope regression first failed; now passes bounded bucket/reset, omitted enemy bodies, opposing/crossing completion and attack move.
- Exact per-cell vision comparison against the original ray painter passes moving sources, changed blockers, death, cloning and alternating peers. Existing full suite covers diplomacy/alliance vision and worker mine transitions.
- `nim c -r -d:headless games/light_vs_dark/tests/tests.nim`: **Game tests passed**. Includes cargo/deposits/Shift, unreachable paths, movement, construction, two-human packet movement, network queues and serialized replay hashes.
- `nim c -r tests/tests.nim`: **All tests passed**, including broader movement, cargo/construction, vision, relay/network and replay tests. Logs retained as `suite-final.log` and `root-suite.log`.

No browser, WASM, server change, deployment or commit. Performance is native evidence only.
