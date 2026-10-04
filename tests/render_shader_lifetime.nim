## Run in a GL context; use -d:testSunDepth for the shadow builder.
import opengl, vmath, windy

when defined(testSunDepth):
  include ../src/polyworld/shadows
else:
  include ../src/polyworld/quadterrain

const
  vertex = """#version 330 core
void main() {
  vec2 vertices[3] = vec2[3](vec2(-1, -1), vec2(3, -1), vec2(-1, 3));
  gl_Position = vec4(vertices[gl_VertexID], 0, 1);
}
"""
  fragment = """#version 330 core
out vec4 color;
void main() { color = vec4(1, 0, 0, 1); }
"""

let window = newWindow("Linked shader lifetime", ivec2(32), vsync = false)
window.makeContextCurrent()
loadExtensions()
var vao: GLuint
glGenVertexArrays(1, vao.addr)
glBindVertexArray(vao)
glViewport(0, 0, 32, 32)

for cycle in 0 ..< 3:
  let program =
    when defined(testSunDepth): compileDepthProgram(vertex, fragment)
    else: compileProgram(vertex, fragment)
  var attached, linked: GLint
  glGetProgramiv(program, GL_ATTACHED_SHADERS, attached.addr)
  glGetProgramiv(program, GL_LINK_STATUS, linked.addr)
  doAssert attached == 0, "Compilation objects must not stay attached"
  doAssert linked == 1
  glUseProgram(program)
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  var pixel: array[4, uint8]
  glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel[0].addr)
  doAssert pixel == [255'u8, 0, 0, 255], "Linked executable must still draw"
  glUseProgram(0)
  glDeleteProgram(program)
  doAssert glIsProgram(program) == GL_FALSE
  doAssert glGetError() == GL_NO_ERROR

glDeleteVertexArrays(1, vao.addr)
echo "Three linked programs drew exact pixels with no attached shader objects"
