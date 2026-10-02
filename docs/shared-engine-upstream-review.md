# Shared engine API review

Inventory date: October 3, 2026. Upstream baseline: `449ad184052567c30fa54c269ef45ff8c9e8e29b`.
This review extracts one CPU API; downstream integrations remain with their owners.

## Selected extraction

`tileTop(QuadLayer, x, z)` samples a supplied layer without replacing installed
pathing state. The existing `tileTop(layerIndex, x, z)` delegates to it. Packed
height units, integer operation order, and rounding toward negative infinity
are unchanged. This does not change terrain generation or rendering.

Cogcraft already uses this overload in
`native/src/cogcraft/polyworld_hollowdeep_client_frame.nim`:
`polyworldHollowdeepSurfaceHeight(source, tile)` validates effects, workshops,
sites, and gates against the supplied map before installing that map. Its
explicit layer access avoids consulting another map's global pathing context.
The overload is retained in Cogcraft's vendored `pathing.nim` at reviewed head
`422a1cb907e754367f7cd8fc7841baeaea7fe2c9`. Available history reaches the
`89b8ca7` boundary; that boundary is not claimed as the original authoring commit.

## Consumer and history inventory

Cogcraft's current `native/vendor/polyworld` is a tracked source tree, **not a
Git submodule**. `native/vendor/PROVENANCE.md` records upstream base
`49e6d49cfa661d941254557fda7eb5e851afe6b5` and local compatibility patches.
Review its game history and source diffs rather than treating the whole vendor
tree as a cherry-pickable engine branch.

Puzzle Pirates uses `vendor/polyworld` as a submodule. Its reviewed game head
and submodule record retain `f866e2fddabce9df909ad79de31fe2e2d73592b9`, already
reachable from the upstream baseline. Reviewed game head:
`b23c513b0ef5915f5c40b69e075ec48668b4044e`. Game history includes `be0501b0`
(follow main during dependency setup/CI) and `acf43526` (advance the pin).
`tools/deps.py` follows main unless `--locked` is supplied, so a checked-in pin
alone does not establish the engine used in a build. Its presentation clock,
motion, and vessel motion remain local game consumers. No vendor pins changed.

## Existing PRs and disposition

The open Polyworld PR census contains **49, 50, 51, 53, 89, 92**. GotA controls,
practice sessions, cast feedback, neural heads, and PR92's source qualification
runner remain author-owned. This extraction does not duplicate their files.

- [PR52](https://github.com/Metta-AI/polyworld/pull/52) is merged. Its
  `98d6814` commit is reachable from main; it changes GotA release discovery
  through Coworld summaries, not shared graphics or pathing APIs.
- [Cogcraft PR52](https://github.com/Metta-AI/coworld-of-cogcraft/pull/52)
  is also merged; it adds configurable client keybinds/settings and remains
  outside this shared engine API extraction.
- PR3's immutable pathing contexts, PR6's posed picking, PR40's character
  playback/attachments, and PR70's resource lifecycle are already merged.
  Review current implementations before replaying preserved relh branches.
- [PR61](https://github.com/Metta-AI/polyworld/pull/61) was explicitly closed
  because no Polyworld caller adopted the clock and Pirates retains a richer
  local clock. No standalone clock resubmission is justified here.
- PR62–66 (redraw scheduling, floating poses, custom toon shaders, grid motion,
  and WebGL context callbacks) are closed. Preserve their branches; any future
  extraction needs a current adopting consumer and the appropriate owner's
  runtime proof, not a wholesale vendor import.
- PR59's BASIC pause extension and PR60's game-bound host refactor were closed
  after PR55's trainer redesign removed their consumers. PR7's frustum query
  remains deferred without a measured bottleneck/caller. PR5/8's attachment
  and animation work is superseded by PR40; composed static scenes remain
  a separate future use case.

## Deferred surfaces and ownership

The four-host census found active game render, terrain, UI, camera, persistence,
and QA work. MBP also has the PR92 qualification worktree. Shared checkouts and
all those task worktrees remain untouched; this PR uses a fresh Git worktree.
No repository worktree helper or nested AGENTS/LESSONS file was found in the
upstream tree. Global synchronization was attempted, then the explicit
fetch/isolation instruction preserved the divergent local main.

Cogcraft's caller-supplied crossing neighbors, topology cache changes, and
explicit-source ray queries need separate integration review. Crossing edges
must preserve admissible A* heuristics, callback ordering, tie breaks, and
smoothing semantics; copying the entire pathing fork would also import unrelated
cache and renderer-facing behavior. Toon/unlit/shadow changes, terrain paint,
wind, water, cutout mips, character crossfades, and HUD/input patches stay with
their active owners. This document is the source handoff, not an acceptance
claim for those patches.

## Proof and remaining gaps

The CPU `test_tile_paths` contract checks every possible four-corner sum
(-131072 through 131068), supplied-layer indexing, unchanged installed state,
negative rounding, extrema, and compatibility with the indexed API. The
existing `test_pathing` contract covers context reuse, path smoothing, occupancy,
and mirrored tie ordering. Full games and browser/graphics acceptance are
outside this proof. Private compiler logs and source snapshots are retained
outside Git. Installed proof dependencies are recorded there; no locked-cohort
or graphics-performance claim follows from these small CPU checks.

Cogcraft main continued advancing during the inventory; the reviewed snapshot
is pinned above. A later API read reported `0dceefde`, but retrieving its source
timed out. Recheck later downstream commits before adopting this extraction.

Richard reviews the unmerged PR. Downstream adoption, broader vendor history
reconstruction, and runtime proofs for deferred surfaces remain open.
