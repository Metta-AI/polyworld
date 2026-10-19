import
  std/[os, strutils],
  chroma, jsony, pixie, silky, vmath, windy,
  chrome, policies

type
  MenusError* = object of CatchableError
  MenuPage* = enum
    HomeMenu, SingleMenu, MultiplayerMenu, LobbyMenu, SettingsMenu
  Preferences* = object
    name*: string = "Player"
    server*: string = "ws://127.0.0.1:8090/ws"
    fullscreen*: bool
    fps*: int = 60
    interpolation*: bool = true
  LocalPolicy* = object
    name*, bytes*: string

const
  MenuInk* = rgbx(222, 231, 228, 255)
  MenuMuted* = rgbx(137, 158, 150, 255)
  MenuAccent* = rgbx(184, 215, 139, 255)

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
  result.fps = clamp(result.fps, 0, 240)
  if result.name.len > 64:
    result.name.setLen(64)

proc savePreferences*(preferences: Preferences, app: string) =
  ## Saves ordinary preferences without bot data or reconnect secrets.
  setConfig(app, "settings.json", preferences.toJson())

proc applyPreferences*(preferences: Preferences, window: Window) =
  ## Applies shared presentation settings to the existing window.
  window.fullscreen = preferences.fullscreen
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

proc settingsPanel*(
    sk: Silky, window: Window, preferences: var Preferences,
    app: string, origin: Vec2
): bool =
  ## Edits and saves shared preferences without replacing a running match.
  sk.menuLabel("Settings", origin, font = "Bold")
  sk.menuLabel("Display name", origin + vec2(0, 44))
  sk.menuInput(window, "displayName", preferences.name,
    origin + vec2(210, 40), 490)
  sk.menuLabel("Server", origin + vec2(0, 94))
  sk.menuInput(window, "preferredServer", preferences.server,
    origin + vec2(210, 90), 490)
  if sk.menuButton(window, "Fullscreen: " & $preferences.fullscreen,
    origin + vec2(0, 150), 340):
      preferences.fullscreen = not preferences.fullscreen
      preferences.applyPreferences(window)
  if sk.menuButton(window, "FPS limit: " & $preferences.fps,
    origin + vec2(0, 200), 340):
      preferences.fps = case preferences.fps
        of 30: 60
        of 60: 120
        of 120: 0
        else: 30
      preferences.applyPreferences(window)
  if sk.menuButton(window,
    "Visual interpolation: " & $preferences.interpolation,
    origin + vec2(0, 250), 340):
      preferences.interpolation = not preferences.interpolation
      preferences.applyPreferences(window)
  if sk.menuButton(window, "Save and back", origin + vec2(0, 320), 340):
    preferences.savePreferences(app)
    result = true
