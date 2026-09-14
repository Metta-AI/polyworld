# GotA tournaments

The runner, scoring, persistence, report generation, and tests are Nim. The small
browser component is also written in Nim and compiled to JavaScript. HTML embeds
that generated script, Rubik fonts, the GotA logo, and the original ladder icons.

Install the repository's Nim dependencies, including `curly` and `yaml`, and use
an existing `softmax login`. The runner reads `~/.softmax/credentials.yaml`
directly and calls the Softmax API through Curly. No Python process is used.

Build from the Polyworld repository root:

```sh
nim r -o:tmp/gota/tools/build_tournament examples/gods_of_the_arena/tools/build_tournament.nim
```

Start a run, then repeat its name to resume:

```sh
tmp/gota/tools/tournament --run comparison --games 1000
tmp/gota/tools/tournament --run comparison
```

The first command freezes the Competition division's top ten active entrants,
policy versions, game release, configuration, and seeded schedule. It schedules
500 mixed and 500 mono games. All output goes to
`tmp/gota/tournaments/comparison/`. Open `report.html` during the run; it becomes
the final report. Refresh the page manually to see new results. The page works
offline and can be moved to another folder.
Assets come from the sibling `polyworld_data` checkout, or `POLYWORLD_DATA`.

Press Ctrl+C to pause. The current response and file replacement finish, then the
runner writes the paused report. Already submitted games continue remotely.
Restarting reconciles their results before scheduling new games. Keep one runner
per run directory. There is no local lock or database.

`run.json` and `games/*.json` are authoritative. Each game stores submission
attempts, pinned payloads, idempotency keys, remote IDs/status, and original result
artifacts. Atomic sibling-file replacements flush the file and its directory.
Abandoned `.tmp` files are ignored. Summaries, CSV exports, and HTML can be rebuilt:

```sh
tmp/gota/tools/tournament --run comparison --report-only
```

`--retry-failed` records a replacement attempt for the same scheduled game. Failed
games remain visible and unscored. Completed games count once. Explicit changes
to frozen settings fail on resume; operational `--concurrency` may change.

Options include `--top`, `--format mixed|mono|both`, `--league`, `--division`,
`--seed`, `--check-every`, `--concurrency`, and `--server`. Defaults are top 10,
both formats, 10 games per stability checkpoint, and four remote requests.
`--games` is the total across formats; mixed receives an odd remainder.

## Submission recovery

GotA release `2026.9.14.2` publishes the original ten-seat `total_xp` result array
while retaining binary victory scores. The runner submits direct XP requests
through the existing API and persists their returned IDs before collecting
results. Every attempt includes a unique request key in its purpose note.

If a POST response is lost, restart searches the current requester's history for
that exact note and verifies the frozen game configuration before attaching the
original request. It never repeats an uncertain POST. If no matching request is
visible, it pauses; another restart checks again. An interrupted attempt that
never reached the server needs manual reconciliation before retrying. This
conservative recovery works without a backend deployment, but fully automatic
recovery in that last ambiguous case still requires server-side deduplication.

## Scoring and stability

Win/loss is average binary team victory, with no MMR adjustment. Score is lifetime
XP minus 100 per simulated minute, including fractional minutes and negative
scores. Glory gives winners that same time-adjusted XP and everyone else zero.
Score keeps losing players' time-adjusted XP. Neither ladder clamps negative
values. Mono policies average their five heroes first. Timeouts score zero for
win/loss and glory, while Score retains their XP minus time.

Each format shares its games across all three ladders. Every checkpoint compares
cumulative displayed ranks. `stabilityScore` counts policies whose ranks changed;
a two-policy swap counts as two. `stabilityRun` counts consecutive unchanged
comparisons. The first checkpoint establishes a baseline. Partial final batches
update standings without advancing stability. Ties are marked and ordered by
frozen policy-version ID; unsampled policies have no rank. Stability never ends
the requested game count.

Out-of-order results are saved immediately. Standings advance through each
format's completed schedule prefix so interruptions cannot change checkpoints.
The report distinguishes completed games from those included in standings.

## Checks

Build first, then run the Nim checks and fixture tests:

```sh
nim check examples/gods_of_the_arena/tools/test_tournament.nim
nim r -o:tmp/gota/tools/test_tournament examples/gods_of_the_arena/tools/test_tournament.nim
```

The tests include scoring, balanced sampling, ties, stability resets, failed-game
retries, atomic replacement failures, and subprocess SIGINT/SIGKILL recovery after
remote acceptance. Fixture requests are persisted to JSON and never sent to
Softmax. Test output is under `tmp/gota/tournament-tests/`.
