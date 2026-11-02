import windy

type
  WindowMode* = enum
    Windowed = "Windowed"
    BorderlessWindow = "Borderless window" # Retained for saved preferences.
    Fullscreen = "Fullscreen"
  WindowResolution* = enum
    CurrentResolution = "Current window size"
    Resolution720 = "1280 x 720"
    Resolution800 = "1280 x 800"
    Resolution900 = "1600 x 900"
    Resolution1080 = "1920 x 1080"
    Resolution1200 = "1920 x 1200"
    Resolution1440 = "2560 x 1440"
    Resolution1600 = "2560 x 1600"
    Resolution2160 = "3840 x 2160"

const ResolutionSizes = [
  (0, 0), (1280, 720), (1280, 800), (1600, 900), (1920, 1080),
  (1920, 1200), (2560, 1440), (2560, 1600), (3840, 2160)
]

when not defined(emscripten):
  var
    pendingWindowSettings = false
    fullscreenTransition = false
    fullscreenTarget = false
    requestedWindowMode: WindowMode
    requestedResolution: WindowResolution

proc resolutionSize*(resolution: WindowResolution): IVec2 =
  ## Returns the window's drawable size in pixels for a resolution preset.
  let size = ResolutionSizes[resolution.ord]
  ivec2(size[0].int32, size[1].int32)

when defined(emscripten):
  {.emit: """
  #include <emscripten.h>
  EM_JS(int, polyworldFullscreen, (), {
    return !!(document.fullscreenElement || document.webkitFullscreenElement ||
      window.matchMedia('(display-mode: fullscreen)').matches);
  });
  """.}
  proc polyworldFullscreen(): cint {.importc, nodecl.}
    ## Reads the browser fullscreen state.
  proc requestFullscreen(
    target: cstring,
    deferUntilInEventHandler: cint
  ): cint {.importc: "emscripten_request_fullscreen",
    header: "<emscripten/html5.h>".}
    ## Requests fullscreen during a browser input gesture.
  proc exitFullscreen(): cint {.importc: "emscripten_exit_fullscreen",
    header: "<emscripten/html5.h>".}
    ## Leaves browser fullscreen.

proc isFullscreen*(window: Window): bool =
  ## Returns the actual fullscreen state on native and browser clients.
  when defined(emscripten):
    polyworldFullscreen() != 0
  else:
    window.fullscreen

proc setFullscreen*(window: Window, enabled: bool) =
  ## Changes fullscreen, deferring browser requests until an input gesture.
  if window.isFullscreen == enabled:
    return
  when defined(emscripten):
    let status =
      if enabled:
        requestFullscreen("#canvas", 1)
      else:
        exitFullscreen()
    if status < 0:
      echo "Fullscreen unavailable: check browser or iframe permissions."
  else:
    window.fullscreen = enabled

when not defined(emscripten):
  proc windowMode*(window: Window): WindowMode =
    ## Reports the selected mode, including an OS fullscreen transition.
    if pendingWindowSettings:
      requestedWindowMode
    elif window.fullscreen:
      Fullscreen
    else:
      Windowed

  proc windowSizeLimit*(window: Window): IVec2 =
    ## Leaves room for window decorations and the desktop on the current screen.
    let screens = getScreens()
    if screens.len == 0:
      return window.size
    var screen = screens[0]
    for candidate in screens:
      if window.pos.x >= candidate.left and window.pos.x < candidate.right:
        screen = candidate
        break
    ((screen.size.vec2 - vec2(80, 140)) * window.contentScale).ivec2

  proc updateWindowSettings*(window: Window) =
    ## Applies queued OS changes outside drawing and waits for fullscreen.
    if fullscreenTransition:
      if window.fullscreen != fullscreenTarget:
        return
      fullscreenTransition = false
    if not pendingWindowSettings:
      return
    let wantsFullscreen = requestedWindowMode == Fullscreen
    if window.fullscreen != wantsFullscreen:
      if wantsFullscreen and window.style != DecoratedResizable:
        window.style = DecoratedResizable
      fullscreenTarget = wantsFullscreen
      fullscreenTransition = true
      window.setFullscreen(wantsFullscreen)
      return
    if wantsFullscreen:
      pendingWindowSettings = false
      return
    if window.style != DecoratedResizable:
      window.style = DecoratedResizable
    if requestedResolution != CurrentResolution:
      let
        size = requestedResolution.resolutionSize
        limit = window.windowSizeLimit
        fittedSize = ivec2(min(size.x, limit.x), min(size.y, limit.y))
      if window.size != fittedSize:
        window.size = fittedSize
    pendingWindowSettings = false

  proc configureWindow*(
    window: Window,
    mode: WindowMode,
    resolution: WindowResolution
  ) =
    ## Queues native display changes for the outer event loop.
    requestedWindowMode =
      if mode == BorderlessWindow:
        Fullscreen
      else:
        mode
    requestedResolution = resolution
    pendingWindowSettings = true
