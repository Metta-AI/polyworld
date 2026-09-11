# Game menu example

Run a character panel, settings page, and quest panel:

```sh
nim r examples/ui_gallery/build_atlas.nim
nim r examples/ui_gallery/gallery.nim
```

Run these commands from the Polyworld root after installing dependencies. The
atlas builder uses Silky's example images and fonts from `../silky`; pass another
Silky directory as its first argument if needed. It writes to `tmp/ui-gallery`.

Try typing a name, changing the volume, choosing a theme, and claiming a quest
reward. Resize the window to see the panels scroll. Copy the controls and replace
the example actions with your game's actions.

`gameuis.gameArea` leaves room for the edge spacing you supply and replay
controls. `fitPanel` keeps a panel in that space, shrinking oversized panels.
Supply insets as left, top, right, and bottom, in UI units; cutouts are not
detected automatically. Content taller than the fitted panel needs a scrolling
control.

The example uses the upstream Silky and Windy versions in `nimby.lock`; it does
not require dependency forks.
