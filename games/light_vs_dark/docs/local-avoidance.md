# Local traffic: measured candidate (gameplay 29)

> Historical first candidate. The gameplay-30 follow-up, profiler-cap correction,
> full three-revision comparison and remaining limits are in
> [local-avoidance-followup.md](local-avoidance-followup.md). The adjacent results
> table now shows baseline / incoming candidate / final; figures below describe
> the original candidate, not the final optimization.

## What actually existed

LvD already had Q16.16 continuous circular bodies (radius 0.22 tiles), not exclusive tile occupancy. `occupancy` is a one-ID-per-tile hint for spawning, building placement, resource approaches and route costs. Ordinary movement and circle separation were separate stages: separation could undo every forward step without incrementing the movement blocked counter. Soldiers lacked workers' persistent lateral-yield recovery. This reproduces with two friendly opposing soldiers and with perpendicular crossing soldiers.

The route implementation is **Pathy terrain A*** (`fillTilePath`, eight neighbors, dynamic walkability and occupied-tile costs), not JPS+. Pathy also has a separate precomputed JPS+ implementation, but that is not what this terrain API calls. This change deliberately retains the existing bounded global route/search and corner-aware string pulling. It does not claim to have switched to JPS+ or reproduce Dota internals.

## Candidate

- A derived one-tile spatial grid replaces all-pairs circle separation, all-pairs passing detection and all-units scans at each sampled yield point. Rebuild before units and separation; ascending IDs within row-major neighboring buckets. Only touched heads are reset. Scratch is rebuilt for each world and is not hashed authoritative state.
- Nine neighboring buckets, at most 16 occupants per bucket: **144 inspected entries per query**, independent of total army size. Normal density is much lower. A dense bucket retains its lowest-ID prefix, so saturation can leave overlaps/stalls; this is a bounded-work policy, not a crowd-capacity guarantee.
- Existing persistent, fixed-point, higher-ID lateral yield now applies to same-owner combat units, including crossing headings. Workers retain their narrower head-on trigger and resource recovery. The selected side persists for up to three seconds; an obstructed side can try the other side. No yield through enemies or unrelated owners. Body radii and melee ranges remain unchanged.
- Combat units resume the existing route after a yield, rather than requesting a global search. Workers retain existing resource-approach repathing. This is not one route recomputation per moving unit.
- Yield sweeps and separation corrections check footprint corners and diagonal transitions against terrain/buildings. Interior builders receive no general walkability exception; existing construction lifecycle stays intact.
- This is bounded local **yield steering plus soft positional separation**, not velocity-obstacle/RVO steering and not unrestricted ghosting. It does not solve a physically blocked narrow corridor or guarantee completion in dense crowds.

## Reproduction and artifacts

Durable local evidence: `tmp/lvd-local-avoidance/` (ignored, not published). Initial scratch copy: `/Users/me/.hermes/cache/scratch/lvd-local-avoidance/`.

Before production edits: `baseline-source.tar.gz`, `baseline-sha256.json`, `baseline-status.txt`, `environment.txt`, frozen `baseline` executable and `baseline-binary.sha256`. Candidate source archive/hash list and executable are beside them. Baseline includes the preexisting dirty construction/diplomacy changes; unrelated work was not reverted.

Apple M4 Pro, macOS 15.1.1 arm64; Nim 2.2.10, Apple clang 16.0.0. Flags: `nim c -d:release -d:headless --opt:speed`, repo config enabled ORC, threads, `nimTypeNames`, `flatty64`, `bassyNative`. Full build logs retained.

```sh
nim c -d:release -d:headless --opt:speed --nimcache:<isolated-cache> --out:<binary> games/light_vs_dark/tests/bench_local_avoidance.nim
<binary> <output.json> 900 5
python3 games/light_vs_dark/tests/summarize_local_avoidance.py tmp/lvd-local-avoidance
```

`trafficfixture.nim`: fixed seed 73021, flat 80×80 controlled terrain; 2/20/100/300 same-owner units; opposing flows, perpendicular crossing, seven-tile choke, one real mine/depot. 900 ticks, five runs per workload, 80 records per revision. `tickWorld(nil)` includes vision/pathfinding/buildings/cleanup but no policies, networking or rendering. Setup, timers' result serialization, pair-overlap sampling, progress metrics and hashing are outside timing. Raw per-tick nanoseconds, hashes, displacement, stalls, overlaps, path work and real gold deposits are in `before.json` / `after.json`; CSV and machine-readable aggregates in `summary.csv` / `summary.json`. `before-confirm.json` reruns the frozen baseline after the candidate measurements.

Table uses median across five run medians and median across five run p95s, not pooled quantiles. Completion is distance ≤0.4 tiles from the assigned destination; for miners that field is not meaningful—use deposited gold. Stalls count unchanged positions while a goal exists (includes legitimate turns/yields). Overlaps are sampled every 30 ticks at radius sum minus 0.01 tiles. These are diagnostic metrics, not proofs of zero overlap.

## Findings and limits

All 2-unit and 20-unit move/cross/choke fixtures finish in the candidate. The baseline finishes neither 2-unit participant and zero of 20 opposing units. At 100 opposing units completion rises 0→83; at 300, 92→167. Mining gold is 200→200, 1600→1700 and 1800→2300 for 2/20/100 miners. **300 miners targeting one mine remain congested with zero deposits in both versions.**

The candidate is **not a universal performance win**. 300-unit median ticks improve substantially, but 100-unit median ticks get worse, and 300-unit crossing/choke p95 rises to about 2.5 ms. Moving formerly jammed actors causes visibility rebuilds and additional partial route retries; the old jammed simulation can cheaply skip unchanged vision. The existing 15-search/3000-expansion-per-search path budget is unchanged. Do not describe this candidate as having met a no-regression performance gate.

Profiler captures are separate from timing runs: 300 units ×300 ticks, `profile-before/after-{opposing,miners}.json`, aggregates `profile-summary.json`. Opposing separation cumulative time falls 39.53→9.97 ms; miner unit-update time 145.31→25.48 ms and separation 41.19→19.76 ms. Opposing total 226.83→192.62 ms; miner total 320.90→177.47 ms. Profiles are instrumented and cannot substitute for ordinary tick latency distributions.

Iteration evidence retained (`candidate1/2/3.json`): initial full-grid clearing raised tiny-workload cost; touched-bucket clearing removed that overhead. Profiling showed yield-finish path searches dominated, so combat yields now resume their cached route. Worker route recovery was retained after deposit throughput declined when it was removed. Remaining p95/path and visibility costs are disclosed rather than hidden by changing benchmark timing scope.

## Verification

`test_local_avoidance.nim` first failed on actual two-soldier opposing completion (`red.log`), then passed: opposing/crossing completion, per-tick cloned-peer hashes, bounded dense bucket and reset, enemy-owner body blocking, attack-move crossing. Full `games/light_vs_dark/tests/tests.nim` passed (`full-tests-final.log`), including miners' passing/cargo/queued successor/deposit behavior, blocked/unreachable paths, formations/order queues, construction inside-shell release, multiplayer packet peers and serialized replay hashes. Each workload's five final state hashes agree.

Gameplay bumped 28→29; old replay versions require archived clients. No browser tests, WASM build, server changes or commit were performed. Existing native peer/replay tests passed, but no new browser or deployed-runtime claim is made.

See the adjacent measured table, or `tmp/lvd-local-avoidance/table.md` for the complete 16 workload timing/completion table.
