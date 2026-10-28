## Keyboard aliases for mouse buttons.

import windy

const
  MouseLeftKey* = KeyA
  MouseRightKey* = KeyD
  MouseMiddleKey* = KeyS

var mouseKeyAliasesEnabled* = true

proc mouseKey(button: Button): Button =
  ## Returns the keyboard stand-in for a mouse button.
  case button
  of MouseLeft:
    MouseLeftKey
  of MouseRight:
    MouseRightKey
  of MouseMiddle:
    MouseMiddleKey
  else:
    button

proc mousePressed*(window: Window, button: Button): bool =
  ## True when the mouse button or its key alias was pressed this frame.
  window.buttonPressed[button] or
    (mouseKeyAliasesEnabled and window.buttonPressed[mouseKey(button)])

proc mouseDown*(window: Window, button: Button): bool =
  ## True while the mouse button or its key alias is held.
  window.buttonDown[button] or
    (mouseKeyAliasesEnabled and window.buttonDown[mouseKey(button)])

proc mouseReleased*(window: Window, button: Button): bool =
  ## True when the mouse button or its key alias was released this frame.
  window.buttonReleased[button] or
    (mouseKeyAliasesEnabled and window.buttonReleased[mouseKey(button)])
