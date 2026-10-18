# Replay control

Browser replay viewers (`-d:emscripten -d:replayViewer`) can be driven by the page
that embeds them: seek, play, pause, speed, looping, camera, and queries that map
between the screen and the world. Gods of the Arena installs it; other games load
normally but report `ready() === false`.

The game side is `src/polyworld/replaycontrols.nim`. A game calls
`installReplayControl(transport, hooks)` once and `publishReplayControlFrame` after
presenting each frame. `ReplayControlHooks` supplies the game-specific parts:
ground height, picking, unit lookup and camera modes. The page side is
`src/polyworld/replay.html`.

## Viewer URL options

Options are read from the hash, then the query, like `replay`.

| Option | Effect |
| --- | --- |
| `embed=1` | Hides the in-canvas HUD (transport bar, scoreboard, minimap, panels) and keeps mouse, wheel, touch and key input from the game. Key presses are forwarded to the host instead. Seeks use 33 ms slices. |
| `loop=0` or `loop=1` | Overrides looping. Replay builds loop by default. |
| `seekSlice=MS` | Simulation time per frame while seeking. The default is 100 ms, or 33 ms with `embed=1`. |

Shorter slices keep the page responsive during long seeks but finish them later.
On an M-series Mac with a GPU, a cold seek over a 28,909-tick GotA match took
28 s at 12 ms, 17 s at 33 ms and 12 s at 100 ms.

## Same-origin hosts

`iframe.contentWindow.polyworldReplay` is synchronous. Screen positions are CSS
pixels in the viewer document. World positions are the game's render space; for
GotA that is `simulation / WorldScale`, centred on the map, with y up.

| Call | Result |
| --- | --- |
| `ready()` | `true` once the first controlled frame has been drawn. |
| `state()` | The latest frame: `tick`, `endTick`, `playing`, `seeking`, `speed`, `loop`, `seekId`, `seekTick`, `viewProjection` (16 floats, column-major), framebuffer `width`/`height`, `cssWidth`/`cssHeight`. |
| `onFrame(fn)` | Calls `fn(state)` after every presented frame. Returns an unsubscribe function. |
| `onKey(fn)` | With `embed=1`, calls `fn({event, key, code, altKey, ctrlKey, metaKey, shiftKey, repeat})` for key presses. |
| `seek(tick, seekId = 0)` | Starts an exact seek and keeps the play state. Frames report `seekId` and `seekTick` until another seek replaces it; the seek has landed when `seekId` matches, `seeking` is false and `tick === seekTick`. |
| `cancelSeek()` | Stops a seek, including a pending backward restore, on the last simulated tick. |
| `play()`, `pause()` | Play rewinds first when already at the end. |
| `setSpeed(x)` | Applies the fastest of 1, 2, 4 or 16 at or below `x` and returns it. |
| `setLoop(on)`, `setSeekSlice(ms)` | As the URL options. |
| `camera({mode, ...})` | `director`; `fixed` with `x`, `z` and optional `distance`; `follow` with unit `id`; `freeze` holds the current view. Every mode except `director` stops the automatic camera. |
| `freezeCamera()` | Same as `camera({mode: 'freeze'})`. |
| `project({x, y, z})` | Screen `{x, y}` in the last drawn frame, or `null` behind the camera. |
| `unproject({x, y})` | The drawn ground point `{x, y, z}` under a screen position, or `null`. |
| `groundY(x, z)` | Drawn ground height. |
| `pick({x, y})` | The unit drawn under a screen position, or 0. Dying units are not pickable. |
| `unit(id)` | `{x, y, z, seat, alive}` for the drawn position, or `null` when absent. `seat` is -1 for units no player controls. |

Overlays should reproject from `state().viewProjection` on every frame: the
director moves the camera continuously and units are interpolated between ticks.

```js
const replay = iframe.contentWindow.polyworldReplay;
replay.pause();
replay.seek(12000, 1);
replay.onFrame(frame => {
  if (frame.seekId === 1 && !frame.seeking) drawOverlay(frame.viewProjection);
});
```

## postMessage bridge

Cross-origin hosts post `{dst: 'coworld-replay', type, ...}` to the iframe. Only
messages from the parent window are accepted. Commands sent before the viewer is
ready run once it is.

| `type` | Fields |
| --- | --- |
| `seek` | `tick`, optional `seekId` |
| `cancelSeek`, `play`, `pause` | |
| `speed` | `speed` |
| `loop` | `loop` |
| `seekSlice` | `milliseconds` |
| `camera` | as `camera()` above |
| `project`, `unproject`, `pick`, `unit`, `state` | as above; `unit` takes `id` |
| `subscribe` | `tick: true` for tick events, `frame: true` for frame events |

Any command with a `requestId` is answered with
`{src: 'coworld-replay', type: 'result', requestId, result}` or `error`.

Outbound messages keep the existing `loading`, `phase`, `ready` and `error` types.
Hosts that subscribe also receive:

- `tick`: `{tick, endTick, playing, seeking, speed, loop, seekId, seekTick}`, sent
  at once when anything except the tick changes and at most every 100 ms while
  only the tick advances.
- `frame`: the full `state()` after every presented frame.
- `key`: forwarded key presses with `embed=1` (always sent; no subscription).

## Verification

`nim r tests/test_player.nim` and `nim r tests/test_replaycontrols.nim` cover the
transport changes and the exports natively. The browser test
(`coworld/tools/test_browser_with_playwright.py`, or `--control-only` for just
this part) checks a cold seek to the last tick for progress, exact seeks, cancel,
pause, speed, frozen cameras, projection round trips, picking, the postMessage
bridge and embed input handling. Page responsiveness during the seek is asserted
only with `--gpu` (hardware rendering through Metal): SwiftShader takes seconds
per frame late in a match, so there the timer gaps are only recorded.
