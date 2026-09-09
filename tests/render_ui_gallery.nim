## Render the actual gallery under a native OpenGL context (Xvfb + Mesa in CI).
import gltf, opengl, pixie, silky, vmath
import ../examples/ui_gallery/gallery

let window = newWindow("UI rendering proof", ivec2(960, 720), vsync = false)
window.makeContextCurrent()
loadExtensions()
let renderer = newRenderer(window)
let sk = newSilky(window, "tmp/ui-gallery/atlas.png")
var state = newGalleryState()
for tab in 0 .. 2:
  state.tab = tab
  sk.beginUI(window, window.size)
  sk.drawGallery(window, state)
  sk.endUi()
  glFinish()
  doAssert glGetError() == GL_NO_ERROR
  let image = renderer.captureScreenshot()
  doAssert image.width == 960 and image.height == 720
  var brightPixels = 0
  for y in 190 ..< 650:
    for x in 40 ..< 900:
      let pixel = image[x, y]
      if pixel.r > 180 and pixel.g > 180 and pixel.b > 180:
        inc brightPixels
  doAssert brightPixels > 1000, "content must render visible text and controls"
  image.writeFile("tmp/ui-gallery/native-" & $tab & ".png")
echo "Native gallery rendering proof passed"
