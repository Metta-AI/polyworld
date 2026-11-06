## LvD-only final current-sight clip. Preserve the explored ground image,
## then restore it over every hidden ground pixel after props/effects/shadows.
## Shared shaders/defaults and authoritative state are untouched.
import opengl, vmath

type StrictFog* = object
  program, vao, framebuffer, color, depth, sight: GLuint
  size: IVec2
  target: GLint
  capturing: bool
  inverse: Mat4
  side: int

proc compile(kind: GLenum, text: string): GLuint =
  result = glCreateShader(kind)
  var sources = allocCStringArray([text])
  glShaderSource(result, 1, sources, nil)
  deallocCStringArray(sources)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  doAssert ok != 0, "Strict fog shader compilation failed"

proc initStrictFog*(): StrictFog =
  let header = when defined(emscripten): "#version 300 es\nprecision highp float;\nprecision highp int;\n"
    else: "#version 410\n"
  let vertex = compile(GL_VERTEX_SHADER, header & """
out vec2 uv;
void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*2.0-1.0,0,1);}
""")
  let fragment = compile(GL_FRAGMENT_SHADER, header & """
in vec2 uv; out vec4 color;
uniform sampler2D groundColor; uniform sampler2D groundDepth;
uniform sampler2D currentSight; uniform mat4 inverseView; uniform float mapSide;
void main(){
 float d=texture(groundDepth,uv).r;
 vec4 p=inverseView*vec4(uv*2.0-1.0,d*2.0-1.0,1.0);
 vec2 cell=floor(p.xz/p.w+mapSide*0.5);
 bool inside=all(greaterThanEqual(cell,vec2(0)))&&all(lessThan(cell,vec2(mapSide)));
 if(d<1.0 && inside && texelFetch(currentSight,ivec2(cell),0).r>0.5) discard;
 color=texture(groundColor,uv);
}
""")
  result.program = glCreateProgram()
  glAttachShader(result.program, vertex)
  glAttachShader(result.program, fragment)
  glLinkProgram(result.program)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var ok: GLint
  glGetProgramiv(result.program, GL_LINK_STATUS, ok.addr)
  doAssert ok != 0
  glGenVertexArrays(1, result.vao.addr)
  glGenFramebuffers(1, result.framebuffer.addr)
  glGenTextures(1, result.color.addr)
  glGenTextures(1, result.depth.addr)
  glGenTextures(1, result.sight.addr)

proc beginStrictGround*(fog: var StrictFog, size: IVec2) =
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, fog.target.addr)
  if fog.size != size:
    fog.size = size
    for tex in [fog.color, fog.depth]:
      glBindTexture(GL_TEXTURE_2D, tex)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
      if tex == fog.color:
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8.GLint,size.x,size.y,0,GL_RGBA,GL_UNSIGNED_BYTE,nil)
      else:
        glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT24.GLint,size.x,size.y,0,GL_DEPTH_COMPONENT,GL_UNSIGNED_INT,nil)
    glBindFramebuffer(GL_FRAMEBUFFER, fog.framebuffer)
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,fog.color,0)
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,fog.depth,0)
    doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  glBindFramebuffer(GL_FRAMEBUFFER, fog.framebuffer)
  glViewport(0, 0, size.x, size.y)
  fog.capturing = true

proc captureStrictGround*(fog: var StrictFog, size: IVec2, inverseView: Mat4,
    values: openArray[uint8], side: int) =
  fog.inverse = inverseView
  fog.side = side
  if not fog.capturing:
    fog.beginStrictGround(size)
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fog.target.GLuint)
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fog.framebuffer)
    glBlitFramebuffer(0,0,size.x,size.y,0,0,size.x,size.y,
      GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT,GL_NEAREST.GLenum)
  fog.capturing = false
  glBindFramebuffer(GL_FRAMEBUFFER, fog.target.GLuint)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, fog.sight)
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST.GLint)
  var alignment: GLint
  glGetIntegerv(GL_UNPACK_ALIGNMENT, alignment.addr)
  glPixelStorei(GL_UNPACK_ALIGNMENT,1)
  glTexImage2D(GL_TEXTURE_2D,0,GL_R8.GLint,side.GLsizei,side.GLsizei,0,GL_RED,GL_UNSIGNED_BYTE,unsafeAddr values[0])
  glPixelStorei(GL_UNPACK_ALIGNMENT,alignment)

proc restoreHiddenGround*(fog: var StrictFog) =
  glBindFramebuffer(GL_FRAMEBUFFER,fog.target.GLuint)
  glViewport(0,0,fog.size.x,fog.size.y)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glDepthMask(GL_FALSE)
  glUseProgram(fog.program)
  for i, name in ["groundColor", "groundDepth", "currentSight"]:
    glActiveTexture(GLenum(GL_TEXTURE0.uint32 + i.uint32))
    glBindTexture(GL_TEXTURE_2D, [fog.color,fog.depth,fog.sight][i])
    glUniform1i(glGetUniformLocation(fog.program,name.cstring),i.GLint)
  glUniformMatrix4fv(glGetUniformLocation(fog.program,"inverseView"),1,GL_FALSE,cast[ptr float32](fog.inverse.addr))
  glUniform1f(glGetUniformLocation(fog.program,"mapSide"),fog.side.float32)
  glBindVertexArray(fog.vao)
  glDrawArrays(GL_TRIANGLES,0,3)
  glBindVertexArray(0)
  glUseProgram(0)
  glDepthMask(GL_TRUE)
  glActiveTexture(GL_TEXTURE0)

proc closeStrictFog*(fog: var StrictFog) =
  glDeleteProgram(fog.program)
  glDeleteVertexArrays(1,fog.vao.addr)
  glDeleteFramebuffers(1,fog.framebuffer.addr)
  glDeleteTextures(1,fog.color.addr)
  glDeleteTextures(1,fog.depth.addr)
  glDeleteTextures(1,fog.sight.addr)
  fog = StrictFog()
