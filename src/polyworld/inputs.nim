## Keyboard aliases for mouse buttons.

import windy

const
  MouseLeftKey* = KeyA
  MouseRightKey* = KeyD
  MouseMiddleKey* = KeyS

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

proc mouseButton*(buttons: ButtonView, button: Button, aliases = true): bool =
  ## Checks a physical mouse button, optionally accepting its keyboard alias.
  buttons[button] or (aliases and buttons[mouseKey(button)])

proc mousePressed*(window: Window, button: Button, aliases = true): bool =
  ## True when the mouse button or its key alias was pressed this frame.
  mouseButton(window.buttonPressed, button, aliases)

proc mouseDown*(window: Window, button: Button, aliases = true): bool =
  ## True while the mouse button or its key alias is held.
  mouseButton(window.buttonDown, button, aliases)

proc mouseReleased*(window: Window, button: Button, aliases = true): bool =
  ## True when the mouse button or its key alias was released this frame.
  mouseButton(window.buttonReleased, button, aliases)
