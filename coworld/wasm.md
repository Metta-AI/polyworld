# Headless Wasm runner

The experimental Gods of the Arena runner executes the same game and BASIC VM as the native Coworld build.
The host supplies config and ordered policy source bytes. The module has no filesystem, HTTP server, browser assets,
or network grants. Each attempt owns a fresh module instance; discard it after completion or failure.

Build with Nim 2.2.10 and Emscripten 6.0.9. Dependencies come from `coworld/dependencies.lock`:

```sh
nim c -o:tmp/build_wasm coworld/tools/build_wasm.nim
# Activate Emscripten for the build tool, for example with mise:
mise exec emsdk@6.0.9 -- ./tmp/build_wasm
```

The output is `tmp/coworld/wasm/gota.mjs` and `gota.wasm`. Import the Wasm as a compiled `WebAssembly.Module` and pass
an `instantiateWasm` callback to the JavaScript factory. Cloudflare does not permit runtime compilation from fetched bytes.
Only the immutable compiled module may be shared across attempts.

The build uses ARC and Emscripten's default allocator directly. Nim allocation tracing is disabled because its counters
require Nim's allocator. This affects runtime instrumentation, not game behavior. Linear memory grows from 16 MiB to a
96 MiB cap. That cap leaves room for the host but does not guarantee a complete Worker fits its isolate limit.

## ABI version 1

All byte buffers are UTF-8 unless described as binary. Call the factory once to initialize the Nim runtime.

| Export | Contract |
| --- | --- |
| `pw_alloc(length)` / `pw_free(pointer)` | Allocate/free an input buffer, up to 4 MiB. A zero pointer means allocation failed. |
| `pw_initialize(pointer, length)` | Initialize exactly one attempt from `{"config":"JSON config","policies":["source", ...]}`. Returns 0 or -1. |
| `pw_advance(ticks)` | Advance 1–256 existing simulation ticks. Returns 0 while running, 1 when finished, or -1 on failure. |
| `pw_finalize()` | Encode results, replay, and diagnostics after completion. Returns 0 or -1. |
| `pw_output(kind)` / `pw_output_length(kind)` | Borrow a buffer: 0 results JSON, 1 binary replay, 2 private diagnostics JSON, 3 error text. |

A borrowed view becomes invalid when memory grows or the instance is discarded. Read artifacts after finalization.
The host must validate schemas, policy hashes and sizes before initialization, enforce its deadline between tick batches,
yield to its event loop, validate outputs, and publish private logs/replay before the results completion marker.
The game retains existing compilation limits, instruction budgets, map generation, replay encoding, and scoring.

A Wasm trap or exhausted memory can bypass the return-code contract. Treat it as an attempt failure and discard the instance.
Do not reset an instance or silently rerun a failed attempt. Caller retries need a new attempt ID.
