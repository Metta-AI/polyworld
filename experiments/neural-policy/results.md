# Richard's policy conversion results

The original and converted policy produced identical gameplay in the recorded
GotA match: all 129,497 actions and all 28,909 per-tick state hashes match.
Both ended with state hash **`00000000491E52B0`**. All 10 scripts remained
active through 288,010 decisions. The match reached its 20-minute battle limit.

The raw replay files differ because their player labels and instruction-use
telemetry differ. `compare.nim` verifies setup, every action, every tick hash,
and every other field after allowing only those two metadata differences.
No actions or state hashes are normalized, and neither recording is modified.

## Policy and environment

- Original BASIC in local, ignored `tmp/neural-parity/original.bas`: 1,147 lines, 46,457 bytes, unchanged.
- [Converted BASIC](../../examples/gods_of_the_arena/players/neural.bas): 828 lines, 24,944 bytes.
- Source: [co-gas at 131b8fde](https://github.com/Metta-AI/co-gas/blob/131b8fde058561cf369449ee2854579f02c64676/players/users/relh/co-gas/polyworld-basic/gods_of_the_arena_neural_v63_arcanist_elixir_stock.bas).
- Original source SHA-256: `d5514435f27c400a53bf026b338e7786114f5a4948e9a99d5dd1c3dea9fd1f3a`.
- Polyworld baseline: `8b31ddd`, gameplay version 63.
- Bassy baseline: `b25e0efef3fec0bd86ed3154659c0762a7158bd3`.
- Fixxy: `05e5446dffb70093056cebb0c57721a60deaf52a`.
- Local validation: macOS, Nim 2.2.6, native release build.
- Match seed: `20260924`. Map seed: `54`, map hash: `0000000099EBA3A6`.
- Seats 1-5: Richard's policy. Seats 6-10: the unchanged GotA base policy.
- Battle: 28,800 ticks. Draft: 109 ticks. Total: 28,909 ticks.

The original binary was built and the baseline recorded before modifying
Bassy or Polyworld. It remains at `../../tmp/neural-parity/gota-original`.

## What changed in the policy

All three affine layers now call `linear`, followed by `relu` and `argmax` as
appropriate. The draft model is 32 to 10 with availability masking. The combat
model is 25 to 16, ReLU, then 16 to 18. All 1,052 matrix and bias entries are
inline DATA, including zero padding in the sparse draft matrix. No binary or
ZIP file is needed.

The converter extracts the exact literal strings without rounding them in
Python. Draft values use fixed-point arithmetic, and combat values retain
int32 arithmetic. The original feature extraction, action mapping, shopping,
draft eligibility, and four-tick inference cadence are preserved. The combat
selection also preserves the original sentinel behavior at the bottom of the
int32 range.

The inference itself is now:

```basic
linear(f, encoder, encoderBias, h, 25, 16)
relu(h, 16)
linear(h, decoder, decoderBias, logits, 16, 18)
decision = argmax(logits, 18)
```

## Performance and validation

`bench_neural.nim` additionally compares all 16 hidden outputs and the selected
action across 256 deterministic combat feature vectors. All match.

| Isolated combat inference | Interpreted | Native |
| --- | ---: | ---: |
| Mean milliseconds per 1,000 evaluations, 20 samples | 12.295 | 4.180 |
| Charged instructions for the last sample | 3,693 | 1,521 |
| Charged work units for the last sample | 4,421 | 1,598 |

That local kernel benchmark is about 2.9 times faster. Full-match elapsed times
were 20.03 and 20.61 seconds; those include the whole simulation and do not
demonstrate a whole-game speedup.

Checks passed:

- Bassy `nim check tests/tests.nim` and `nim r tests/tests.nim`.
- Polyworld `nim check tests/tests.nim` and `nim r tests/tests.nim`.
- AWM host `nim check`, in addition to the games covered by the main suite.
- Playback of the converted recording consumed all 129,497 actions with no
  state-hash mismatches and ended at the same final state hash.
- DATA syntax, integer/fixed coercion, immutability, reset/restart behavior,
  context callback binding, array-handle boundaries, and memory limits.
- Scalar/native arithmetic equivalence, int32 wraparound, fixed rounding,
  argmax ties/masks, alias and shape rejection, instruction/work exhaustion
  before kernel mutation, and stable memory across repeated inference.

## Reproduce

From the repository root, after installing the dependencies in `nimby.lock`.
The original policy is a temporary local artifact and is not included in the
repository. Conversion, baseline replay generation, and the benchmark require
`tmp/neural-parity/original.bas`; restore it from the source link above if the
temporary directory has been cleared.

```sh
mkdir -p tmp/neural-parity
python3 experiments/neural-policy/convert.py \
  tmp/neural-parity/original.bas \
  examples/gods_of_the_arena/players/neural.bas
nim c -d:headless -o:tmp/neural-parity/gota-native \
  examples/gods_of_the_arena/gota.nim
tmp/neural-parity/gota-native \
  --bot tmp/neural-parity/original.bas:5 \
  --bot examples/gods_of_the_arena/players/base.bas:5 \
  --seed 20260924 --ticks 28800 \
  --record tmp/neural-parity/original.replay
tmp/neural-parity/gota-native \
  --bot examples/gods_of_the_arena/players/neural.bas:5 \
  --bot examples/gods_of_the_arena/players/base.bas:5 \
  --seed 20260924 --ticks 28800 \
  --record tmp/neural-parity/converted.replay
nim r experiments/neural-policy/compare.nim \
  tmp/neural-parity/original.replay tmp/neural-parity/converted.replay
nim r experiments/neural-policy/bench_neural.nim
```

The commands above compare both policies on the new runtime. To rerun the
historical baseline, use the preserved `gota-original` binary
with `--bot tmp/neural-parity/original.bas:5`, the same opponent,
seed, and tick limit. To rebuild that binary, use the baseline commits above
without the Bassy override. Names in metadata follow the supplied BAS filename.

## Saved artifacts

Both replay files remain under the worktree's ignored `tmp/neural-parity/`
directory, along with build, test, comparison, and benchmark logs.

| Replay | Bytes | SHA-256 of raw file |
| --- | ---: | --- |
| `tmp/neural-parity/original.replay` | 4,438,360 | `d2e07478a5fa8bf510de9c3ad84f74164bec466c8610ce7834905b741ab01e52` |
| `tmp/neural-parity/converted.replay` | 4,438,365 | `f54b3d9c22364727977dc1b7c264c3585f3e48b5a647444d8becdbdb56a21ec1` |
