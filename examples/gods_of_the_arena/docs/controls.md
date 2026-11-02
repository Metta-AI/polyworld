# Human controls

Settings → Controls provides two bindings for each action. Click a binding,
then press a keyboard key or mouse button. Escape cancels capture, Backspace
clears the selected binding, and Reset bindings restores the defaults.
Assigning an occupied button clears its previous assignment. Settings are
saved locally with Save and Back.

| Action | Default bindings |
| --- | --- |
| Select / left click | Left mouse, Z |
| Drag camera / middle click | Middle mouse, X |
| Order / right click | Right mouse, C |
| Attack move | A |
| Stop movement and queued actions | S |
| Abilities | Q, W, E, R |
| Item slots beside abilities | F, G |
| Shop | B |
| Action camera | V |
| Pause offline playback | Space |
| Cancel targeting / game menu | Escape |
| Debug menu | F1 |
| Fullscreen | F11 |
| Pan camera | Arrow keys |
| Zoom | Mouse wheel, = and - |
| Upgrade ability / add to selection | Left or right Shift |
| Select-all modifier | Left or right Control, with Attack move |
| Toggle shading | T |
| Show occluded characters | O |
| Performance trace | F2 |
| Water debug panel (developer build) | F4 |

Z, X, and C perform mouse actions at the pointer's current position. Hold X
and move the pointer to drag the camera. Hold A for repeated attack moves;
releasing it leaves one attack move armed. Double-tap an item binding to
self-use a potion or return home with a portal scroll.

Stop cancels movement, chasing, queued casts, and portal channeling. It does
not disable automatic basic attacks. In multiplayer it follows the same
server-ordered command path as movement. Live multiplayer pause uses the
shared game-menu pause control instead of the offline playback shortcut.

Native display settings offer Windowed and Fullscreen. Windowed mode supports
common drawable resolutions from 1280 x 720 through 3840 x 2160, limited to
sizes that fit the current display. Fullscreen uses the desktop resolution
through Windy's single fullscreen API: an OS fullscreen Space on macOS and
a monitor-sized borderless window on Windows. It does not expose a separate
exclusive display mode. Browser builds only expose the fullscreen control,
since the browser manages window size and display resolution.
