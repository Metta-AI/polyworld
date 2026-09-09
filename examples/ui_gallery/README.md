# Polyworld UI gallery

A runnable Character, Settings and Quest interface using the pinned Silky DSL
and widgets. Run from the Polyworld root after dependency installation:

```sh
nim r examples/ui_gallery/build_atlas.nim
nim r examples/ui_gallery/gallery.nim
nim r -d:silkyTesting tests/test_ui_gallery.nim
```

The atlas builder accepts the Silky repository root as its first argument. It
uses the existing basicwindow assets and font plus the7gui's disabled-button
patch without copying them into Polyworld. The generated atlas belongs in `tmp/ui-gallery`.

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

The lockfile temporarily pins the interaction fix from
[Silky #67](https://github.com/treeform/silky/pull/67). It preserves a complete
click whose press and release arrive between two rendered frames. Replace that
pin with the upstream commit when the dependency PR merges.

The browser build also pins [Windy #194](https://github.com/treeform/windy/pull/194),
which restores printable key events for canvas text entry and corrects wheel
direction on non-Mac browser hosts. Both fixes live in
their dependency owners and should return to upstream pins after merging.
