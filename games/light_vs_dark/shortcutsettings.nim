## LvD sequence editor and platform-neutral Windy configuration storage.
import silky, vmath, windy
import polyworld/[chrome, inputs, menus]
import shortcuts
export shortcuts

type ShortcutEditor* = object
  active*: bool
  action*: ShortcutAction
  draft*: string
  error*: string

var
  currentShortcuts* = DefaultShortcuts
  shortcutEditor: ShortcutEditor
  captureHeld: set[Button]
  shortcutSettingsError*: string

proc maskShortcutBindings*(bindings: InputBindings,
    consumed: set[Button]): InputBindings =
  ## Keep sequence strokes from becoming camera/selection aliases in polling.
  result = bindings
  for action in InputAction:
    for slot in 0 .. 1:
      if result[action][slot] in consumed:
        result[action][slot] = ButtonUnknown

proc shortcutKey*(button: Button): char =
  # Windy does not promise alphabetically contiguous enum ordinals.
  let name = $button
  if name.len == 4 and name[0 .. 2] == "Key" and
      name[3] in {'A'..'Z', '0'..'9'}:
    return name[3]
  if button == KeyEscape: return '\e'

proc readShortcuts*(app = "Polyworld LvD"): ShortcutBindings =
  decodeShortcuts(getConfig(app, "hotkeys.json"))

proc saveShortcuts*(bindings: ShortcutBindings, app = "Polyworld LvD") =
  setConfig(app, "hotkeys.json", encodeShortcuts(bindings))

proc loadLvdShortcuts*() =
  shortcutSettingsError = ""
  try: currentShortcuts = readShortcuts()
  except CatchableError:
    currentShortcuts = DefaultShortcuts
    shortcutSettingsError = getCurrentExceptionMsg()

proc beginEdit*(editor: var ShortcutEditor, action: ShortcutAction) =
  editor = ShortcutEditor(active: true, action: action)

proc editKey*(editor: var ShortcutEditor, bindings: var ShortcutBindings,
    key: char): bool =
  if not editor.active: return false
  if key == '\e':
    editor.active = false
    editor.draft = ""
    return false
  if key notin {'A'..'Z', '0'..'9'}: return false
  editor.draft.add key
  if editor.draft.len == 2:
    editor.error = bindings.setShortcut(editor.action, editor.draft)
    editor.active = false
    result = editor.error.len == 0

proc endShortcutEditing*() =
  if shortcutEditor.active: bindingCapture = false
  shortcutEditor = ShortcutEditor()
  captureHeld = {}

proc persistCurrent() =
  try:
    currentShortcuts.saveShortcuts()
    shortcutSettingsError = ""
  except CatchableError:
    shortcutSettingsError = getCurrentExceptionMsg()

proc drawShortcutRows(sk: Silky, window: Window, origin: Vec2) =
  if shortcutEditor.active:
    for button in Button:
      if not window.buttonDown[button]: captureHeld.excl button
      let key = shortcutKey(button)
      if key != '\0' and window.buttonPressed[button] and button notin captureHeld:
        captureHeld.incl button
        if shortcutEditor.editKey(currentShortcuts, key): persistCurrent()
        if not shortcutEditor.active:
          bindingCapture = false
          break
  sk.drawLabel("BUILD / TRAIN SEQUENCES", origin, vec2(720, 36),
    sk.theme.defaultTextColor)
  sk.drawLabel("Press two keys in order, not together. 1.25s timeout; Esc cancels.",
    origin + vec2(0, 36), vec2(720, 36), sk.theme.defaultTextColor)
  let message =
    if shortcutEditor.active: "Type both keys for " & shortcutLabel(shortcutEditor.action) & "; Esc cancels."
    elif shortcutSettingsError.len > 0: shortcutSettingsError
    elif shortcutEditor.error.len > 0: shortcutEditor.error
    else: "Click a sequence to edit both keys. Duplicate sequences are rejected."
  sk.drawLabel(message, origin + vec2(0, 72), vec2(720, 36),
    sk.theme.defaultTextColor)
  for action in ShortcutAction:
    let row = origin + vec2(0, 112 + action.ord.float32 * 38)
    sk.drawLabel(shortcutLabel(action), row, vec2(410, 36), sk.theme.defaultTextColor)
    sk.at = row + vec2(420, 0)
    let sequence = currentShortcuts[action]
    let label =
      if shortcutEditor.active and shortcutEditor.action == action:
        (if shortcutEditor.draft.len == 0: "First key..." else: shortcutEditor.draft & " then ...")
      else: $sequence[0] & "  " & $sequence[1]
    button label, not bindingCapture:
      shortcutEditor.beginEdit(action)
      captureHeld = {}
      for held in Button:
        if window.buttonDown[held]: captureHeld.incl held
      bindingCapture = true
  sk.at = origin + vec2(420, 112 + (ShortcutAction.high.ord + 1).float32 * 38)
  button "Reset build / train", not bindingCapture:
    currentShortcuts.resetShortcuts()
    shortcutEditor.error = ""
    persistCurrent()

proc lvdShortcutExtension*(): ControlExtension =
  ControlExtension(draw: drawShortcutRows,
    capturing: proc(): bool = shortcutEditor.active)
