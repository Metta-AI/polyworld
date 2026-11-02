import
  std/[monotimes, os, times],
  windy,
  polyworld/displays

let window = newWindow("Window settings check", ivec2(1280, 720))
for mode in [Windowed, Fullscreen, Windowed]:
  let previousSize = window.size
  window.configureWindow(mode, Resolution900)
  doAssert window.size == previousSize, "Configuration must only queue changes"
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    window.updateWindowSettings()
    pollEvents()
    if mode == Fullscreen:
      if window.fullscreen:
        break
    elif not window.fullscreen and window.size == ivec2(1600, 900) and
      window.style == DecoratedResizable:
        break
    sleep(10)
  doAssert window.fullscreen == (mode == Fullscreen)
  if mode != Fullscreen:
    doAssert window.size == ivec2(1600, 900)
    doAssert window.style == DecoratedResizable
  echo mode, ": ", window.size, ", ", window.style
window.close()
echo "Native window modes and resolution changes passed"
