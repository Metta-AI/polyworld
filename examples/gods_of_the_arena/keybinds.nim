## One binding map for gameplay input and the labels that teach it.
import std/[os, strutils], windy

type
  ControlPreset* = enum
    MouseControls, WasdControls, MouseKeyControls
  PlayAction* = enum
    SpellQ = "spell1", SpellW = "spell2", SpellE = "spell3", SpellR = "spell4",
    AttackMove = "attackmove", Stop = "stop", CenterHero = "center",
    FollowHero = "follow", PanCamera = "pan"

var
  controlPreset* = MouseControls
  bindings: array[PlayAction, Button]
  heldPlayButtons*: set[Button]
  pressedPlayButtons*, releasedPlayButtons*: set[Button]
  pendingPresses, pendingReleases: set[Button]

proc capturePlayPress*(button: Button): bool =
  ## Keep events across Asyncify's frame-end yield; ignore OS key repeat.
  result = button notin heldPlayButtons
  if result: pendingPresses.incl button
  heldPlayButtons.incl button

proc capturePlayRelease*(button: Button) =
  heldPlayButtons.excl button
  pendingReleases.incl button

proc clearPlayKeys*() =
  heldPlayButtons = {}
  pressedPlayButtons = {}
  releasedPlayButtons = {}
  pendingPresses = {}
  pendingReleases = {}

proc discardPlayPresses*() =
  ## A modal/pause transition must not replay earlier command presses.
  pressedPlayButtons = {}
  pendingPresses = {}

proc beginPlayInputFrame*() =
  pressedPlayButtons = pendingPresses
  releasedPlayButtons = pendingReleases
  pendingPresses = {}
  pendingReleases = {}

when defined(emscripten):
  # Windy's browser key table omits F1-F12. Collect them without re-entering
  # a suspended WASM frame, then dispatch through the ordinary callbacks.
  {.emit: """
  #include <emscripten.h>
  EM_JS(void, gota_install_function_keys, (), {
    const state = {pressed:0, released:0, held:0};
    Module.gotaFunctionKeys = state;
    for (const type of ['keydown','keyup']) {
      document.addEventListener(type, function(event) {
        if (document.activeElement !== Module.canvas || !/^F([1-9]|1[0-2])$/.test(event.code)) return;
        const bit = 1 << (Number(event.code.slice(1)) - 1);
        if (type === 'keydown') {
          if (!(state.held & bit)) state.pressed |= bit;
          state.held |= bit;
        } else {
          state.released |= bit;
          state.held &= ~bit;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
    }
    window.addEventListener('blur', () => {
      state.released |= state.held;
      state.pressed = state.held = 0;
    });
  });
  EM_JS(int, gota_take_function_keys, (), {
    const state = Module.gotaFunctionKeys;
    const result = state.pressed | (state.released << 12);
    state.pressed = state.released = 0;
    return result;
  });
  """.}
  proc installFunctionKeys() {.importc: "gota_install_function_keys", nodecl.}
  proc installBrowserKeys*() = installFunctionKeys()
  proc takeFunctionKeys(): cint {.importc: "gota_take_function_keys", nodecl.}
  proc pollBrowserKeys*(window: Window) =
    let events = takeFunctionKeys()
    for i in 0 ..< 12:
      let key = Button(KeyF1.ord + i)
      if (events and (1 shl i)) != 0: window.onButtonPress(key)
      if (events and (1 shl (i + 12))) != 0: window.onButtonRelease(key)
else:
  proc installBrowserKeys*() = discard
  proc pollBrowserKeys*(window: Window) = discard

proc setControlPreset*(preset: ControlPreset) =
  controlPreset = preset
  bindings = [KeyQ, KeyW, KeyE, KeyR, KeyA, KeyS, KeyF1, KeyL, KeyC]
  if preset == WasdControls:
    bindings[SpellQ] = Key1
    bindings[SpellW] = Key2
    bindings[SpellE] = Key3
    bindings[SpellR] = Key4
    bindings[AttackMove] = KeyQ
    bindings[Stop] = KeyX
  elif preset == MouseKeyControls:
    bindings[AttackMove] = KeyZ
    bindings[Stop] = KeyX

setControlPreset(MouseControls)

proc playKey*(action: PlayAction): Button = bindings[action]
proc abilityKey*(slot: int): Button = bindings[PlayAction(slot)]
proc keyLabel*(action: PlayAction): string =
  result = $bindings[action]
  result.removePrefix("Key")
  result = result.toUpperAscii()
proc abilityKeyLabel*(slot: int): string = keyLabel(PlayAction(slot))

proc loadPlayKeys*(path: string) =
  if not fileExists(path): raise newException(IOError, "Key file not found: " & path)
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let pair = line.split('=', 1)
    if pair.len != 2: raise newException(ValueError, "Expected action = KeyName: " & line)
    let action = parseEnum[PlayAction](pair[0].strip())
    bindings[action] = parseEnum[Button](pair[1].strip())

proc mouseAlias(button: Button): Button =
  case button
  of MouseLeft: KeyA
  of MouseRight: KeyD
  of MouseMiddle: KeyS
  else: button

proc mousePressed*(window: Window, button: Button): bool =
  button in pressedPlayButtons or window.buttonPressed[button] or
    (controlPreset == MouseKeyControls and mouseAlias(button) in pressedPlayButtons)
proc mouseDown*(window: Window, button: Button): bool =
  button in heldPlayButtons or window.buttonDown[button] or
    (controlPreset == MouseKeyControls and mouseAlias(button) in heldPlayButtons)
proc mouseReleased*(window: Window, button: Button): bool =
  button in releasedPlayButtons or window.buttonReleased[button] or
    (controlPreset == MouseKeyControls and mouseAlias(button) in releasedPlayButtons)
