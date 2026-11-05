import std/unittest
import silky, vmath, windy
import polyworld/[menus, inputs]
import ../games/light_vs_dark/[lobbies, shortcuts, shortcutsettings]

suite "LvD shortcut settings integration":
  test "settings entry point accepts the shared home and match layout":
    static:
      doAssert compiles(block:
        let sk = Silky()
        let window: Window = nil
        var preferences = Preferences()
        discard sk.lvdSettingsPanel(window, preferences, "Polyworld LvD", vec2(0))
      )
  test "button adapter supports letters, digits, Escape, and ignores mouse":
    check shortcutKey(KeyB) == 'B'
    check shortcutKey(KeyP) == 'P'
    check shortcutKey(Key7) == '7'
    check shortcutKey(KeyEscape) == '\e'
    check shortcutKey(MouseLeft) == '\0'
  test "consumed sequence keys cannot trigger polled mouse aliases":
    var bindings = LvdControlProfile.defaults
    when declared(maskShortcutBindings):
      let masked = maskShortcutBindings(bindings, {KeyS, KeyA})
      check masked[PanInput] == [MouseMiddle, ButtonUnknown]
      check masked[AttackMoveInput] == [ButtonUnknown, ButtonUnknown]
      check bindings == LvdControlProfile.defaults
    else:
      check false

  test "native config roundtrip uses isolated app namespace":
    let app = "Polyworld LvD Shortcut Tests"
    var custom = DefaultShortcuts
    check custom.setShortcut(BuildBarracksShortcut, "Q7") == ""
    saveShortcuts(custom, app)
    check readShortcuts(app) == custom
    custom.resetShortcuts()
    saveShortcuts(custom, app)
    check readShortcuts(app) == DefaultShortcuts
  test "sequence editor keeps old assignment on duplicate and commits complete input":
    var editor: ShortcutEditor
    var bindings = DefaultShortcuts
    editor.beginEdit(BuildBarracksShortcut)
    check editor.editKey(bindings, 'T') == false
    check editor.editKey(bindings, 'P') == false
    check editor.error.len > 0
    check bindings == DefaultShortcuts
    editor.beginEdit(BuildBarracksShortcut)
    check editor.editKey(bindings, 'Q') == false
    check editor.editKey(bindings, '7') == true
    check bindings[BuildBarracksShortcut] == "Q7"
    editor.beginEdit(TrainPeonShortcut)
    check editor.editKey(bindings, '\e') == false
    check not editor.active
    check bindings[TrainPeonShortcut] == "TP"
