import
  std/[os, strutils],
  chroma, jsony, pixie, silky, vmath, windy,
  chrome, displays, gameuis, inputs, policies, rtscameras

type
  MenusError* = object of CatchableError
  MenuPage* = enum
    HomeMenu, SingleMenu, MultiplayerMenu, LobbyMenu, SettingsMenu
  SettingsTab = enum
    DisplaySettings = "Display"
    SoundSettings = "Sound"
    ControlsSettings = "Controls"
    NetworkingSettings = "Networking"
  Preferences* = object
    name*: string
    server*: string = "ws://127.0.0.1:8090/ws"
    fullscreen*: bool
    windowMode*: WindowMode
    resolution*: WindowResolution
    fps*: int = 60
    interpolation*: bool = true
    edgeScrolling*: EdgeScrollMode = FullscreenEdgeScroll
    bindings*: InputBindings = DefaultBindings
    soundMuted*: bool
    mainVolume*: int = 100
    musicVolume*: int = 100
    fxVolume*: int = 100
    uiVolume*: int = 100
  LocalPolicy* = object
    name*, bytes*: string

const
  MenuInk* = rgbx(222, 231, 228, 255)
  MenuMuted* = rgbx(137, 158, 150, 255)
  MenuAccent* = rgbx(184, 215, 139, 255)

var
  settingsTab: SettingsTab
  captureAction: InputAction
  captureSlot: int

when defined(emscripten):
  {.emit: """
  #include <emscripten.h>
  EM_ASYNC_JS(int, polyworldPickPolicy, (), {
    return await new Promise(resolve => {
      const input = document.createElement('input');
      input.type = 'file'; input.accept = '.bas,.zip';
      input.style.display = 'none';
      document.body.appendChild(input);
      let finished = false;
      const done = value => {
        if (finished) return;
        finished = true; input.remove(); resolve(value);
      };
      input.oncancel = () => done(0);
      input.onchange = async () => {
        const file = input.files[0];
        if (!file) return done(0);
        if (file.size > 16 * 1024 * 1024) return done(-1);
        try {
          const bytes = new Uint8Array(await file.arrayBuffer());
          FS.writeFile('/tmp/polyworld-local-policy.bin', bytes);
          FS.writeFile('/tmp/polyworld-local-policy.name', file.name);
          done(1);
        } catch (e) { done(-2); }
      };
      input.click();
    });
  });
  EM_JS(void, polyworldInvite, (char* output, int length), {
    const url = new URL(window.location.href);
    stringToUTF8(url.origin + url.pathname, output, length);
  });
  EM_JS(void, polyworldParameter, (const char* name, char* output, int length), {
    const value = new URLSearchParams(window.location.search).get(UTF8ToString(name));
    stringToUTF8(value || '', output, length);
  });
  EM_JS(void, polyworldCopyInvite, (const char* text), {
    navigator.clipboard.writeText(UTF8ToString(text));
  });
  EM_JS(void, polyworldSaveReplay, (const char* bytes, int length), {
    const blob = new Blob([HEAPU8.slice(bytes, bytes + length)],
      {type: 'application/octet-stream'});
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = 'gota.replay';
    document.body.appendChild(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  });
  """.}
  proc polyworldPickPolicy(): cint {.importc, nodecl.}
  proc polyworldInvite(output: cstring, length: cint) {.importc, nodecl.}
  proc polyworldParameter(
    name, output: cstring, length: cint
  ) {.importc, nodecl.}
  proc polyworldCopyInvite(text: cstring) {.importc, nodecl.}
  proc polyworldSaveReplay(bytes: cstring, length: cint) {.importc, nodecl.}

proc saveReplayFile*(bytes: string) =
  ## Saves an ordinary replay locally without uploading its contents.
  when defined(emscripten):
    polyworldSaveReplay(bytes.cstring, cint(bytes.len))
  else:
    let path = saveFileDialog("Save replay", @[
      FileDialogFilter(name: "Polyworld replay", extensions: "replay")
    ])
    if path.len > 0:
      try:
        writeFile(path, bytes)
      except IOError, OSError:
        raise newException(MenusError, "Cannot save replay: " & getCurrentExceptionMsg())

proc readPreferences*(app: string): Preferences =
  ## Loads native or browser settings through Windy's configuration storage.
  let bytes = getConfig(app, "settings.json")
  if bytes.len == 0:
    return Preferences()
  try:
    result = bytes.fromJson(Preferences)
  except JsonError as error:
    raise newException(MenusError, "Cannot read settings: " & error.msg)
  if result.windowMode == BorderlessWindow:
    result.windowMode = Fullscreen
  result.fps = clamp(result.fps, 0, 240)
  result.mainVolume = clamp(result.mainVolume, 0, 100)
  result.musicVolume = clamp(result.musicVolume, 0, 100)
  result.fxVolume = clamp(result.fxVolume, 0, 100)
  result.uiVolume = clamp(result.uiVolume, 0, 100)
  if result.name.len > 64:
    result.name.setLen(64)

proc savePreferences*(preferences: Preferences, app: string) =
  ## Saves ordinary preferences without bot data or reconnect secrets.
  setConfig(app, "settings.json", preferences.toJson())

proc applyPreferences*(preferences: Preferences, window: Window) =
  ## Applies shared presentation settings to the existing window.
  inputBindings = preferences.bindings
  when defined(emscripten):
    window.setFullscreen(preferences.fullscreen)
  else:
    window.configureWindow(preferences.windowMode, preferences.resolution)
  framePaceHz = preferences.fps
  interpolateVisuals = preferences.interpolation

proc selectPolicy*(): LocalPolicy =
  ## Reads a local policy into process memory without uploading it anywhere.
  when defined(emscripten):
    let code = polyworldPickPolicy()
    if code == 0:
      return
    if code < 0:
      raise newException(PolicyError, "Cannot read policy, maximum size is 16 MiB")
    result.bytes = readPolicyBytes("/tmp/polyworld-local-policy.bin")
    result.name = readFile("/tmp/polyworld-local-policy.name")
    removeFile("/tmp/polyworld-local-policy.bin")
    removeFile("/tmp/polyworld-local-policy.name")
  else:
    let path = openFileDialog("Choose local bot", @[
      FileDialogFilter(name: "BASIC policy or package", extensions: "bas,zip")
    ])
    if path.len == 0:
      return
    result.name = path.extractFilename()
    result.bytes = readPolicyBytes(path)
  discard loadPolicy(result.bytes)

proc inviteBase*(): string =
  ## Returns the browser's game URL for an invite, or a native URI prefix.
  when defined(emscripten):
    result = newString(4096)
    polyworldInvite(cast[cstring](result[0].addr), 4096)
    result.setLen(result.find('\0'))
  else:
    result = "polyworld://join"

proc inviteParameter*(name: string): string =
  ## Reads an invitation parameter without treating it as a local bot URL.
  when defined(emscripten):
    result = newString(4096)
    polyworldParameter(name.cstring, cast[cstring](result[0].addr), 4096)
    result.setLen(result.find('\0'))

proc copyInvite*(text: string) =
  ## Copies an invitation using the platform clipboard.
  when defined(emscripten):
    polyworldCopyInvite(text.cstring)
  else:
    setClipboardString(text)

proc menuLabel*(
    sk: Silky, text: string, position: Vec2,
    width = 580.0'f, color = MenuInk, font = "Default"
) =
  ## Draws a consistent label on any game's frontend.
  sk.drawLabel(text, position, vec2(width, 28), color, font)

proc menuButton*(
    sk: Silky, window: Window, text: string, position: Vec2,
    width = 280.0'f, enabled = true
): bool =
  ## Draws a shared menu button with a predictable pointer hit area.
  let
    size = vec2(width, 36)
    hovered = sk.mousePos.x >= position.x and
      sk.mousePos.y >= position.y and sk.mousePos.x < position.x + size.x and
      sk.mousePos.y < position.y + size.y
    color =
      if not enabled: rgbx(29, 37, 35, 255)
      elif hovered: rgbx(66, 83, 73, 255)
      else: rgbx(41, 54, 48, 255)
  sk.drawRect(position, size, color)
  sk.drawLabel(
    text, position, size, if enabled: MenuInk else: MenuMuted,
    "Default", CenterAlign
  )
  enabled and hovered and window.buttonPressed[MouseLeft]

proc menuInput*(
    sk: Silky, window: Window, id: string, value: var string,
    position: Vec2, width = 280.0'f, height = 36.0'f,
    multiline = false
) =
  ## Draws an editable field using Silky's native text selection behavior.
  sk.at = position
  sk.textBox(
    window, id, value, width, height,
    wrapWords = multiline, singleLine = not multiline
  )

proc beginMenu*(sk: Silky, window: Window, title, subtitle: string): Vec2 =
  ## Starts a shared menu frame scaled to fit smaller windows.
  sk.uiScale = max(0.7'f, min(window.size.x.float32 / 1150,
    window.size.y.float32 / 880))
  sk.beginUi(window, window.size)
  sk.mousePos = window.mousePos.vec2 / sk.uiScale
  sk.clearScreen(rgbx(20, 29, 27, 255))
  let size = window.size.vec2 / sk.uiScale
  result = vec2(max(24.0'f, (size.x - 1040) / 2), 28)
  sk.menuLabel(title, result, color = MenuAccent, font = "H1")
  sk.menuLabel(subtitle, result + vec2(0, 42), width = 1040, color = MenuMuted)
  result.y += 92

proc beginSettings*(
    sk: Silky, window: Window, headerHeight = 0.0'f
): Vec2 =
  ## Centers the shared settings panel at a readable scale.
  sk.uiScale = max(0.1'f, min(
    window.size.x.float32 / 800,
    window.size.y.float32 / (540 + headerHeight)
  ))
  sk.beginUi(window, window.size)
  sk.clearScreen(rgbx(0, 0, 0, 255))
  result = (window.size.vec2 / sk.uiScale - vec2(720, 440)) * 0.5'f
  result.y += headerHeight / 2

proc beginOverlay*(sk: Silky, window: Window, size: Vec2): Vec2 =
  ## Centers a modal over the rendered game without clearing its framebuffer.
  sk.uiScale = max(0.1'f, min(
    window.size.x.float32 / 1000,
    window.size.y.float32 / 800
  ))
  sk.beginUi(window, window.size)
  sk.textStyle = "Default"
  let view = window.size.vec2 / sk.uiScale
  sk.drawRect(vec2(0), view, rgbx(0, 0, 0, 110))
  result = (view - size) * 0.5'f

proc bindingsPanel(
    sk: Silky,
    window: Window,
    preferences: var Preferences,
    origin: Vec2
) =
  ## Edits two bindings per action using the existing Silky buttons.
  let capturing = bindingCapture
  if capturing:
    for key in Button:
      if key in {ButtonUnknown, DoubleClick, TripleClick, QuadrupleClick}:
        continue
      if window.buttonPressed[key]:
        if key != KeyEscape:
          preferences.bindings.bindInput(
            captureAction,
            captureSlot,
            if key == KeyBackspace: ButtonUnknown else: key
          )
        bindingCapture = false
        break
  sk.drawLabel(
    if capturing: "Press a key or mouse button. Esc cancels; Backspace clears."
    else: "Click a binding to change it. Conflicting bindings are cleared.",
    origin + vec2(0, 49), vec2(720, 34), sk.theme.defaultTextColor
  )
  frame "Control bindings", origin + vec2(0, 90), vec2(720, 304):
    sk.startCurrentChildren()
    let listOrigin = sk.at
    for action in InputAction:
      let row = listOrigin + vec2(0, action.ord.float32 * 38)
      sk.drawLabel($action, row, vec2(295, 36), sk.theme.defaultTextColor)
      for slot in 0 .. 1:
        sk.at = row + vec2((300 + slot * 190).float32, 0)
        let label =
          if capturing and action == captureAction and slot == captureSlot:
            "Press a button..."
          else:
            preferences.bindings[action][slot].bindingLabel
        button label, not capturing:
          captureAction = action
          captureSlot = slot
          bindingCapture = true
  sk.at = origin + vec2(500, 408)
  button "Reset bindings", not capturing:
    preferences.bindings = DefaultBindings

proc volumeSlider(
  sk: Silky,
  window: Window,
  caption: string,
  volume: var int,
  origin: Vec2
) =
  ## Edits a saved volume percentage with the standard Silky slider.
  sk.drawLabel(caption, origin, vec2(210, 36), sk.theme.defaultTextColor)
  sk.pushLayout(
    origin + vec2(210, 0),
    vec2(420 + sk.theme.padding.float32 * 3, 36)
  )
  scrubber("volume" & caption, volume, 0, 100)
  sk.popLayout()
  sk.drawLabel(
    $volume & "%",
    origin + vec2(645, 0),
    vec2(75, 36),
    sk.theme.defaultTextColor
  )

proc settingsPanel*(
    sk: Silky, window: Window, preferences: var Preferences,
    app: string, origin: Vec2, title = "Settings"
): bool =
  ## Edits preferences with the existing Silky theme and widgets.
  when defined(emscripten):
    preferences.fullscreen = window.isFullscreen
  else:
    preferences.windowMode = window.windowMode
  let previous = preferences
  sk.draw9Patch(
    "window.9patch",
    sk.theme.windowPatch,
    origin - vec2(24),
    vec2(768, 488)
  )
  if title.len > 0:
    sk.drawLabel(title, origin, vec2(720, 40),
      sk.theme.defaultTextColor, "H1")
  let
    tabsLeft = if title.len > 0: 160.0'f else: 0.0'f
    tabCount = ord(high(SettingsTab)) + 1
    tabWidth = (720 - tabsLeft - (tabCount - 1).float32 * 8) /
      tabCount.float32
  for page in SettingsTab:
    let
      tab = GameUiPanel(
        origin: origin + vec2(tabsLeft + page.ord.float32 * (tabWidth + 8), 0),
        size: vec2(tabWidth, 40)
      )
      interaction = sk.interact(
        rect(tab.origin, tab.size), not bindingCapture, false
      )
    if interaction == Released:
      settingsTab = page
    let selected = settingsTab == page
    sk.drawTab(tab, selected, interaction in {Hovered, Pressed, Held})
    sk.drawLabel(
      $page,
      tab.origin,
      tab.size,
      if selected: sk.theme.defaultTextColor else: sk.theme.disabledTextColor,
      "Default",
      CenterAlign
    )
  case settingsTab
  of SoundSettings:
    sk.at = origin + vec2(0, 64)
    checkBox "Mute all sound", preferences.soundMuted
    sk.volumeSlider(
      window, "Main", preferences.mainVolume, origin + vec2(0, 120)
    )
    sk.volumeSlider(
      window, "Music", preferences.musicVolume, origin + vec2(0, 176)
    )
    sk.volumeSlider(
      window, "FX", preferences.fxVolume, origin + vec2(0, 232)
    )
    sk.volumeSlider(
      window, "UI", preferences.uiVolume, origin + vec2(0, 288)
    )
    sk.drawLabel(
      "Audio playback is not available yet.",
      origin + vec2(0, 352),
      vec2(720, 36),
      sk.theme.disabledTextColor
    )
  of ControlsSettings:
    sk.bindingsPanel(window, preferences, origin)
    inputBindings = preferences.bindings
  of NetworkingSettings:
    sk.drawLabel("Display name", origin + vec2(0, 64), vec2(210, 36),
      sk.theme.defaultTextColor)
    sk.menuInput(window, "displayName", preferences.name,
      origin + vec2(210, 64), 510)
    sk.drawLabel("Server", origin + vec2(0, 112), vec2(210, 36),
      sk.theme.defaultTextColor)
    sk.menuInput(window, "preferredServer", preferences.server,
      origin + vec2(210, 112), 510)
  of DisplaySettings:
    when defined(emscripten):
      sk.at = origin + vec2(0, 80)
      checkBox "Fullscreen", preferences.fullscreen
    else:
      sk.drawLabel("Window mode", origin + vec2(0, 64), vec2(210, 36),
        sk.theme.defaultTextColor)
      sk.pushLayout(origin + vec2(210, 64),
        vec2(510 + sk.theme.padding.float32 * 3, 36))
      dropDown preferences.windowMode, [Windowed, Fullscreen]
      sk.popLayout()
      sk.drawLabel("Resolution", origin + vec2(0, 112), vec2(210, 36),
        sk.theme.defaultTextColor)
      if preferences.windowMode == Fullscreen:
        sk.drawLabel("Desktop resolution", origin + vec2(210, 112),
          vec2(510, 36), sk.theme.defaultTextColor)
      else:
        var resolutions = @[CurrentResolution]
        let limit = window.windowSizeLimit
        for resolution in Resolution720 .. Resolution2160:
          let size = resolution.resolutionSize
          if size.x <= limit.x and size.y <= limit.y:
            resolutions.add resolution
        sk.pushLayout(origin + vec2(210, 112),
          vec2(510 + sk.theme.padding.float32 * 3, 36))
        dropDown preferences.resolution, resolutions
        sk.popLayout()
    sk.at = origin + vec2(0, 160)
    checkBox "Visual interpolation", preferences.interpolation
    sk.drawLabel("FPS limit", origin + vec2(0, 204), vec2(210, 36),
      sk.theme.defaultTextColor)
    for i, fps in [30, 60, 120, 0]:
      sk.at = origin + vec2(210 + i.float32 * 120, 204)
      radioButton (if fps == 0: "Unlimited" else: $fps), preferences.fps, fps
    sk.drawLabel("Edge scrolling", origin + vec2(0, 248), vec2(210, 36),
      sk.theme.defaultTextColor)
    sk.pushLayout(
      origin + vec2(210, 248),
      vec2(510 + sk.theme.padding.float32 * 3, 36)
    )
    dropDown preferences.edgeScrolling,
      [NoEdgeScroll, FullscreenEdgeScroll, AlwaysEdgeScroll]
    sk.popLayout()
    if preferences != previous:
      preferences.applyPreferences(window)
  sk.at = origin + vec2(0, 408)
  button "Save and Back", not bindingCapture:
    preferences.savePreferences(app)
    result = true
