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
