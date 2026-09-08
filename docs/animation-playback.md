# Clip playback controls

`ClipPlayer.timeScale` defaults to one and advances the incoming clip, outgoing
clip, and crossfade together. Use `0.5` for half speed, `2` for double speed, or
`0` to freeze time. `player.paused = true` freezes time without changing the rate.

Continue calling `update` while paused: it reapplies the frozen pose, including
when character draws share a mutable node tree. `play` and `restart` remain
explicit controls that can change the clip or time while paused.

Rates and frame deltas must be finite and nonnegative. Reverse playback is not
supported by forward one-shot chaining. These presentation controls never change
the simulation tick rate or replay commands.

Run `nim r tests/test_animblend_controls.nim` for sampled-pose verification.
