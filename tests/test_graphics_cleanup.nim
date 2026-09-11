## Check graphics cleanup with a current OpenGL context (Xvfb + Mesa in CI).
import std/importutils
import opengl, vmath, windy
import polyworld/[shapes, worldbars]

privateAccess(WorldBarRenderer)
privateAccess(ShapeRenderer)

proc alive(bars: WorldBarRenderer, expected: bool) =
  doAssert (glIsProgram(bars.program) == GL_TRUE) == expected
  doAssert (glIsVertexArray(bars.vertexArray) == GL_TRUE) == expected
  doAssert (glIsBuffer(bars.vertexBuffer) == GL_TRUE) == expected
  doAssert (glIsTexture(bars.whiteTexture) == GL_TRUE) == expected

proc alive(shapeRenderer: ShapeRenderer, expected: bool) =
  doAssert (glIsProgram(shapeRenderer.program) == GL_TRUE) == expected
  doAssert (glIsVertexArray(shapeRenderer.vertexArray) == GL_TRUE) == expected
  doAssert (glIsBuffer(shapeRenderer.vertexBuffer) == GL_TRUE) == expected
  doAssert (glIsTexture(shapeRenderer.whiteTexture) == GL_TRUE) == expected

let window = newWindow("Graphics cleanup test", ivec2(256), vsync = false)
window.makeContextCurrent()
loadExtensions()
var emptyBars: WorldBarRenderer
var emptyShapes: ShapeRenderer
emptyBars.closeWorldBarRenderer()
emptyShapes.closeShapeRenderer()
doAssert glGetError() == GL_NO_ERROR

var
  bars = initWorldBarRenderer()
  peerBars = initWorldBarRenderer()
  shapeRenderer = initShapeRenderer()
  peerShapeRenderer = initShapeRenderer()
shapeRenderer.texture = peerShapeRenderer.whiteTexture
bars.alive(true)
shapeRenderer.alive(true)
# These copies observe handles; they do not own the resources.
let oldBars = bars
let oldShapes = shapeRenderer
bars.closeWorldBarRenderer()
shapeRenderer.closeShapeRenderer()
oldBars.alive(false)
oldShapes.alive(false)
doAssert bars == WorldBarRenderer()
doAssert shapeRenderer == ShapeRenderer()
bars.closeWorldBarRenderer()
shapeRenderer.closeShapeRenderer()
peerBars.alive(true)
peerShapeRenderer.alive(true)
peerBars.closeWorldBarRenderer()
peerShapeRenderer.closeShapeRenderer()
doAssert glGetError() == GL_NO_ERROR

echo "GPU release, repeated close and peer isolation passed"
