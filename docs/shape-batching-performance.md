# Shape primitive assembly

Triangles reserve 27 floats once; quads reserve 54 floats once. A private writer
fills the existing interleaved position/UV/color layout in the same order. Color
normalization happens once per primitive. Public APIs, tint behavior, winding,
alpha blending, draw calls and GPU upload policy are unchanged.

Run the differential and alternating-order microbenchmark:

```sh
POLYWORLD_DEPS=/path/to/dependencies python3 tools/verify_shape_batching.py \
  --baseline 7ff5a8ce4b4ad5895de9371b415dc5630a13d187 --backend native
```

Repeat with `--backend js` and `--backend wasm`. `--nim` selects a compiler.
The tool reads the preceding source from Git into a unique temporary directory;
there is no old implementation in production. Native imports both complete shape
modules without creating a GL context. JS and WASM extract their unchanged CPU
primitive definitions, excluding the GL setup/draw code. This measures assembly,
not GPU submission, browser frame rate, scene culling or a full game.

On macOS arm64, Nim 2.2.10 release, Node 24.12.0 (2026-10-08):

| Backend | Previous median | Batched median | Ratio |
| --- | ---: | ---: | ---: |
| Native ORC | 24.648 ms | 12.284 ms | 2.007x |
| Nim JS | 523.882 ms | 540.258 ms | 0.970x |
| Emscripten WASM ARC | 40.865 ms | 22.893 ms | 1.785x |

Each sample assembles 12 frames of 4,096 mixed primitives, with retained storage,
10 samples alternating old/new execution order after warmup. Each final frame
contains 675,756 floats. JS does not show an improvement; shipped WASM needs its
own full browser measurement before asserting a game frame-rate improvement.

All three backends pass 2,048 mixed primitive cases covering triangle, quad,
square, polygon, circle, hexagon, polyline, line, degenerate inputs, custom UVs,
rotation, all color channels and alpha 0/1/128/254/255. Clear/reuse and every
benchmark output are compared. Native and WASM compare every float's uint32
representation; Nim JS compares every numerical value. This preserves the
existing painter order and the fully opaque input's special half-alpha tint.
