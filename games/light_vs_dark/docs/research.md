# Passive research (gameplay 31)

All players and both factions have the same four passive research categories.
These are multiplayer technology rules, **not campaign-level unlocks**.

| Category | Completed producer | Effect per completed tier |
|---|---|---|
| Keenflight Arrows | Lumber Mill | Archer +2 piercing damage |
| Tempered Edges | Blacksmith | Soldier (Footman), Knight, Cleric and Mage (Conjurer) +2 basic damage |
| Runed Plating | Blacksmith | Every mobile unit kind +2 armor, including workers, casters, elementals and siege; never buildings |
| Windrunner Training | Stables | Knight movement +10% of base speed |

Each category has exactly three sequential tiers. Effects apply dynamically to
existing and future units; there is no per-unit upgrade stamp or HP modification.
Speed is additive (110%, 120%, 130%), not compounded. It multiplies the existing
Q16.16 base tiles-per-tick speed, then divides by 100 using fixed-point arithmetic;
whole `stepTicks` remain the base content value and must not be used to display the
effective upgraded speed. Armor reduces basic damage, not piercing or splash.

## Prices and duration

The same explicit, escalating ladder applies to every category:

| Target tier | Gold | Wood | Seconds | Simulation duration |
|---|---:|---:|---:|---|
| 1 | 600 | 200 | 20 | `20 * TickRate` |
| 2 | 900 | 400 | 30 | `30 * TickRate` |
| 3 | 1200 | 600 | 40 | `40 * TickRate` |

This is a deliberately chosen LvD balance ladder, not a claim about historical
Warcraft pricing. It makes higher tiers a progressively larger investment while
allowing a completed producer and a normal economy to unlock the first tier.

## Acceptance, lifecycle and cancellation

- Acting player must be valid and undefeated in a running match.
- Producer must be living, complete, owned, and the matching building kind.
- Its ordinary completed-building prerequisites must currently exist: Barracks
  for Blacksmith/Stables; no extra prerequisite for Lumber Mill.
- Resources must cover the next tier; pay once when the command is accepted.
- Only the next tier is requested. The command never supplies a target tier.
- One active research per building and no duplicate category anywhere for that
  player. Different categories can progress in separate eligible buildings.
- The producer must have no training queue. Current research producers do not
  train units, so this imposes no new ordinary unit-training restriction.
- On the final countdown tick, the target tier becomes player-wide permanent
  state. Units have already advanced that tick; they use the new bonus next tick.
- `Cancel` on a researching building clears research immediately. Destruction
  also clears it immediately. Neither refunds research costs nor grants a partial
  tier. Destroying prerequisite structures after acceptance does not pause work.
- Destroying the producer after completion never removes completed research.

## Deterministic integration

`content.nim` owns category identifiers, producer/name lookup, the cost ladder and
hashed tuning constants. `passiveresearch.nim` contains pure effective-stat and
fixed-point speed functions. `sim.nim` owns validation, countdown, player tiers,
combat/movement integration, cancellation and hashes. Arrays/scalars participate
in existing clone/restore semantics; research adds no global mutable simulation
state. No renderer, icon substitution or speculative spell system is involved.

UI submits `controls.queueResearch(player, buildingId, kind)` and reads
`canResearch`, `researchLevel`, `researchInProgress`, `unitStats` and
`unitMoveSpeed`. A building's `researchTicks > 0` denotes active work;
`researchTotal` is its original duration and `researchLevel` its target tier.

Action 10 (`ActionResearch`) uses the existing opaque action envelope:
`entityId = producer`, `first = ResearchKind ordinal`; `second`, `third`, offset
and append must remain zero/false. Network intent does not mutate the local world.
Accepted commands use the same recording/authoritative replay path as training.
Gameplay version is **31**, replay format remains **6**, network protocol remains
**3**. Old gameplay tapes require archived clients; shared relay code is unchanged.

Spells are a separate follow-up phase. Keep passive modifiers separate from
future spell unlocks, mana/cooldowns and casting commands; no speculative fields,
spell opcodes or faction spell trees have been added here.

## Verification

`tests/test_research.nim` covers sequential tiers, affordability and prerequisites,
category/building locks, cancellation/destruction, both-faction stat coverage,
actual combat and movement, hashing and clone/restore, human command queue,
submission codec, peer tick parity, serialized action replay and invalid payloads.
`tests/test_research_network.nim` additionally exercises two human controls through
an in-process real Relay, ordinary authoritative packets, same-tick duplicate
rejection, paid-once accounting, completion and serialized replay. Its registered
opening-building fixture is intentional; it does not claim live browser coverage.
Run it and `games/light_vs_dark/tests/tests.nim` headlessly; run root
`tests/tests.nim` without `-d:headless` (its CLI expectations require that).
UI rendering, generated icons and browser acceptance are separate integration
work and are not established by these simulation tests.

## Upgrades HUD integration

Select an owned Blacksmith, Lumber Mill, or Stables/Kennels and open **Upgrades**.
Only that selected producer's categories appear (no implicit redirection). Cards
read authoritative tiers, costs, total/remaining duration, progress and MAX LEVEL;
busy, unfinished, prerequisite/resource and duplicate-category locks disable clicks.
A click uses ordinary `queueResearch`; it neither spends resources nor grants a tier
before the authoritative command is accepted. Replay/watch, chat, results and
existing covered-HUD input guards apply. Build/Units and placement shortcuts are
unchanged. Hover for half a second for affected/excluded units, prerequisites,
per-tier effects and cancellation rules. Selected single-unit HUD stats read live
`unitStats` and Q16.16 `unitMoveSpeed`, including worker armor without hiding cargo.

The atlas keys are `keenflight_arrows`, `tempered_edges`, `runed_plating`, and
`windrunner_training`. **Generated artwork remains blocked on Higgsfield user
authentication.** Until those real assets exist, the HUD uses existing `bow`,
`attack`, `armor`, and `speed_1x` glyphs and labels the tooltip **Temporary icon**.
No generated artwork is claimed or fabricated; real keys automatically take
precedence when available in the atlas.

Native checks: `test_research_presentation.nim` (content/state),
`test_research_render.nim` (actual glyph/contrast/progress FBO), and
`test_research_ui.nim` (production HUD mouse presses, all four categories and all
three tiers, ordinary queued network submissions, authoritative acceptance,
replay/watch/chat and producer locks, full HUD/tooltip/selected-stat FBO captures).
Use separate scratch `--nimcache`/outputs; set `LVD_RESEARCH_FIXTURE` to a PNG path
and `LVD_RESEARCH_UI_FIXTURE` to a scratch directory. The UI fixture supplies
native per-frame mouse state, not OS event delivery or browser evidence. Its black
world area is intentional: it draws the full HUD but not the 3D battlefield.
