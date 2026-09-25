# Neural policies

A Polyworld game can let a player submit a small neural network next to a BASIC
program. The network runs natively inside the game, under a fixed operation budget,
and the BASIC program keeps everything the network does not decide (drafts, shops,
chat, fallbacks). This page is the game-agnostic part: the package format, the model
format, the budget and the host functions. It also explains how to plug a game in.

The shared code:

| file | role |
|---|---|
| `src/polyworld/neural_actor.nim` | model format (GOTANET1) loader and FP32 MinGRU inference |
| `src/polyworld/neural_package.nim` | strict ZIP + manifest parser, checked against a game's contract |
| `src/polyworld/neural_host.nim` | `NeuralContract`, per-seat `NeuralBrain`, lifecycle, budget, telemetry, decoders, BASIC host functions |
| `src/polyworld/boundedinflate.nim` | DEFLATE with a hard output limit (used by the package reader) |
| `coworld/runtime/neural_package.py` | staging validator and builder that mirrors the Nim parser |
| `tests/test_neural_tier.nim`, `tests/neural_toy.nim` | the tier on a synthetic toy contract |
| `tests/neural_cases.py`, `tests/test_neural_cases.nim` | one corruption suite run by both validators |

The tier has no game in it. Each game supplies a contract. Gods of the Arena is the
first client (`examples/gods_of_the_arena/neural_basic.md`).

## Package

A package is a ZIP with exactly three entries:

- `manifest.json`: at most 64 KiB.
- `policy.bas`: the seat's BASIC program, at most 256 KiB.
- `model.bin`: the network (see below), at most the size of the largest valid model.

The whole ZIP may be up to 16 MiB. Entries must be stored or deflated, and none may be
encrypted.

```json
{
  "schema": "<game schema id>",
  "observation_contract": "<sha256 hex of the game's observation contract text>",
  "action_contract": "<sha256 hex of the game's action contract text>",
  "decision_period": 4,
  "files": {"policy.bas": "<sha256 hex>", "model.bin": "<sha256 hex>"},
  "model": {"format": "GOTANET1", "inputs": 1407, "hidden": 128, "heads": [8, 25, 49, 4, 6]},
  "decoder": {"mode": "argmax"}
}
```

Parsing is strict, and the reader never raises a defect, whatever the bytes. It
rejects the package with a `ValueError` naming the reason when:

- a key is not listed. The generic keys are listed above; a game adds its own
  through `manifestKeys` and `decoderKeys`.
- a required key is missing, or a value has the wrong JSON kind. An integer field
  must be a JSON integer, so `1407.0` and `true` are rejected.
- any number is non-finite (`NaN`, `Infinity` or `1e999`).
- a file hash, the schema, a contract hash, `inputs`, `hidden` or `heads` differs
  from the model or the contract.
- an entry name is unknown or repeated, or an entry declares more uncompressed bytes
  than its cap. The reader checks this before decompressing anything, and inflating
  stops at the declared size, so a small zip bomb cannot expand in memory.

`decoder.mode` is `argmax` (the default: the first maximum of each head) or `sample`
with `temperature` 0.01..10. Sampling draws once per head, in head order, from
softmax(logits / T). It uses SplitMix64, seeded per seat from the match seed.

Staging uses the Python validator. Each game wraps it with its own `Contract` (GotA:
`coworld/gota/runtime/neural_package.py`). Because the Python and Nim validators run
the same corruption suite in CI, a package that passes staging is one the game
accepts, and the reverse.

Coworld servers read a staged player file whose first bytes are `PK\x03\x04` up to
16 MiB, instead of the 256 KiB BASIC cap (`coworld.nim` `readPlayerSource`). This
applies to every game. A larger file is read one byte past the cap, so the loader
reports "package exceeds 16 MiB" rather than a broken ZIP. Games without neural
seats treat such a file as BASIC and reject it at compile time, exactly as before.

## Model format (model.bin, GOTANET1)

GOTANET1 is the Polyworld neural model format. Gods of the Arena introduced it, so the
magic stays `GOTANET1` for every game. All values are little-endian.

| offset | field |
|---|---|
| 0 | magic `GOTANET1` (8 bytes) |
| 8 | u32 version = 1 |
| 12 | u32 inputs I (1..4096) |
| 16 | u32 hidden H (64, 128 or 256) |
| 20 | u32 outputs O (2..1024, the sum of the head sizes) |
| 24 | u32 heads K (1..32) |
| 28 | u32 parameters = I*H + 3*H*H + O*H (at most 2,000,000) |
| 32 | observation contract hash, 64 lowercase hex chars |
| 96 | action contract hash, 64 lowercase hex chars |
| 160 | K x u32 head sizes (2..1024 each) |
| 160+4K | f32 weights: W_enc[H][I], W_rec[3H][H], W_dec[O][H] (row-major, all finite) |

One inference (PufferLib's MinGRU policy) runs these steps:

```
x = W_enc · obs                     (H)
c, g, hw = split(W_rec · x)         (3 x H)
candidate = c >= 0 ? c + 0.5 : sigmoid(c)
state' = lerp(state, candidate, sigmoid(g))
y = sigmoid(hw) * state' + (1 - sigmoid(hw)) * x
logits = W_dec · y                  (O, heads concatenated)
```

`sigmoid` and `lerp` use the same branches as PufferLib's GPU kernels, so a trainer can
check its actor against the hosted one bit for bit. A non-finite input, state or
output fails the inference, and nothing changes.

## Budget

A model costs `2 * parameters + 32 * H` operations per inference
(`Actor.operationCount`). A seat runs at most one inference per tick. The contract's
`opBudget` caps this cost. It defaults to 4,000,000 and is separate from the BASIC
instruction budget. The cap is checked when the model is loaded, so an over-budget
model is rejected up front. It is never stopped halfway through a match.

## Adding neural seats to a game

1. **Write the contract texts.** Two canonical strings: the observation layout
   (every feature, normalizer and slot rule) and the action heads (every verb and how
   it decodes). Their SHA-256 values are the contract hashes. Any change to a feature
   or a decode rule must change the text, which gives it a new hash, so old models
   are rejected instead of misread.

2. **Build one `NeuralContract`** with `initNeuralContract`. It computes the hashes
   from the texts. It also asserts that your hand-counted logit total equals the sum
   of the head sizes, and that the mask size and mask callback come together.

   ```nim
   let MyContract = initNeuralContract("mygame", "mygame-neural/1",
     observationText(), actionText(), ObservationSize, HeadSizes, ActionOutputs,
     buildObservation = myObservation, decodeAction = myDecode,
     head = myHead, tick = myTick,
     log = mySeatLog, maskSize = MaskSize, actionMask = myMask,
     manifestKeys = ["goal"], decoderKeys = ["my_option"],
     parseOptions = parseMyOptions)
   ```

   Its fields and callbacks:

   | field | purpose |
   |---|---|
   | `buildObservation(brain): bool` | fills `brain.obs` for the current tick; returns whether the seat acts |
   | `decodeAction(brain)` | turns `brain.logits` into your heads and the command to issue (argmax, sampling, masks) |
   | `head(brain, i)` | head `i` of the latest decision (for `neuralModel(5 + i)`) |
   | `tick(brain)` | your current tick (a decision is fresh only on its own tick) |
   | `log(brain, text)` | optional; the seat's private log (telemetry) |
   | `actionMask(brain, mask)`, `maskSize` | optional; the frame's validity mask |
   | `parseOptions(manifest)` | optional; validates your extra keys and returns your options object |
   | `telemetryExtra(brain)` | optional; your counters appended to the telemetry line |

3. **Derive a seat type** from `NeuralBrain`, adding whatever your decoder needs (a
   decision frame, the heads, your command). Create each seat with
   `seat.initBrain(contract, period, maxTicks)`. Set `seat.actor = package.actor`,
   then call `seat.resetBrain(matchSeed, seatIndex)` at every match start.

4. **Run it** on the decision ticks (`decisionDue(battleTick, period)`). The simple
   form is `seat.decide(tick, battleTick)`, which observes, infers, decodes and logs.
   A game with other seat kinds (trainer-driven, label capture) can call
   `seat.beginFrame(tick)` and then `seat.think(battleTick)` itself.

5. **Expose the BASIC surface** with `host.addNeuralHostFunctions(lookup)`. Register it
   in the same place in the schema host and in each seat's host, next to your own
   action function (GotA uses `gota_act`). The functions:

   | function | result |
   |---|---|
   | `run_neural_net()` | 1 when this tick has a fresh decision |
   | `neuralObservation(i)` | observation float `i` (Q16.16) |
   | `neuralLogits(i)` | logit `i` of the last inference (Q16.16) |
   | `neuralState(i)` | recurrent state float `i` (Q16.16) |
   | `neuralModel(k)` | 0 hidden width, 1 inputs, 2 outputs, 3 decision period, 5+h head h |

   Every function returns 0 for a seat without a brain.

6. **Load packages** with `parsePackage(bytes, contract)`. On a Coworld server, a
   rejected package should end the episode with `failPlayer(slot, reason, message)`,
   so the platform reports the real reason.

7. **Wrap the Python validator** with a `Contract` that has the same schema, hashes,
   sizes and extra keys, plus a `parse_options` that mirrors yours.

### State and resets

`beginFrame` captures one frame per tick. The recurrent state restarts from zero on
the seat's first frame, and on the first frame after the seat stopped acting (death,
respawn). `resetBrain` clears everything per match except `peakOps`. A reset seat
replays a fresh seat exactly (`tests/test_neural_tier.nim`).

### Telemetry

With `brain.telemetry = true` and a `log` callback, the seat logs this line on the
first inference, every 1800 inferences and on the match's last decision:

```
neural: peak_ops=<ops> budget=<opBudget> model=w<hidden> ticks=<battle tick> inferences=<n>
```

A game can add its own counters after it (GotA adds its decision, invalid, defer and
override counts).

### Parity expectations

Neural support must not change games that don't use it:

- A match with no neural seats must replay byte-identically (state hashes and replay
  bytes) to the same match on a build without neural support.
- A hosted package seat must play exactly like a trainer-driven seat that runs the
  same weights through the same actor and decoder.
- Every decoder option must be byte-identical when off.

Prove all three with seeded batteries over full-length matches before shipping. GotA's
proofs (`examples/gods_of_the_arena/tools/`) are a template.
