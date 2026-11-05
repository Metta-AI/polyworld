## Native hidden-GL regression for LvD's byte-per-cell fog upload.
## Run from repository root; requires desktop OpenGL, but no terrain art.
include polyworld/quadterrain
import windy
import ../[maps, sim]
import polyworld/visions

proc worldVisibility(world: World, mode: int32): seq[uint8] =
  ## Match updateTerrainVision's encoding, including its presentation blur.
  result = newSeq[uint8](world.map.side * world.map.side)
  for y in 0 ..< world.map.side:
    for x in 0 ..< world.map.side:
      result[world.map.tileIndex(x, y)] =
        if mode == 0 or world.visible(mode - 1, x, y): 255
        elif world.explored(mode - 1, x, y): 48
        else: 0
  if mode != 0:
    result = blurVisibility(result, world.map.side, world.map.side)

proc readVisibility(): seq[uint8] =
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  result.setLen(visibilitySize * visibilitySize)
  glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_UNSIGNED_BYTE, result[0].addr)
  doAssert glGetError() == GL_NO_ERROR

block visibilityUpload:
  let window = newWindow("LvD terrain vision regression", ivec2(64, 64),
    visible = false, vsync = false)
  defer: window.close()
  window.makeContextCurrent()
  loadExtensions()
  # Allocate the same R8 target without requiring optional terrain art.
  glGenTextures(1, visibilityTexture.addr)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  visibilitySize = 0

  # LvD's ordinary 90-wide map has tightly packed rows, not GL's default
  # 92-byte aligned rows. Asymmetric data detects drift, flips and scaling.
  const Side = 90
  var expected = newSeq[uint8](Side * Side)
  for y in 0 ..< Side:
    for x in 0 ..< Side:
      expected[y * Side + x] = uint8((x * 7 + y * 19) mod 256)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  uploadTerrainVisibility(expected, Side)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  var actual = newSeq[uint8](expected.len)
  glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_UNSIGNED_BYTE, actual[0].addr)
  doAssert glGetError() == GL_NO_ERROR
  var mismatches = 0
  for i in 0 ..< expected.len:
    if actual[i] != expected[i]: inc mismatches
  echo "visibility upload side=", Side, " mismatched texels=", mismatches,
    " first row1 expected=", expected[Side], " actual=", actual[Side]
  doAssert actual == expected, "Fog upload must preserve every row-major cell"

  # Exercise reallocations and both aligned (GotA) and unaligned map sizes.
  for side in [64, 90, 110, 91, 64]:
    var cells = newSeq[uint8](side * side)
    for i in 0 ..< cells.len: cells[i] = uint8((i * 13) mod 256)
    for alignment in [1, 2, 4, 8]:
      glPixelStorei(GL_UNPACK_ALIGNMENT, alignment.GLint)
      glActiveTexture(GL_TEXTURE3)
      uploadTerrainVisibility(cells, side)
      var restored: GLint
      glGetIntegerv(GL_UNPACK_ALIGNMENT, restored.addr)
      doAssert restored == alignment.GLint
      doAssert readVisibility() == cells
  echo "Aligned/unaligned sizes, resizing, unpack-state restoration passed"

  let world = newWorld(generateMap(47, 3), 100)
  for mode in [1'i32, 2, 3, 0, 3, 1]:
    let cells = worldVisibility(world, mode)
    uploadTerrainVisibility(cells, world.map.side.int)
    doAssert readVisibility() == cells
  echo "Live three-player LOS and spectator/team transitions passed; side=",
    world.map.side

  # Render the actual terrain shader and its world-space UVs, without art.
  # Constant varyings keep lighting/materials identical between fog states.
  let vertexSource = """#version 410
out vec3 worldPos;
out float vertEdgeMask;
out vec3 vertNormal;
out vec3 vertColor;
out vec4 vertMaterials;
out vec4 vertWeights;
out vec3 vertSplatRange;
out vec3 shadowPos;
out vec3 fragmentColor;
out vec3 fragmentNormal;
out vec3 fragmentPosition;
uniform vec2 probePosition;
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
  worldPos = vec3(probePosition.x, 0.0, probePosition.y);
  vertEdgeMask = 0.0; vertNormal = vec3(0,1,0);
  vertColor = vec3(1); vertMaterials = vec4(0);
  vertWeights = vec4(1,0,0,0); vertSplatRange = vec3(-1);
  shadowPos = worldPos;
  fragmentColor = vec3(45,180,65) / 255.0;
  fragmentNormal = vertNormal; fragmentPosition = worldPos;
}
"""
  var program = compileProgram(vertexSource,
    toShader(terrainFrag, OpenGlShaderTarget, shaderFragment))
  glUseProgram(program)
  for name in ["envHighlight", "envShadow"]:
    glUniform3f(glGetUniformLocation(program, name.cstring), 1, 1, 1)
  glUniform1f(glGetUniformLocation(program, "blendDepth"), 1)
  glUniform1i(glGetUniformLocation(program, "terrainTextures"), 0)
  glUniform1i(glGetUniformLocation(program, "visibilityTex"), 1)
  # Shadow samplers must have different texture units from color samplers.
  for name in ["shadowMapPcf0", "shadowMapPcf1"]:
    glUniform1i(glGetUniformLocation(program, name.cstring), 2)
  for name in ["ambientMap", "splatData", "blendData", "groundMask"]:
    glUniform1i(glGetUniformLocation(program, name.cstring), 1)
  # Complete even disabled shadow samplers to keep native drivers quiet.
  glActiveTexture(GL_TEXTURE2)
  var depthTexture: GLuint
  glGenTextures(1, depthTexture.addr)
  glBindTexture(GL_TEXTURE_2D, depthTexture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint, 1, 1, 0,
    GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.GLint)
  glActiveTexture(GL_TEXTURE0)
  let green = newImage(1, 1)
  green.fill(rgbx(45, 180, 65, 255))
  let material = buildTextureArray(@[@[green]], GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D_ARRAY, material)
  var vao: GLuint
  glGenVertexArrays(1, vao.addr)
  glBindVertexArray(vao)
  # Hidden Cocoa windows have no drawable default framebuffer.
  var framebuffer, colorBuffer: GLuint
  glGenFramebuffers(1, framebuffer.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glGenRenderbuffers(1, colorBuffer.addr)
  glBindRenderbuffer(GL_RENDERBUFFER, colorBuffer)
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64)
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
    GL_RENDERBUFFER, colorBuffer)
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  glViewport(0, 0, 64, 64)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_BLEND)

  proc sample(cells: seq[uint8], side, x, y: int): ColorRGBX =
    glActiveTexture(GL_TEXTURE1)
    uploadTerrainVisibility(cells, side)
    glBindTexture(GL_TEXTURE_2D, visibilityTexture)
    glUniform1f(glGetUniformLocation(program, "visibilityOffset"), side.float32 / 2)
    glUniform1f(glGetUniformLocation(program, "visibilityScale"), 1'f32 / side.float32)
    glUniform2f(glGetUniformLocation(program, "probePosition"),
      x.float32 + 0.5'f32 - side.float32 / 2,
      y.float32 + 0.5'f32 - side.float32 / 2)
    doAssert glGetError() == GL_NO_ERROR, "shader fixture setup"
    glDrawArrays(GL_TRIANGLES, 0, 3)
    let drawError = glGetError()
    doAssert drawError == GL_NO_ERROR, "draw error " & $drawError.uint32
    glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, result.addr)
    doAssert glGetError() == GL_NO_ERROR, "pixel readback"

  var cells = newSeq[uint8](Side * Side)
  let unexplored = sample(cells, Side, 7, 63)
  cells[63 * Side + 7] = 48
  let explored = sample(cells, Side, 7, 63)
  cells[63 * Side + 7] = 255
  let visible = sample(cells, Side, 7, 63)
  doAssert visible.g > visible.r * 2
  doAssert explored.g > unexplored.g
  doAssert explored.g < visible.g div 2
  doAssert unexplored.r == unexplored.g and unexplored.g == unexplored.b
  doAssert sample(cells, Side, 63, 7) == unexplored
  doAssert sample(cells, Side, Side - 8, Side - 64) == unexplored
  for value in cells.mitems: value = 255
  doAssert sample(cells, Side, 7, 63) == visible
  echo "Actual terrain shader RGBA visible=", visible, " explored=", explored,
    " unexplored=", unexplored

  # Building props use the same world-space mapping and fog values.
  program = compileProgram(vertexSource,
    toShader(propFrag, OpenGlShaderTarget, shaderFragment))
  glUseProgram(program)
  for name in ["envHighlight", "envShadow"]:
    glUniform3f(glGetUniformLocation(program, name.cstring), 1, 1, 1)
  glUniform4f(glGetUniformLocation(program, "propTint"), 1, 1, 1, 1)
  glUniform1i(glGetUniformLocation(program, "visibilityTex"), 1)
  glUniform1i(glGetUniformLocation(program, "ambientMap"), 1)
  for name in ["shadowMapPcf0", "shadowMapPcf1"]:
    glUniform1i(glGetUniformLocation(program, name.cstring), 2)
  for value in cells.mitems: value = 0
  let hiddenProp = sample(cells, Side, 7, 63)
  cells[63 * Side + 7] = 48
  let exploredProp = sample(cells, Side, 7, 63)
  cells[63 * Side + 7] = 255
  let visibleProp = sample(cells, Side, 7, 63)
  doAssert visibleProp.g > visibleProp.r * 2
  doAssert hiddenProp.g < exploredProp.g and exploredProp.g < visibleProp.g div 2
  doAssert sample(cells, Side, 63, 7) == hiddenProp
  for value in cells.mitems: value = 255
  doAssert sample(cells, Side, 7, 63) == visibleProp
  echo "Actual building prop shader RGBA visible=", visibleProp,
    " explored=", exploredProp, " unexplored=", hiddenProp

echo "Native terrain vision upload passed"
