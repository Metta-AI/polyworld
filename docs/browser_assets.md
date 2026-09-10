# Browser asset bundles

Normal and replay WASM builds for GOTA, LVD, and CTA automatically run the game's
own native `pack_assets.nim`. Each entry point imports only its game's asset
declarations and uses the shared packing functions in `tools/assetpacks.nim`.
Existing build commands and `POLYWORLD_DATA` continue to work.
Native games still read the original assets at their original quality. Heartleaf
keeps its existing packaging path.

Each game's `assets.nim` shares its model paths, selected parts, props, portraits,
animation names, and terrain settings with its renderer. Shared declarations live
in `src/polyworld/assets.nim`. Change these declarations when adding content.
There is no source-code scanning or manually maintained `webdata.txt`.

The packer maintains `tmp/webassets/<game>-ktx2/stage/` and preloads only that
directory at `/polyworld_data`. Generated GLBs and textures never enter the source
asset repository. A sorted `manifest.txt` and `report.json` sit beside the stage,
outside the preload. The JSON report includes each file's bytes and the total.
UI atlas directories include their PNGs, matching the renderer's directory loads.

Unchanged builds print `Assets unchanged, skipping bake` and reuse the stage
without rewriting its files or reports. `cache.json`, outside the preload,
records content hashes for every input actually read, including external model
images, buffers, and character preset manifests. The cache key includes the asset
declarations, selected directory members, source root, and packer executable, so
changed selections, added or removed PNGs, and encoder changes trigger a fresh
bake. Timestamps alone do not invalidate the cache. Unrelated source files are
ignored.

Generated files and reports are also hashed. Missing, changed, or extra staged
files trigger a clean rebuild. Cache metadata is published only after a successful
bake, and a failed rebuild cannot leave a reusable partial stage. Delete
`tmp/webassets/<game>-ktx2/cache.json` to force baking again. The PNG comparison
variant uses the same mechanism in its separate `-png` cache. Nim still checks the
native packer's compilation dependencies before running the hash check.

Each game's packer also creates a cached 320 by 240 maximum logo preview outside
the preload stage. Normal and replay HTML pages embed this preview above the
loading status, so it appears before the asset download finishes. The original
in-game logo keeps its full resolution.

Static props become individual GLBs under the original pack's basename. The
multi-file `loadPropPack` overload collects these files into the same runtime
structure. Native builds retain the original single-file path. Character packs
retain their node hierarchy, selected meshes, required skins, and animation
targets. Accessors and binary views are compacted after selection. GOTA retains
95 modular parts and CTA retains 44. GOTA and LVD retain all animation clips.
CTA keeps Idle, Run, and Attack01, with Walk replacing Run for the rock golem.

Embedded and external image dependencies become shared content-addressed files.
External buffers are resolved and their retained views are embedded in the output
GLB. PNG scanlines are recompressed without changing pixels or metadata, and the
original encoding is kept when smaller. UI images, portraits, and palettes keep
their original resolution. Missing content, invalid references, cyclic node
hierarchies, and unsupported GLB extensions fail the build. The packer deliberately
rejects opaque extension references it cannot safely remap.

## CTA terrain

Seven ordinary 2D KTX2 files contain 256 by 256 linear BC3 terrain materials.
Each contains RGB color and height in alpha, with mip levels down to 4 by 4.
Color and height are resized and filtered independently. The glTF library's
existing BC1 and BC4 encoders produce the color and height blocks, which the
packer combines into BC3. Height never participates in color premultiplication.
No glTF dependency changes are required.

The renderer assembles the files into a texture array. WebGL S3TC support enables
direct compressed uploads. Otherwise, a local BC3 decoder expands the same files
to RGBA. No duplicate fallback PNGs ship. Append `&textureFallback=1` to an existing
query, or build with `-d:webForceRgba`, to exercise the compatibility path. The
texture's maximum level is explicitly limited to the supplied mips.

CTA explicitly disables tree, scattered grass, scattered rock, and water assets,
and omits the unused underwater material. GOTA and LVD's dense-tree configuration
loads only fir textures. Material replacement respects configured dimensions and
converts a compressed terrain array to RGBA before editing it.

## Checks

Run from the repository root:

```sh
nim check tests/tests.nim
nim r tests/tests.nim
nim c -d:emscripten examples/gods_of_the_arena/gota.nim
nim c -d:emscripten examples/light_vs_dark/lvd.nim
nim c -d:emscripten examples/call_to_adventure/cta.nim
nim r tests/manual_assetpacks.nim
```

The assertion suite covers selection, transforms, skin references, clip targets,
external buffers and images, data URIs, invalid references, PNG round trips,
independent BC3 channels, deterministic output, stale-file removal, cache reuse,
dependency invalidation, and recovery from damaged output or failed bakes. The manual
audit requires the three generated stages and source assets. It compares every
retained mesh, palette, skin weight, transform, and three poses per retained clip
against the original models, including all declared construction and rubble props.

Add `-d:replayViewer` to each WASM command to build its replay viewer. Replay
fixtures must match the current game versions. Check full replay playback,
controls, resizing, and visible errors in the browser.

## PNG comparison

`-d:webPng` produces the same selected CTA content with 256 by 256 color/height
PNGs for visual comparison. It uses a separate `cta-png` staging cache.

## Measured bundles

Measurements use the source assets available on 2026-09-10. Baselines are the
bytes in the previous per-game manifests. These are raw `.data` bytes before HTTP
compression. Adding PNGs to the shared UI atlas directories changes the totals.

| Game | Previous | Generated | Reduction |
| --- | ---: | ---: | ---: |
| CTA | 59.23 MiB | 7.00 MiB | 88.2% |
| GOTA | 43.91 MiB | 19.26 MiB | 56.1% |
| LVD | 33.51 MiB | 22.05 MiB | 34.2% |

CTA's generated `.data` is 7,338,654 bytes, below the 8 MiB target. The same
selection using PNG terrain is 7,492,090 bytes. Most savings come from selecting
geometry, trimming clips, sharing textures, and lossless PNG compression.

The complete headless suite and all six normal/replay WASM builds passed. The
model audit checked 678 poses: CTA 45, GOTA 210, and LVD 423. Browser replay tests
reached tick 15,029 for CTA, 13,548 for GOTA, and 28,800 for LVD, then checked rewind,
speed changes, resize, and missing/corrupt/divergent replay errors. The CTA fixture
visited all six levels and escaped with all four heroes. Regenerating each of the
three complete stages produced identical file, manifest, and report hashes.
Heartleaf's native check also passed with the shared renderer changes.
