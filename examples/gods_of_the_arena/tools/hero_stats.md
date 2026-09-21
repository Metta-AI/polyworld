# GOTA hero statistics

Download the last 24 hours of completed league games and reconstruct each
hero's final statistics by playing the recorded actions through the simulator.
The tool only reads public Softmax endpoints. It does not submit matches or
require a login.

From the repository root:

```sh
nim c -d:headless -o:tmp/gota/hero_stats \
  examples/gods_of_the_arena/tools/hero_stats.nim
tmp/gota/hero_stats --hours 24 --jobs 4
```

When the sibling `polyworld-buff` checkout is present, the same command also
updates `polyworld-buff/GOTA/heros/index.html` and its `hero_assets/` folder.
The website's `GOTA/site.css` and `tools/layouts.nim` supply the exact shared
styling and navigation. The local report receives that styling too, with
the stylesheet copied beside its fonts and images. No server is needed.
Commit and push the website checkout to publish the refreshed page.

Use `--site /path/to/polyworld-buff` or set `POLYWORLD_BUFF` for another
checkout location. Use `--no-site` to generate only local reports. If no
sibling checkout is available, the tool generates the standalone template.

Use a named directory to resume downloads and reuse verified results:

```sh
tmp/gota/hero_stats --out tmp/gota/hero-stats/balance-check --hours 24
tmp/gota/hero_stats --out tmp/gota/hero-stats/balance-check --jobs 6
```

The first run freezes the completion window in `manifest.json`. Resuming uses
that original window. Choose a new output directory for a fresh last 24 hours.
`--end 2026-09-14T18:00:00Z` selects an explicit exclusive end time. The start is
inclusive. Game completion time determines membership, including games in a
round that started before the window.

Regenerate exports from downloaded results without network access:

```sh
tmp/gota/hero_stats --out tmp/gota/hero-stats/balance-check --offline
```

To update HTML alone without compiling the game simulator:

```sh
nim r -o:tmp/gota/hero_report \
  examples/gods_of_the_arena/tools/hero_report.nim \
  tmp/gota/hero-stats/balance-check
```

This command also updates the website when its checkout is present. It
accepts `--site CHECKOUT` and `--no-site`, just like the full analyzer.

The website report lives in `polyworld-buff/GOTA/heros/index.html`. To update
that page from saved results, use the website checkout:

```sh
nim r -o:tmp/gota/hero_report \
  examples/gods_of_the_arena/tools/hero_report.nim \
  tmp/gota/hero-stats/balance-check \
  --site ../polyworld-buff
```

Open `../polyworld-buff/GOTA/heros/index.html` directly in a browser. Generated
HTML and assets are not kept beside the tool source in this repository.
The analysis directory also contains `report.html` and `hero_assets/` for
offline use. Keep those together when copying a standalone report.
Asset paths are relative, so the report works under a project subdirectory.
Local reports link to the published game guide and standings.
No server is required to view it locally. Hero data is embedded in the HTML
to avoid local-file restrictions on fetching JSON. Fonts, portraits, and
icons are ordinary files in `hero_assets/`.

Edit `hero_stats_template.html` to change the layout, then regenerate the
report. The template is source for the generator, not the page to open.
Shared site styling comes from `polyworld-buff/GOTA/site.css` when the
website checkout is selected.

Each hero profile includes a spell-level reference generated directly from
`content.nim`: every learnable rank, its required hero level, effect amount,
mana cost, charge capacity, and cooldowns. Spell icons travel with the
report's other assets. These are current tuning values, independent of the
historical match-version filter. Updating spell tuning and regenerating the
report updates the reference without editing the HTML by hand.

Outputs include:

- `report.html` and `hero_assets/`: a static page with GOTA portraits, fonts,
  and aggregate hero data. Open it directly in a browser. No server,
  installation, or network connection is required. It includes sortable
  hero statistics, version and faction filters, hero profiles, level
  distributions, and an embedded CSV export. It contains no individual player
  or match records.
- `report.md`: hero averages, per-release tables, and interpretation notes.
- `heroes.csv`: games, appearances, wins, losses, draws, win rate, average
  level, lifetime XP, kills, deaths, assists, gold earned, unspent gold,
  per-minute rates, KDA ratio, and distinct player and policy counts.
- `heroes_by_version.csv`: the same statistics separated by game release.
- `appearances.csv`: one auditable row per hero per match, with source URLs.
- `summary.json`: counts, descriptive confidence intervals, and exclusions.
- `manifest.json` and `matches/`: frozen league metadata and seat scores.
- `replays/`: original replay downloads, which may contain gzip data.
- `stats/`: final reconstructed statistics and replay/executable SHA-1 hashes
  used for local cache identity, not security or authenticity verification.

Every included game must match all recorded simulation hashes and all hosted
seat scores. Both plain and gzip replay downloads are accepted. A modified
replay or a rebuilt executable invalidates its cached analysis on resume.
Unsupported versions, divergent state, and missing artifacts are listed as
exclusions, not added as zero-valued games. Exit status 2 means coverage is
incomplete; status 1 indicates an operational error. Partial results remain
available for another run.

Concurrent workers are separate processes because terrain and pathing use
global state. `--jobs` bounds both replay downloads and local simulations.

Win rate includes time-limit draws as non-wins. Averages are end-of-game
values per hero appearance. XP is cumulative earned XP. Gold earned excludes
the initial 150 gold and includes rewards already spent in the shop. K/D/A
are separate averages; the exported KDA ratio is total kills plus assists
divided by total deaths, with a denominator of one when there are no deaths.

Current GOTA league lineups are fixed by faction. All five heroes in a faction
share its match outcomes, so faction win rate cannot isolate an individual
hero's effect. Use the individual economy and combat statistics as leads for
controlled balance tests. Reported player counts and version splits help
expose other confounders. Damage and healing totals are not instrumented in
these GOTA versions, so the tool does not report them as zero.

Run the focused regression tests:

```sh
nim check -d:headless examples/gods_of_the_arena/tools/hero_stats.nim
nim r -d:headless -o:tmp/gota/test_hero_stats tests/test_gota_hero_stats.nim
nim r -o:tmp/gota/test_hero_report tests/test_gota_hero_report.nim
```
