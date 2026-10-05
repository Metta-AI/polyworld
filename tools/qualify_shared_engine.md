# Shared engine qualification

Run one asset-free cohort for animation, characters, picking, pathing, tile transitions, and terrain.
The runner checks all dependency revisions against the checkout’s `nimby.lock` before compiling.
It records source, toolchain, commands, exit status, output hashes, and produced binary identities.
WebAssembly custody includes both the JavaScript loader and `.wasm` module; a missing module fails.

```sh
python tools/qualify_shared_engine.py --dependencies /path/to/locked/dependencies --output /path/to/new/results --target native
python tools/qualify_shared_engine.py --dependencies /path/to/locked/dependencies --output /path/to/new/results --target wasm
```

Repeat `--test` for a bounded subset. Every run requires a new output directory.
Dependency directories may be read-only caches or isolated worktrees. Keep generated receipts outside the repository.

## Archived proof

Historical producer `879bdb350858a425fbec5a721118603389b54abc` used Nim 2.2.10, Emscripten 5.0.7-git, and Node 24.
Its 28 dependency pins matched lock SHA256 `872447d9ba549499beb5483d7fd84bbb967eeb8152af1a65701db6cd65ec710a`.
Six native and six Node fixtures passed with identical assertion output. All twelve retained artifacts passed reexecution.
Reexecution was not recompilation, browser graphics, hardware acceptance, or qualification of current main’s different dependency lock.

The six generated receipts below are preserved byte-for-byte at the immutable review head.
They retain every command, dependency revision, artifact hash, owner, failure, and source-specific limitation.
Archive SHA256: `4f999368ee5d9cfbf13492fcb88fea8a48678fb71036438629420e90cda05854`.

| Original receipt | Lines | SHA256 |
| --- | ---: | --- |
| [qualify_shared_engine_consumer_results.json](https://github.com/Metta-AI/polyworld/blob/ad446f12f0a3c4fc91e03be17966291cea41e851/tools/qualify_shared_engine_consumer_results.json) | 19 | `c0a0af67c43a2cf7cb5c5ba9e48fa847dd58aa73fa81dd24edd398ff4ab0b29c` |
| [qualify_shared_engine_current_consumer_receipts.json](https://github.com/Metta-AI/polyworld/blob/ad446f12f0a3c4fc91e03be17966291cea41e851/tools/qualify_shared_engine_current_consumer_receipts.json) | 242 | `61e9b62d7c17ed2aa1021fbde1a473c8790d5690217c2eb17fe2e84d823dbaee` |
| [qualify_shared_engine_execution_results.json](https://github.com/Metta-AI/polyworld/blob/ad446f12f0a3c4fc91e03be17966291cea41e851/tools/qualify_shared_engine_execution_results.json) | 1216 | `019c3581fcff4dbffdd8d18fc495feead1cd8fe99fccf7e29f574c0cc0ac1290` |
| [qualify_shared_engine_results.json](https://github.com/Metta-AI/polyworld/blob/ad446f12f0a3c4fc91e03be17966291cea41e851/tools/qualify_shared_engine_results.json) | 446 | `faa6ed895fa907cac5740a1b3fcd845e6ffa0594dafa878e57a2930021c65676` |
| [qualify_shared_engine_runtime_artifacts.json](https://github.com/Metta-AI/polyworld/blob/ad446f12f0a3c4fc91e03be17966291cea41e851/tools/qualify_shared_engine_runtime_artifacts.json) | 211 | `710a36f044e50ea59918793b524bb9ed9970ddce481978a9ac4d2b003b80654a` |
| [qualify_shared_engine_wasm_results.json](https://github.com/Metta-AI/polyworld/blob/ad446f12f0a3c4fc91e03be17966291cea41e851/tools/qualify_shared_engine_wasm_results.json) | 191 | `083828c664081ab0a45934badc363aad0033e3e0e20d12d7867f171c0ed4a569` |

Retained runtime identities, from the archived runtime receipt:

| Artifact | SHA256 |
| --- | --- |
| test_animblend_controls | `d8c3a0466ff970bd355fa279571e2ce9230c74da1b266f50babc7df8c0597f0c` |
| test_characters | `90a7856a5001703ff4cec50c2964d79d50a5841c4972823b6dcbf18cbd973b55` |
| test_picking | `742d82a90548195c0eaa70ef2ecf830bc21a5d8ddb67d4f18ef9ccf38aa9586b` |
| test_pathing | `ef887f894939ed158f3e4fd96088914643663767d916ec498fbc15e4b9a6de3e` |
| test_tile_paths | `2275a0c3f66aeebe5d1a0dd6023eb81e756284c764bb10960246b43317e15523` |
| test_terrainmaps | `9e6ace69a665408b71256e66986869540758696ae30cbbce9a2d768e06be83c9` |
| test_characters.js | `8ee8eb55292bc0f3011d6436784ab955d48d215c1d5b63e06f90226a7359dc3c` |
| test_characters.wasm | `08ddc40e7ebb2235286a6aa7eb325f2c9d03c9a40e61c19adcf6fb37582ac927` |
| test_animblend_controls.js | `b8a272a7ce1f1539e7ec797ec20642ae4927a904fa07e00edd904886365d6f64` |
| test_animblend_controls.wasm | `8d1e37a6911b0dcf1a92504b725b7c7f04b98ad6d81da4addec683c3b4dc1ec8` |
| test_picking.js | `81ba5395c174d94978643cd8cfd50562be604b5d4a69d03259bab1e9b491d6a9` |
| test_picking.wasm | `24ef5356efd4205167dc7e214e38af9a3801643230ea5ecec4c17ea3fa128980` |
| test_pathing.js | `60064177218ec1f56f41fe164bff32e7416be03b1685262d0e050c2e2e691b97` |
| test_pathing.wasm | `448c6f91a8e2dedc0b65e4535c7649a378844afbbe61ed115fdb200d78250550` |
| test_tile_paths.js | `0ed43f0fd24c6a654c7c0e1a6f9df18ae5c1a30fd781bec1c8330c88938ed014` |
| test_tile_paths.wasm | `2f27766e73dffcc043d023efd5b8acdf7eda6757e43f3ae8c4b0ec827e76d12f` |
| test_terrainmaps.js | `c0c85382e4a840c52f85076fe3fa4c1e5fd43d60cea23b32c1a58a352ccda1d1` |
| test_terrainmaps.wasm | `6174b4b24c0dc4b892106259d51f5b92effa15a950c79a7590e9f8b8f0787628` |

## Consumer conclusions

Historical Pirates source `3f7b2fa870858c7069d55e52674153d47501c56b` with engine `4fc74f6adf000ea2534fcecfbd1859fa1fcaa252`
produced 167 identical native/WebAssembly replay lines. Output SHA256:
`a5267673bc309265b90724fc2cd2cada9ccd50cad258ed24f26a7f2a44db45e4`.

Pirates `7c23a909d3d59b19e4eefe5c7551f48b350d3d88` passed software two-browser physical move, chat, and reload in 24.697 seconds.
This does not establish hardware graphics, held-input acceptance, or persistent-world readiness.

| Later Pirates cohort | Official run | Peer receipt SHA256 | Retained outcome |
| --- | --- | --- | --- |
| `00b883566abc5ad21c55474bf3510600511c43f4` | 37205939757 | `34a6b550d68663ad50130ebbcb136a451b1c443385e1bca8f8af24578b162831` | Native keyboard/reconnect and two-browser grapple/boarding/cargo/reconnect pass; software 42 samples, p95 883.2 ms, timeout: failure. |
| `2311c87ea165a955987a48ec2e01f3cfb52613cc` | 37223507259 | `5d08965f44910a7346946415c031263580a9fdefdbc658ea50980843f775d0f9` | Native keyboard/reconnect and two-browser grapple/boarding/cargo/reconnect pass; software 41 samples, p95 849.9 ms, timeout: failure. |

Earlier Pirates `4f3ef1a7182950bc57db3f3b8e69b34a519f1fda` retained normal frame/HTTP p95 61.4/133.9 ms
and compact 27.8/83.2 ms. Original limits remain 33.34/50 ms; both overall controls fail.
These historical results are not relabeled to another source.

Dwarf rendered source `955484aad9ddb3ca0f6670926ddceea21c862e1b` with engine
`a808ccc81f06cd9cfdbfa872f795cba21aa1a7b1` passed native/software-browser input, picking, save/reload, and deterministic state.
Two 600-frame clients measured median 43.8/43.9 ms and p95 48.0/47.7 ms.
Full served identities and receipts remain in the archived consumer index and
[PR7](https://app.graphite.dev/github/pr/Metta-AI/dwarf_fortress/7)/[PR8](https://app.graphite.dev/github/pr/Metta-AI/dwarf_fortress/8).
This does not establish hardware, color, skeletal fidelity, or persistent-world acceptance.

## Failures and exact remainder

Unlocked glTF lacked `Material.unlit`; cached shady lacked `replaceTextureReads`. Locking all dependencies resolved both.
The shared low-memory gate refused admission 75 while another owner held its lease; no bypass occurred.
WebAssembly initially failed because Windy referenced stripped `_malloc`. Exporting `_main,_malloc` fixed that source-specific failure.
Current consumer build custody, old screenshots, and 58-asset readiness do not substitute for rendered acceptance.

The original three-consumer goal remains open: current Cogcraft paired renderer/camp, animation, assets, terrain, picking,
frame-time, and memory proof; current Pirates 1,500 ms held-input, native/browser hardware parity, and sustained multi-client proof.
Historical Dwarf proof stays on its recorded cohort. Consumer owners retain their work; no duplicate run is required.
No new experiment, upload, resource allocation, graphics run, or scientific completion is implied by this index.
