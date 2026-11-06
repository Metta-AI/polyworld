# Cards and Casters loading artwork

The browser shows a moonlit card-table illustration while the game downloads.
An archer, warrior and mage gather in a ruined observatory, with quiet scenery
on the left for the title. Portrait screens focus on the gathering above the
title and progress bar. The loading screen uses ordinary HTML images; it does
not initialize a 3D scene or a second canvas.

- `polyworld_art/cac/loading/moonlit-table.webp` is the runtime painting,
  approximately 305 KiB. Its original PNG, generation prompt and conversion
  recipe live in the art repository's `cac/loading/` directory.
- `cnc-wordmark.svg` replaces the old shield with the full **Cards and Casters**
  name and a small fan of cards. The letter shapes are outlined from the
  project's Grenze SemiBold font and retain its SIL OFL 1.1 attribution.
  Outlines render immediately, before the subtitle's webfont is ready.
- `cac-logo.svg` and `courtyard-night.svg` are the previous design, retained as
  source history. The loading page no longer requests them.

`tools/build_web.sh` copies the WebP, wordmark, Grenze font and OFL notice into
the browser output's `loading/` directory, outside the Wasm asset pack. The
source PNG is not packaged. The shell preloads its two images and font.

Download progress, indeterminate preparation, first-frame reveal, reduced
motion support and error recovery retain their existing behavior. The empty
`loading-note` element is reserved for error recovery guidance.

With a fresh browser build served locally, run the focused loading checks:

```sh
CAC_TEST_URL=http://127.0.0.1:8080 node tests/test_hero_select.cjs --loading-only
```

These use Playwright and Chrome and save desktop, portrait and short-landscape
screenshots to `build/test-output/`.
