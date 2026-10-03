# Shared engine qualification

The six asset-free native tests pass on macOS with Nim2.2.10 and all28 dependency revisions matching `nimby.lock`.
The receipt records each source hash, exact command, dependency revision and exit code.

```sh
python tools/qualify_shared_engine.py --dependencies /path/to/locked/dependencies --output /path/to/new/results
```

Dependency paths may reuse read-only caches or isolated Git worktrees. The runner rejects any lock mismatch before compiling tests.

Initial unlocked tests failed because cached glTF lacked `Material.unlit`. Locking glTF exposed cached shady's missing `replaceTextureReads`.
Both failures disappeared after locking the complete dependency set. No shared cache was modified.

These assertions cover animation controls, character representation, picking, pathing, tile paths and terrain maps.
They do not establish rendered pixel fidelity, browser execution or acceptance in Cogcraft, Puzzle Pirates and Dwarf Fortress.
Those downstream owners must pin game revisions, scene seeds and native/browser snapshots before declaring cross-game qualification.

The same pathing, tile-path and terrain-map assertions also pass after Emscripten5.0.7-git compilation, under Node24.
`qualify_shared_engine_wasm_results.json` pins the native receipt and records each WebAssembly compile command and assertion output.
This checks simulation portability. A Node run does not establish browser graphics or WebGL behavior.

The pinned Puzzle Pirates consumer3f7b2fa870858c7069d55e52674153d47501c56b also passes its existing
`tools/test-portable.sh` harness against engine4fc74f6 and the28locked dependencies. Native and WebAssembly
outputs match across167lines, SHA256a5267673bc309265b90724fc2cd2cada9ccd50cad258ed24f26a7f2a44db45e4.
`qualify_shared_engine_consumer_results.json` records the exact command and source identities.
The shared low-memory wrapper initially refused admission75 while another task held its lock; it passed after
that owner released the seat. No lock bypass or shared dependency edits occurred. Consumer source remains unchanged.
This proves the existing consumer's simulation/replay hash portability, including puzzle and paid-labor fixtures.
Browser rendering and acceptance in the other two games remain unqualified.

Runtime artifact custody includes the native executable, or both the JavaScript loader and its `.wasm` module.
The qualifier fails if the expected module is missing. The primary executable hash remains separately recorded.
`qualify_shared_engine_runtime_artifacts.json` adds the module identities to retained execution evidence.
All six native and six Node runs reproduce their recorded assertion-output hashes.
This is artifact reexecution, not recompilation or rendered consumer acceptance.
