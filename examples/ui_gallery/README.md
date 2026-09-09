# Polyworld UI gallery

A runnable Character, Settings and Quest interface using the pinned Silky DSL
and widgets. Run from the Polyworld root after dependency installation:

```sh
nim r examples/ui_gallery/build_atlas.nim
nim r examples/ui_gallery/gallery.nim
nim r -d:silkyTesting tests/test_ui_gallery.nim
```

The atlas builder accepts the path to Silky's `examples/basicwindow/data` as
its first argument. It uses those existing assets and font without copying them
into Polyworld. The generated atlas belongs in `tmp/ui-gallery`.

The example reuses Silky's content sizing, stack spacing, text alignment,
scrolling frame, dropdowns, checkbox, disabled button, scrubber, text input,
progress bar and nine-slice assets. The state is disposable presentation data,
not an inventory or combat authority. Copy the composition and replace its
callbacks with your game's ordinary commands.

`window.__polyworldUiGallery.snapshot()` exposes current example state for
browser proof. It is read-only; verification clicks the real canvas. The
headless test separately uses Silky's semantic targets. The UI gallery workflow
builds native and WebGL variants, exercises the browser and retains captures.

`gameuis.gameArea` is the single safe-area rectangle for anchored game panels
and replay controls. Insets use left/top/right/bottom order in UI units.
`fitPanel` contains oversized popup rectangles (their content should scroll),
and `popupPanel` flips below/above an anchor before clamping to the usable area.
Zero insets preserve existing placements.
