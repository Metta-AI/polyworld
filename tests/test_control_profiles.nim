import silky, vmath, windy
import polyworld/[inputs, menus]

block:
  doAssert DefaultControlProfile.actions.len == ord(high(InputAction)) + 1
  for i, row in DefaultControlProfile.actions:
    doAssert row.action == InputAction(i)
    doAssert row.label == $InputAction(i)
  doAssert DefaultControlProfile.defaults == DefaultBindings

block:
  var defaults: InputBindings
  defaults[SelectInput] = [MouseLeft, KeyA]
  defaults[PanInput] = [MouseMiddle, KeyS]
  let controls = ControlProfile(
    actions: @[
      ControlBinding(action: PanInput, label: "Move camera"),
      ControlBinding(action: SelectInput, label: "Select units")
    ],
    defaults: defaults
  )
  var preferences = Preferences(name: "Test player", fps: 120)
  preferences.resetBindings(controls)
  doAssert preferences.bindings == defaults
  doAssert preferences.name == "Test player"
  doAssert preferences.fps == 120
  doAssert controls.actions[0].action == PanInput
  doAssert controls.actions[0].label == "Move camera"
  doAssert controls.actions.len == 2
  preferences.resetBindings()
  doAssert preferences.bindings == DefaultBindings
  static:
    doAssert compiles(block:
      let sk = Silky()
      let window: Window = nil
      var preferences = Preferences()
      discard sk.settingsPanel(window, preferences, "test", vec2(0),
        controls = ControlProfile())
    )

echo "Shared control profile tests passed"
