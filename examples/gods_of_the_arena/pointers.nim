import
  windy,
  polyworld/displays

when defined(macosx) and not defined(emscripten):
  import windy/platforms/macos/macdefs

  objc:
    proc keyWindow(self: NSApplication): NSWindow
      ## Finds the game's focused native window.
    proc setMouseConfinementRect(self: NSWindow, x: NSRect)
      ## Confines the visible cursor using AppKit's window-relative rectangle.

  var
    confinedWindow: NSWindow
    confinedBounds: NSRect

proc releaseCursorConfinement*() =
  ## Restores normal pointer movement when GotA loses focus or closes.
  when defined(macosx) and not defined(emscripten):
    if confinedWindow.int != 0:
      confinedWindow.setMouseConfinementRect(NSRect())
      confinedWindow.ID.release()
      confinedWindow = NSWindow(0)
      confinedBounds = NSRect()

proc updateCursorConfinement*(window: Window) =
  ## Keeps GotA's visible pointer inside a focused native fullscreen window.
  when defined(macosx) and not defined(emscripten):
    if not window.focused or not window.isFullscreen or window.closeRequested:
      releaseCursorConfinement()
      return
    let native = NSApp.keyWindow()
    if native.int == 0:
      releaseCursorConfinement()
      return
    if native.int != confinedWindow.int:
      releaseCursorConfinement()
      confinedWindow = native
      confinedWindow.ID.retain()
    let bounds = native.contentView.bounds
    if bounds != confinedBounds:
      native.setMouseConfinementRect(bounds)
      confinedBounds = bounds
