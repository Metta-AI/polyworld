## Keyboard aliases for mouse buttons.

import std/strutils, windy

const
  MouseLeftKey* = KeyA
  MouseRightKey* = KeyD
  MouseMiddleKey* = KeyS

type
  InputAction* = enum
    SelectInput = "Select / left click"
    PanInput = "Drag camera / middle click"
    OrderInput = "Order / right click"
    AttackMoveInput = "Attack move"
    StopInput = "Stop"
    AbilityOneInput = "Ability Q"
    AbilityTwoInput = "Ability W"
    AbilityThreeInput = "Ability E"
    AbilityFourInput = "Ultimate R"
    ItemOneInput = "Item slot 1"
    ItemTwoInput = "Item slot 2"
    ShopInput = "Shop"
    CameraInput = "Action camera"
    PauseInput = "Pause playback"
    MenuInput = "Cancel / game menu"
    DebugInput = "Debug menu"
    FullscreenInput = "Fullscreen"
    PanLeftInput = "Pan left"
    PanRightInput = "Pan right"
    PanUpInput = "Pan up"
    PanDownInput = "Pan down"
    ShiftInput = "Upgrade / add selection"
    ControlInput = "Select-all modifier"
    ShadingInput = "Toggle shading"
    OcclusionInput = "Occluded characters"
    TraceInput = "Performance trace"
    ZoomInInput = "Zoom in"
    ZoomOutInput = "Zoom out"
    WaterPanelInput = "Water debug panel"
  InputBindings* = array[InputAction, array[2, Button]]

const
  DefaultBindings*: InputBindings = [
    [MouseLeft, KeyZ], [MouseMiddle, KeyX], [MouseRight, KeyC],
    [KeyA, ButtonUnknown], [KeyS, ButtonUnknown],
    [KeyQ, ButtonUnknown], [KeyW, ButtonUnknown],
    [KeyE, ButtonUnknown], [KeyR, ButtonUnknown],
    [KeyF, ButtonUnknown], [KeyG, ButtonUnknown],
    [KeyB, ButtonUnknown], [KeyV, ButtonUnknown],
    [KeySpace, ButtonUnknown], [KeyEscape, ButtonUnknown],
    [KeyF1, ButtonUnknown], [KeyF11, ButtonUnknown],
    [KeyLeft, ButtonUnknown], [KeyRight, ButtonUnknown],
    [KeyUp, ButtonUnknown], [KeyDown, ButtonUnknown],
    [KeyLeftShift, KeyRightShift], [KeyLeftControl, KeyRightControl],
    [KeyT, ButtonUnknown], [KeyO, ButtonUnknown],
    [KeyF2, ButtonUnknown], [KeyEqual, ButtonUnknown],
    [KeyMinus, ButtonUnknown], [KeyF4, ButtonUnknown]
  ]

var
  mouseKeyAliasesEnabled* = true
  customBindingsEnabled* = false
  inputBindings* = DefaultBindings
  bindingCapture* = false

proc matches*(bindings: InputBindings, action: InputAction, key: Button): bool =
  ## Checks either binding, excluding the unbound sentinel.
  key != ButtonUnknown and key in bindings[action]

proc matches*(action: InputAction, key: Button): bool =
  ## Checks the current bindings for an input event.
  not bindingCapture and inputBindings.matches(action, key)

proc actionDown*(window: Window, action: InputAction): bool =
  ## Reads a held action from either of its two bindings.
  if bindingCapture:
    return false
  for key in inputBindings[action]:
    if key != ButtonUnknown and window.buttonDown[key]:
      return true

proc actionPressed*(window: Window, action: InputAction): bool =
  ## Reads an action pressed this frame without key-repeat toggling.
  if bindingCapture:
    return false
  for key in inputBindings[action]:
    if key != ButtonUnknown and window.buttonPressed[key]:
      return true

proc actionReleased*(window: Window, action: InputAction): bool =
  ## Reports release only after both bindings are up.
  if window.actionDown(action) or bindingCapture:
    return false
  for key in inputBindings[action]:
    if key != ButtonUnknown and window.buttonReleased[key]:
      return true

proc keyboardPanPressed*(window: Window): bool =
  ## Allows a keyboard drag to begin even while the pointer is over the HUD.
  for key in inputBindings[PanInput]:
    if key >= Key0 and window.buttonPressed[key] and not bindingCapture:
      return true

proc keyboardPanDown*(window: Window): bool =
  ## Keeps a keyboard drag active while the pointer crosses the HUD.
  for key in inputBindings[PanInput]:
    if key >= Key0 and window.buttonDown[key] and not bindingCapture:
      return true

proc bindingLabel*(key: Button): string =
  ## Formats a keyboard key or mouse button for the settings and HUD.
  case key
  of ButtonUnknown: "Unbound"
  of MouseLeft: "Mouse left"
  of MouseMiddle: "Mouse middle"
  of MouseRight: "Mouse right"
  of MouseButton4: "Mouse 4"
  of MouseButton5: "Mouse 5"
  else: ($key).replace("Key", "")

proc actionLabel*(action: InputAction): string =
  ## Returns the first configured hotkey for a compact HUD label.
  for key in inputBindings[action]:
    if key != ButtonUnknown:
      return key.bindingLabel
  "-"

proc bindInput*(
    bindings: var InputBindings,
    action: InputAction,
    slot: int,
    key: Button
) =
  ## Assigns a binding and removes conflicting assignments.
  assert slot in 0 .. 1
  if key != ButtonUnknown:
    for other in InputAction:
      for i in 0 .. 1:
        if bindings[other][i] == key:
          bindings[other][i] = ButtonUnknown
  bindings[action][slot] = key

proc mouseAction(button: Button): InputAction =
  ## Maps a logical mouse button to its configurable action.
  case button
  of MouseMiddle: PanInput
  of MouseRight: OrderInput
  else: SelectInput

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
  if customBindingsEnabled and button in {MouseLeft, MouseMiddle, MouseRight}:
    return window.actionPressed(mouseAction(button))
  window.buttonPressed[button] or
    (mouseKeyAliasesEnabled and window.buttonPressed[mouseKey(button)])

proc mouseDown*(window: Window, button: Button): bool =
  ## True while the mouse button or its key alias is held.
  if customBindingsEnabled and button in {MouseLeft, MouseMiddle, MouseRight}:
    return window.actionDown(mouseAction(button))
  window.buttonDown[button] or
    (mouseKeyAliasesEnabled and window.buttonDown[mouseKey(button)])

proc mouseReleased*(window: Window, button: Button): bool =
  ## True when the mouse button or its key alias was released this frame.
  if customBindingsEnabled and button in {MouseLeft, MouseMiddle, MouseRight}:
    return window.actionReleased(mouseAction(button))
  window.buttonReleased[button] or
    (mouseKeyAliasesEnabled and window.buttonReleased[mouseKey(button)])
