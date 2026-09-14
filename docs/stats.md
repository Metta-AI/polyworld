# Shared match statistics

The three viewers use `src/polyworld/stats.nim`. The overlay reuses the
existing panel, portrait well, label, bar, and faction colors. Sparklines
are drawn by `chrome.nim` using the existing triangle renderer.

Hold TAB to show the table temporarily. The Stats button beside the camera
control toggles it independently. Releasing TAB preserves the button's
selection. Losing focus clears held-key visibility. The simulation, camera,
HUD, and transport keep updating and drawing behind the table. Mouse input
inside the table does not reach the world or covered HUD controls.

The window fits its actual roster and scrolls when necessary. It has no
game title or footer. Gota keeps blue and red kill totals above Players.

Rows rank by gold, highest first. Gota sorts within its blue and red teams.
Light vs Dark sorts by gold gathered across all players. Adventure sorts by
carried plus banked gold, so depositing loot preserves its value in the
ranking. Ties use the original player seat. Live and final tables use the
same ordering, and each hero keeps its own metrics and chart history.

| Game | Rows | Columns after portrait and name |
| --- | --- | --- |
| Gods of the Arena | All heroes, grouped by team | Level, gold earned with trend, kills with stepped trend, deaths, assists, CPU%, APM |
| Light vs Dark | Two commanders | Gold gathered with trend, army value with trend, unit kills, unit losses, CPU%, APM |
| Call to Adventure | Four party members | Total gold with trend, damage with trend, healing, monster kills, CPU%, APM |

Gold earned excludes starting gold and counts combat rewards. An assist
requires damage to an enemy hero within ten seconds before its death.
Army value is the gold cost of surviving combat units, excluding workers.
Damage and healing count effective health changes, excluding overkill and
overhealing. Adventure's Gold column and trend combine carried and banked
gold. Fallen adventurers retain only their banked gold in this total.
Adventure winners follow the existing surviving-returner rules, including
ties.

CPU% is consumed BASIC instructions divided by the allotted instruction
budget for decisions in the current simulation second. It is unavailable
for a human player without a VM. APM counts accepted gameplay commands.
Rejected commands, VM operations, and queries do not contribute. Playback
reapplies recorded actions through the same validators to recover that
count. Live APM uses a rolling minute in one-second buckets, normalized over
elapsed time for matches shorter than a minute. Results use lifetime
averages for both.

Completion automatically opens the same table with victory, defeat, draw,
or hero outcome labels. The final standings remain readable if the
transport automatically loops. Dismissing the table or using a playback
control returns the overlay to the displayed simulation tick. This does
not alter playback, speed, or looping preferences.

Combat counters and assist attribution belong to simulation state. They
are cloned with checkpoints and included in simulation hashes.
Only CPU samples and the final CPU average are stored in
`ReplayData.metrics`. Each sample stores one 32-bit integer per player.
APM, gameplay counters, and charts are reconstructed during resimulation.
`loadReplay(path)` returns the entire replay without an output parameter or
separate trailer. Each client accepts only its exact gameplay version.
Older recordings use the matching archived client stored on the server.
The current client does not migrate replay payloads or emulate older rules.

History begins at tick zero and samples once per simulation second, plus
the final or saved tick. At 4,096 samples it coarsens the history while
retaining endpoints. Charts share a time axis and metric scale across
players, omit future samples when seeking, and retain per-pixel extrema.
Replay CPU uses the latest recorded sample at or before the shown tick.
APM uses reconstructed history when seeking, and revisiting a completed
tick does not count commands again. Histories and decoded CPU samples have
explicit size limits.

For viewer screenshots, build with `-d:takeScreenshot` and set
`SHOW_STATS=1` to include the overlay. Normal builds use TAB and the button.
