# Controlling animations

Set `player.paused = true` to pause and `false` to resume. Keep calling `update`
while paused so the pose is restored when characters share model data.

Set `player.timeScale` to `0.5` for half speed, `2` for double speed, or `0` to
hold still. Clip timing and fades follow the same speed. Speed and frame time
must be finite and nonnegative; reverse playback is not supported.

`player.seek(seconds)` shows the chosen pose immediately and ends any fade.
Looping clips wrap; one-shot clips stop at their last pose. Seeking keeps the
pause and speed settings. `play` and `restart` can also change a paused clip.

Changing clips during a fade starts from that player's current pose, including
when another character has just used the same model data.

Run `nim r tests/test_animblend_controls.nim`.
