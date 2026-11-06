## Real native FBO regression for game-local final fog clipping.
import opengl, windy, vmath
import ../strictfog
import polyworld/[clickmarks, particles]
const Side = 4
let window = newWindow("Strict fog composite", ivec2(64, 64), visible=false, vsync=false)
window.makeContextCurrent()
loadExtensions()
var fbo, color, depth: GLuint
glGenFramebuffers(1, fbo.addr)
glBindFramebuffer(GL_FRAMEBUFFER, fbo)
glGenTextures(1, color.addr)
glBindTexture(GL_TEXTURE_2D, color)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0)
glGenTextures(1, depth.addr)
glBindTexture(GL_TEXTURE_2D, depth)
glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint, 64, 64, 0, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nil)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
glViewport(0,0,64,64)
var fog = initStrictFog()
var marks = initClickMarks()
marks.emitClickMark(vec3(0))
marks.advanceClickMarks(0.08)
var checks = 0
proc hidden(origin: Vec3, radius: float32): bool =
  inc checks
  doAssert radius > 0
  false
# Identity inverse maps screen X directly to world X; left half hidden.
var cells = newSeq[uint8](Side * Side)
for y in 0 ..< Side:
  for x in 2 ..< Side: cells[y*Side+x] = 255
proc pixel(x: int): array[4,uint8] =
  glReadPixels(x.GLint,32,1,1,GL_RGBA,GL_UNSIGNED_BYTE,result[0].addr)
proc frame(visible: seq[uint8]) =
  fog.beginStrictGround(ivec2(64))
  glDepthMask(GL_TRUE)
  glClearDepth(0.5)
  glClearColor(0.1,0.2,0.3,1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  fog.captureStrictGround(ivec2(64), mat4(), visible, Side)
  glClearColor(1,0,0,1)
  glClear(GL_COLOR_BUFFER_BIT)
  fog.restoreHiddenGround()
frame(cells)
doAssert pixel(16)[0] < 30 and pixel(16)[2] > 70, "Hidden effect pixels must restore ground"
doAssert pixel(48)[0] == 255 and pixel(48)[2] == 0, "Visible effect pixels remain"
glClearColor(0,0,0,1)
glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
marks.drawClickMarks(mat4(), hidden)
doAssert checks == 1 and pixel(32)[0] == 0, "Hidden live click marker suppressed at draw"
marks.closeClickMarks()
for value in cells.mitems: value = 255
frame(cells)
doAssert pixel(16)[0] == 255, "Sight restoration reveals effects immediately"
doAssert particlePathVisible(vec3(0.5,0,0.5),vec3(0.5,0,0.5),cells,Side,vec2(-2))
cells[0] = 0
doAssert not particlePathVisible(vec3(0.5,0,0.5),vec3(0.5,0,0.5),cells,Side,vec2(-2),padding=2),
  "Conservative spread mask must catch hidden neighboring tiles"
for value in cells.mitems: value = 0
frame(cells)
doAssert pixel(48)[0] < 30, "Same tick sight loss takes effect immediately"
doAssert glGetError() == GL_NO_ERROR
fog.closeStrictFog()
window.close()
echo "Strict native composite: hidden pixels restored, visible preserved, transitions passed"
