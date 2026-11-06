# Two real human LvD browser regression

Run from the repository root:

```sh
npm install --prefix /Users/me/.hermes/cache/scratch/lvd-browser-qa playwright pngjs
/Users/me/.hermes/cache/scratch/lvd-browser-qa/node_modules/.bin/playwright install chromium
node tests/browser_lvd_multiplayer.cjs
```

Dependencies are scratch-only; no project dependencies or production files change. Chromium defaults to **headed** because headless software rendering on this Mac produced multi-second frame stalls and screenshot timeouts. `LVD_QA_HEADLESS=1` opts in to headless. `LVD_QA_URL`, `LVD_QA_DEPS`, and `LVD_QA_OUT` override the target/dependency/artifact directories. The default target is the specified LAN standalone page with the loopback relay. HTTP cache is disabled in both contexts.

The test creates **two isolated browser contexts** and confirms distinct server participant IDs. All state-changing game actions use real pointer/key events: Home → Multiplayer → player name → explicitly Private Create Room → guest invite-field join → exactly two slots → each Play as you → Ready both → host Start → own worker left click → clear-ground right click. No bots, injected commands, direct relay clients, native APIs, server restarts or WASM builds are used. Browser closure disconnects only these synthetic clients; the test does not administratively delete rooms.

## Acceptance gates

1. Distinct QA host / QA guest, private room and authoritative Human seat ownership/readiness.
2. Both receive BeginMatch.
3. Each right click emits a decoded `SubmitCommand` containing LvD `ActionMove=1` for that participant's seat.
4. **Each actual selected worker moves.** On the uninstrumented fixed 1514×970 fresh-map camera, compare the yellow selection-outline centroid in a tightly bounded battlefield ROI before/after the right click. Require >15 pixels displacement, not merely a click, command, camera tick or changed full screenshot. Starting selection/ground points were inspected from real screenshots. The mouse stays away from scrolling edges and no camera actions are issued.
5. Each command is acknowledged by its participant/seat/sequence appearing in an authoritative TickPacket, or by a standalone CommandAck for retransmissions. New commands normally have no separate CommandAck.
6. Both participants report an equal hash for the **same match and same tick after both command acknowledgements**. Initial hash agreement alone is insufficient. No frame reports mismatches.

A failed move is a failing test even if all lobby/start steps passed. Both movement paths run before failure is reported. Each run writes `report.json` with decoded WS traffic, console, frame ticks, measured displacement and error, plus before/after/error PNGs. A 180-second watchdog bounds the run. The selection-image gate is specifically tied to the fresh default map and these controls; changes to default camera/map/art require re-inspection rather than silently loosening it.

Optional stronger read-only instrumentation, if the production owner chooses to supply it: `Module.polyworldLvdQA()` returns `{tick, humanPlayer, units:[{id,owner,alive,x,y,screen:{x,y},moveTarget:{x,y}}]}`. `x/y` are authoritative world positions; `screen` is a visible owned movable unit's CSS-pixel selection point, and `moveTarget` is a legal reachable ground CSS-pixel target. This path asserts >0.5 world-unit displacement at a later tick. The harness never mutates snapshots or invokes gameplay APIs. This export is **not required for the current screenshot-position RED** and does not exist in the observed bundle.

## Optional chat + diplomacy acceptance

After the production owner builds and serves the integrated client, run:

```sh
LVD_QA_SOCIAL=1 node tests/browser_lvd_multiplayer.cjs
# Explicit target example (use the actual rebuilt URL/relay):
LVD_QA_SOCIAL=1 LVD_QA_URL='http://10.10.11.114:4173/gameshowcase/games/light-vs-dark/play/?server=ws%3A%2F%2F127.0.0.1%3A9911%2Fws' node tests/browser_lvd_multiplayer.cjs
```

This preserves the existing movement gates, then adds six social commands through
real keyboard/pointer input, with a 300-second overall deadline:

1. Each human presses Enter, types `hello from QA host` / `hello from QA guest`,
   and presses Enter again. Decode the **variable-length binary Chat** envelope
   (category 0, signed sender, broadcast target -2, UTF-8 byte count and text), not
   the nine-int32 ReplayAction format. Assert exact text and own Human seat, with
   the two distinct named participants and no bots.
2. For **each** chat/action, require identical payload bytes, participant, seat,
   sequence, match and authoritative TickPacket tick on **both** browsers.
   A sent command or standalone CommandAck is insufficient. Wait until both
   displayed frame streams reach that tick, then require a matching same-match,
   same-tick ReportHash strictly after it.
3. Open Diplomacy on both peers. Host clicks Offer peace; guest clicks Accept.
   **Guest** then offers alliance and host accepts: changing the sender avoids
   the original peace sender's resend cooldown. Require `ActionDiplomacy=9`,
   the correct player/other fields, enum `2/4/3/4`, and offer IDs `0/1/0/2`.
   IDs 1 and 2 follow the fresh two-human match's `nextOfferId=1`; the test does
   not write them into the game or invoke any game API.
4. Save draft/feed screenshots for each chat and both peers' panel screenshots
   at At war, peace-offered, peace-accepted, alliance-offered, alliance-accepted,
   then the final unobscured feed. `report.social.events` records each receipt
   and checkpoint. PNGs are **visual review evidence**, not automated OCR or a
   claim that rendered labels, combat cessation or shared vision were asserted.

Coordinates are derived from `ui.nim:drawHumanCommunication` and
`chrome.nim:gameUiScale`, printed on social entry, and stored in the report.
The existing fixed viewport is 1514×970, deviceScaleFactor 1, fresh default Auto
HUD scale **0.5**. In CSS pixels: Diplomacy **(51,108.5)**; the first action on the
only other player's row **(638,374)**; Close **(899,332)**; panel bounds
**(592,322,330,326)**. Feed begins **(6,119)** with width 220. The same first-action
position holds Offer peace / incoming Accept / Offer alliance as state changes.
Do not reuse these as unscaled layout coordinates or silently loosen gates when
HUD layout/defaults change; inspect the saved screenshots and update the mapping.
The harness makes no production edits, build, server change, or direct mutation.

Offline harness checks (no browser/server and **not** integrated acceptance):

```sh
node --check tests/browser_lvd_multiplayer.cjs
node --check tests/browser_lvd_social.cjs
node --test tests/browser_lvd_social.test.cjs
```

`browser_lvd_social.cjs` isolates the decoder, observation checks and social UI
sequence. Its `.test.cjs` exercises UTF-8/non-aligned Chat lengths, malformed
payload rejection, unchanged action decoding, strict receipt matching and layout
coordinates. These are test fixtures, not fabricated live acceptance results.
**The social browser run is pending the rebuilt integrated client.** The earlier
movement GREEN below does not establish chat/diplomacy behavior.

## Captured before-fix RED

Artifacts: `/Users/me/.hermes/cache/scratch/lvd-browser-qa/run-2026-11-05T23-03-45-101Z/`

Observed run exited **1**. Both real humans completed lobby/start; neither worker moved after a real right click:

- Host participant 19, seat 0: ActionMove `[1,0,1000000000,16,28,0,0,0,0]`; selected-worker centroid `(757.0873786407767,461.81553398058253)` before and after; **0 pixels displacement**.
- Guest participant 20, seat 1: ActionMove `[1,1,1000000005,64,65,0,0,0,0]`; centroid `(756.8076256499133,460.19237435008665)` before and after; **0 pixels displacement**.
- Both latest received TickPacket and reported frame tick were **16**. Neither received CommandAck. Both emitted only the tick-0 hash `13808194775195298182`. This is initial agreement, **not movement agreement**.
- Visible workers remained at their initial positions; `host-selected.png` / `host-after-rightclick.png` and guest equivalents preserve the exact before/after evidence.

This isolated browser input → game ActionMove → WebSocket send. The confirmed production cause was bounded catch-up starvation after graphics initialization: live push stops beyond the client's 16-tick window, but the client exhausted its known edge without asking for newer history. Absence of a standalone CommandAck alone was not a bug; new commands are acknowledged within TickPacket payloads.

## Fixed-build GREEN

`run-2026-11-05T23-22-24-083Z` exited **0** against the LAN build. The real UI created six-character room `TT3XQ8`, both humans joined/readied, and the host started. Both selected workers moved more than 52 screen pixels after right-clicks. Their commands appeared in authoritative ticks 316 and 473. Both clients then reported identical hashes at ticks 480, 504, 528, 552, and 576, with zero frame mismatches. Artifacts live under `/Users/me/.hermes/cache/scratch/lvd-browser-qa/`.

The native companion `games/light_vs_dark/tests/test_two_human_movement.nim`, run with `-d:delayedHumanStartup`, deliberately reproduces the graphics-loading gap and asserts actual world displacement plus peer and serialized-replay hash equality through tick 96.
