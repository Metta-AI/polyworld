# Pausing and scaling clip playback

`ClipPlayer` keeps presentation time separate from the game's simulation clock.
Its `timeScale` defaults to one. Set it to `0.5` for half-speed animation or `2`
for double speed. Clip times and the active crossfade advance together, including
the outgoing clip, so changing speed does not distort transition timing.

```nim
player.timeScale = 0.5
player.paused = true
player.update(frameSeconds) # reapplies the frozen pose
player.paused = false
player.update(frameSeconds) # resumes at half speed
```

Pausing leaves the configured speed intact. A zero time scale also freezes the
clocks. Both cases still sample and apply the current pose, which matters when a
game reuses a node tree between character draws. `play` and `restart` remain
explicit controls and can change the selected clip or time while paused.

Rates must be finite and nonnegative. Reverse playback needs a separate decision
about one-shot chaining and is not silently approximated here. Continue passing
finite, nonnegative frame deltas to `update`. These controls never alter the
authoritative tick rate, commands, or replay simulation.

`nim r tests/test_animblend_controls.nim` verifies sampled poses, clock scaling,
pause/resume, crossfade continuity, one-shot chaining, and rejected rates without
requiring a graphics context.
