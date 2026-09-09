## Real GPU lifecycle proof: render, release, preserve peers, then recreate.
import std/[importutils, os]
import chroma, gltf, opengl, pixie, vmath, windy
import polyworld/[selectionoutlines, worldbars]

privateAccess(WorldBarRenderer)
privateAccess(SelectionOutline)

proc alive(bars: WorldBarRenderer, expected: bool) =
  doAssert (glIsProgram(bars.program) == GL_TRUE) == expected
  doAssert (glIsVertexArray(bars.vertexArray) == GL_TRUE) == expected
  doAssert (glIsBuffer(bars.vertexBuffer) == GL_TRUE) == expected

proc alive(outline: SelectionOutline, expected: bool) =
  doAssert (glIsProgram(outline.program) == GL_TRUE) == expected
  doAssert (glIsVertexArray(outline.vertexArray) == GL_TRUE) == expected
  doAssert (glIsBuffer(outline.vertexBuffer) == GL_TRUE) == expected
  doAssert (glIsFramebuffer(outline.framebuffer) == GL_TRUE) == expected
  doAssert (glIsTexture(outline.colorTexture) == GL_TRUE) == expected
  doAssert (glIsRenderbuffer(outline.depthBuffer) == GL_TRUE) == expected

proc render(bars: var WorldBarRenderer, outline: var SelectionOutline) =
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, 256, 256)
  glDepthMask(GL_TRUE)
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  bars.clear()
  bars.addResourceBars(vec3(0, 0.3, 0), 1, [WorldResourceBar(
    value: 75, maximum: 100, height: 0.15, color: rgbx(40, 210, 70, 255))])
  bars.draw(mat4(), vec3(1, 0, 0), vec3(0, 1, 0))
  outline.beginMask(ivec2(256))
  bars.draw(mat4(), vec3(1, 0, 0), vec3(0, 1, 0))
  outline.drawOutline()
  glFinish()
  doAssert glGetError() == GL_NO_ERROR

let window = newWindow("Renderer lifecycle proof", ivec2(256), vsync = false)
window.makeContextCurrent()
loadExtensions()
let renderer = newRenderer(window)
var emptyBars: WorldBarRenderer
var emptyOutline: SelectionOutline
emptyBars.closeWorldBarRenderer()
emptyOutline.closeSelectionOutline()
doAssert glGetError() == GL_NO_ERROR

for cycle in 0 ..< 8:
  var
    bars = initWorldBarRenderer()
    outline = initSelectionOutline()
    peerBars = initWorldBarRenderer()
    peerOutline = initSelectionOutline()
  bars.render(outline)
  peerBars.render(peerOutline)
  bars.alive(true)
  outline.alive(true)
  # These copies are handle observations, never additional resource owners.
  let oldBars = bars
  let oldOutline = outline
  bars.closeWorldBarRenderer()
  outline.closeSelectionOutline()
  oldBars.alive(false)
  oldOutline.alive(false)
  doAssert bars == WorldBarRenderer()
  doAssert outline == SelectionOutline()
  bars.closeWorldBarRenderer()
  outline.closeSelectionOutline()
  peerBars.alive(true)
  peerOutline.alive(true)
  peerBars.render(peerOutline)
  let image = renderer.captureScreenshot()
  var green, gold = 0
  for pixel in image.data:
    if pixel.g > 150 and pixel.r < 80: inc green
    if pixel.r > 200 and pixel.g > 150 and pixel.b < 80: inc gold
  doAssert green > 500, "live peer must retain its green bar"
  doAssert gold > 100, "live peer must retain its gold outline"
  when not defined(emscripten):
    if cycle == 7:
      createDir("tmp/resource-lifecycle")
      image.writeFile("tmp/resource-lifecycle/native.png")
  peerBars.closeWorldBarRenderer()
  peerOutline.closeSelectionOutline()
  doAssert glGetError() == GL_NO_ERROR

echo "GPU release, repeated close, peer isolation and recreation proof passed"

when defined(emscripten):
  # Keep a fresh live pair visible for a real browser capture after the proof.
  var bars = initWorldBarRenderer()
  var outline = initSelectionOutline()
  window.onFrame = proc() =
    bars.render(outline)
    window.swapBuffers()
    proc runScript(script: cstring) {.importc: "emscripten_run_script", header: "<emscripten.h>".}
    runScript("window.__polyworldResourceProof = {passed: true};")
  while not window.closeRequested:
    pollEvents()
  bars.closeWorldBarRenderer()
  outline.closeSelectionOutline()
