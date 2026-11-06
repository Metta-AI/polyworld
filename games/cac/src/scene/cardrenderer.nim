## Card surfaces: silky draws each face, from source images and fonts in the
## UI atlas (silkyfaces.nim), into a texture of its own the first time that
## face is needed. The table draws a card as one quad on its face's texture;
## the HUD shows the same texture. Card backs and badges come from the atlas.

import std/tables
import chroma, opengl, pixie, shady, silky, silky/drawers/ogl, vmath
import ../core/core, ../ui/[cardfaces, silkyfaces]
export silkyfaces.FaceState, silkyfaces.addFaceAssets

type
  CardRenderer* = object
    program, vertexArray, vertexBuffer: GLuint
    vertices: seq[float32]
    batches: seq[Batch]

  Batch = object
    ## Consecutive vertices drawn from one texture.
    texture: GLuint
    size: Vec2  ## The texture's size, in texels.
    first, count: int

  FaceTexture = object
    texture: GLuint
    lastFrame: int

  HudFace = object
    texture: GLuint
    origin, size: Vec2
    tint: ColorRGBX

const
  CardBackKey* = "card/back"
  FloatsPerVertex = 9
  FaceTextureBudget = 64
    ## Face textures kept between frames (about 2.7 MB each with mipmaps).
    ## A frame that shows more keeps them all.

var
  cardViewProjection: Uniform[Mat4]
  cardAtlasSize: Uniform[Vec2]
  cardAtlasSampler: Uniform[Sampler2D]
  hudViewportSize: Uniform[Vec2]
  hudTint: Uniform[Vec4]
  hudSampler: Uniform[Sampler2D]

proc cardVertex(position: Vec3, uv: Vec2, tint: Vec4,
    gl_Position: var Vec4, fragmentUv: var Vec2, fragmentTint: var Vec4) =
  gl_Position = cardViewProjection * vec4(position, 1)
  fragmentUv = uv / cardAtlasSize
  fragmentTint = tint

proc cardFragment(fragmentUv: Vec2, fragmentTint: Vec4,
    outputColor: var Vec4) =
  let surface = texture(cardAtlasSampler, fragmentUv)
  if surface.a < 0.01'f32:
    discardFragment()
  outputColor = vec4(mix(surface.rgb * fragmentTint.rgb,
    vec3(1.0, 0.025, 0.045) * surface.a, fragmentTint.w * 0.88'f32), surface.a)

proc hudVertex(position: Vec2, uv: Vec2, gl_Position: var Vec4,
    fragmentUv: var Vec2) =
  ## A HUD face's corner, in framebuffer pixels from the top left.
  gl_Position = vec4(position.x / hudViewportSize.x * 2 - 1,
    1 - position.y / hudViewportSize.y * 2, 0, 1)
  fragmentUv = uv

proc hudFragment(fragmentUv: Vec2, outputColor: var Vec4) =
  outputColor = texture(hudSampler, fragmentUv) * hudTint

proc compileStage(kind: GLenum, source: string): GLuint =
  result = glCreateShader(kind)
  let sources = allocCStringArray([source])
  defer: deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    raise newException(CatchableError, "Card shader failed: " & log)

proc linkProgram(vertexSource, fragmentSource: string): GLuint =
  let
    vertex = compileStage(GL_VERTEX_SHADER, vertexSource)
    fragment = compileStage(GL_FRAGMENT_SHADER, fragmentSource)
  result = glCreateProgram()
  glAttachShader(result, vertex)
  glAttachShader(result, fragment)
  glLinkProgram(result)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var status: GLint
  glGetProgramiv(result, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    raise newException(CatchableError, "Card shader link failed: " & log)

proc bindAttributes(program: GLuint,
    attributes: openArray[(string, int)]) =
  ## Float attributes, packed one after another in each vertex.
  var stride = 0
  for (_, count) in attributes:
    stride += count
  var offset = 0
  for (name, count) in attributes:
    let location = glGetAttribLocation(program, name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(location.GLuint, count.GLint, cGL_FLOAT, GL_FALSE,
      (stride * sizeof(float32)).GLsizei,
      cast[pointer](offset * sizeof(float32)))
    offset += count

const ShaderTarget = when defined(emscripten): glsl3WebGL else: glsl4Desktop

proc initCardRenderer*(): CardRenderer =
  result.program = linkProgram(
    toShader(cardVertex, ShaderTarget, shaderVertex),
    toShader(cardFragment, ShaderTarget, shaderFragment))
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  result.program.bindAttributes([("position", 3), ("uv", 2), ("tint", 4)])
  glBindVertexArray(0)

var
  faceTextures: Table[FaceState, FaceTexture]
  faceFramebuffer: GLuint
  frame = 0
  hudFaces: seq[HudFace]
  hudProgram, hudVertexArray, hudVertexBuffer: GLuint

proc newFaceTexture(): GLuint =
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, CardFaceWidth.GLsizei,
    CardFaceHeight.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
    GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glGenerateMipmap(GL_TEXTURE_2D)

proc renderFace(sk: Silky, state: FaceState, texture: GLuint) =
  ## Silky draws the face into `texture`, between the quads it has queued
  ## for the HUD, which are set aside meanwhile. Needs silky's UI frame.
  var
    framebuffer: GLint
    viewport: array[4, GLint]
    clearColor: array[4, GLfloat]
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, framebuffer.addr)
  glGetIntegerv(GL_VIEWPORT, viewport[0].addr)
  glGetFloatv(GL_COLOR_CLEAR_VALUE, clearColor[0].addr)
  let blend = glIsEnabled(GL_BLEND)
  var queued: typeof(sk.drawer.layers)
  swap(queued, sk.drawer.layers)
  let layer = sk.drawer.currentLayer
  sk.drawer.currentLayer = 0
  sk.pushRawClipRect(rect(0, 0, CardFaceWidth.float32,
    CardFaceHeight.float32))
  sk.paintFace(state, vec2(0, 0))
  sk.popClipRect()
  if faceFramebuffer == 0:
    glGenFramebuffers(1, faceFramebuffer.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, faceFramebuffer)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
    texture, 0)
  glViewport(0, 0, CardFaceWidth.GLsizei, CardFaceHeight.GLsizei)
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)
  let vertices = sk.drawer.layers[0]
  if vertices.len > 0:
    sk.drawer.endFrame(sk.image, vec2(CardFaceWidth.float32,
      CardFaceHeight.float32), vertices[0].unsafeAddr, vertices.len)
  glBindTexture(GL_TEXTURE_2D, texture)
  glGenerateMipmap(GL_TEXTURE_2D)
  swap(queued, sk.drawer.layers)
  sk.drawer.currentLayer = layer
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer.GLuint)
  glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
  glClearColor(clearColor[0], clearColor[1], clearColor[2], clearColor[3])
  if blend: glEnable(GL_BLEND) else: glDisable(GL_BLEND)

proc faceTexture(sk: Silky, state: FaceState): GLuint =
  ## The face's texture, drawn the first time it is needed. Past the budget,
  ## the texture least recently shown is drawn over.
  if state in faceTextures:
    faceTextures[state].lastFrame = frame
    return faceTextures[state].texture
  var
    oldest = frame
    stale: FaceState
    found = false
  if faceTextures.len >= FaceTextureBudget:
    for key, face in faceTextures:
      if face.lastFrame < oldest:
        oldest = face.lastFrame
        stale = key
        found = true
  if found:
    result = faceTextures[stale].texture
    faceTextures.del stale
  else:
    result = newFaceTexture()
  sk.renderFace(state, result)
  faceTextures[state] = FaceTexture(texture: result, lastFrame: frame)

proc clear*(renderer: var CardRenderer) =
  ## Starts a frame's cards.
  renderer.vertices.setLen(0)
  renderer.batches.setLen(0)
  inc frame

proc quadCount*(renderer: CardRenderer): int =
  ## Quads queued this frame, for the benchmark.
  renderer.vertices.len div (6 * FloatsPerVertex)

proc addQuad(renderer: var CardRenderer, corners: array[4, Vec3],
    uvs: array[4, Vec2], brightness, damageFlash: float32, tint: Vec3,
    texture: GLuint, size: Vec2) =
  let first = renderer.vertices.len div FloatsPerVertex
  if renderer.batches.len > 0 and renderer.batches[^1].texture == texture:
    renderer.batches[^1].count += 6
  else:
    renderer.batches.add Batch(texture: texture, size: size, first: first,
      count: 6)
  for i in [0, 1, 2, 0, 2, 3]:
    let p = corners[i]
    renderer.vertices.add [p.x, p.y, p.z, uvs[i].x, uvs[i].y,
      brightness * tint.x, brightness * tint.y, brightness * tint.z,
      damageFlash]

proc addSurface*(renderer: var CardRenderer, sk: Silky,
    corners: array[4, Vec3], imageKey: string, brightness = 1.0'f32,
    damageFlash = 0.0'f32, tint = vec3(1, 1, 1)) =
  ## One atlas image over these corners: top-left, bottom-left,
  ## bottom-right, top-right in card space. `tint` colours the image, for
  ## sprites that aren't card faces.
  let
    entry = sk.atlas.entries[imageKey]
    left = entry.x.float32 + 0.5'f32
    top = entry.y.float32 + 0.5'f32
    right = (entry.x + entry.width).float32 - 0.5'f32
    bottom = (entry.y + entry.height).float32 - 0.5'f32
    atlasSize = sk.atlasImageSize()
  renderer.addQuad(corners, [vec2(left, top), vec2(left, bottom),
    vec2(right, bottom), vec2(right, top)], brightness, damageFlash, tint,
    sk.atlasTextureId(), vec2(atlasSize.x.float32, atlasSize.y.float32))

proc addFace*(renderer: var CardRenderer, sk: Silky,
    corners: array[4, Vec3], state: FaceState, brightness = 1.0'f32,
    damageFlash = 0.0'f32) =
  ## A card face over these corners (as addSurface), on its own texture,
  ## half a texel in at its edges. Silky drew the face's top at the
  ## texture's last row.
  const
    left = 0.5'f32
    right = CardFaceWidth.float32 - 0.5'f32
    top = CardFaceHeight.float32 - 0.5'f32
    bottom = 0.5'f32
  renderer.addQuad(corners, [vec2(left, top), vec2(left, bottom),
    vec2(right, bottom), vec2(right, top)], brightness, damageFlash,
    vec3(1, 1, 1), sk.faceTexture(state),
    vec2(CardFaceWidth.float32, CardFaceHeight.float32))

proc draw*(renderer: var CardRenderer, sk: Silky, viewProjection: Mat4) =
  if renderer.vertices.len == 0: return
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(GL_ARRAY_BUFFER, renderer.vertices.len * sizeof(float32),
    renderer.vertices[0].addr, GL_DYNAMIC_DRAW)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(renderer.program)
  glActiveTexture(GL_TEXTURE0)
  cardViewProjection = viewProjection
  glUniformMatrix4fv(glGetUniformLocation(renderer.program, "cardViewProjection"),
    1, GL_FALSE, cast[ptr float32](cardViewProjection.addr))
  glUniform1i(glGetUniformLocation(renderer.program, "cardAtlasSampler"), 0)
  let sizeLocation = glGetUniformLocation(renderer.program, "cardAtlasSize")
  glBindVertexArray(renderer.vertexArray)
  for batch in renderer.batches:
    glBindTexture(GL_TEXTURE_2D, batch.texture)
    glUniform2f(sizeLocation, batch.size.x, batch.size.y)
    glDrawArrays(GL_TRIANGLES, batch.first.GLint, batch.count.GLsizei)
  glBindVertexArray(0)

proc drawFace*(sk: Silky, state: FaceState, origin, size: Vec2,
    tint = rgbx(255, 255, 255, 255)) =
  ## A card face in the HUD: the face's texture, drawn over the HUD once
  ## silky has drawn it (`drawHudFaces`).
  hudFaces.add HudFace(texture: sk.faceTexture(state), origin: origin,
    size: size, tint: tint)

proc drawFlatFace*(sk: Silky, card: Card, origin, size: Vec2,
    tint = rgbx(255, 255, 255, 255)) =
  ## A printed face, for the choose screen.
  sk.drawFace(FaceState(card: card, power: -1, toughness: -1), origin, size,
    tint)

proc drawHudFaces*(sk: Silky) =
  ## Draws the faces the HUD asked for this frame, over what silky drew.
  ## Call after `endUi`.
  if hudFaces.len == 0:
    return
  if hudProgram == 0:
    hudProgram = linkProgram(
      toShader(hudVertex, ShaderTarget, shaderVertex),
      toShader(hudFragment, ShaderTarget, shaderFragment))
    glGenVertexArrays(1, hudVertexArray.addr)
    glBindVertexArray(hudVertexArray)
    glGenBuffers(1, hudVertexBuffer.addr)
    glBindBuffer(GL_ARRAY_BUFFER, hudVertexBuffer)
    hudProgram.bindAttributes([("position", 2), ("uv", 2)])
    glBindVertexArray(0)
  let scale = sk.uiScale
  glViewport(0, 0, sk.framebufferSize.x, sk.framebufferSize.y)
  glDisable(GL_DEPTH_TEST)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(hudProgram)
  glUniform2f(glGetUniformLocation(hudProgram, "hudViewportSize"),
    sk.framebufferSize.x.float32, sk.framebufferSize.y.float32)
  glUniform1i(glGetUniformLocation(hudProgram, "hudSampler"), 0)
  let tintLocation = glGetUniformLocation(hudProgram, "hudTint")
  glActiveTexture(GL_TEXTURE0)
  glBindVertexArray(hudVertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, hudVertexBuffer)
  for face in hudFaces:
    let
      a = face.origin * scale
      b = (face.origin + face.size) * scale
      # Silky drew the face's top at the texture's last row.
      vertices = [a.x, a.y, 0'f32, 1, a.x, b.y, 0, 0, b.x, b.y, 1, 0,
        a.x, a.y, 0, 1, b.x, b.y, 1, 0, b.x, a.y, 1, 1]
    glBufferData(GL_ARRAY_BUFFER, vertices.len * sizeof(float32),
      vertices[0].unsafeAddr, GL_STREAM_DRAW)
    glUniform4f(tintLocation, face.tint.r.float32 / 255,
      face.tint.g.float32 / 255, face.tint.b.float32 / 255,
      face.tint.a.float32 / 255)
    glBindTexture(GL_TEXTURE_2D, face.texture)
    glDrawArrays(GL_TRIANGLES, 0, 6)
  glBindVertexArray(0)
  glUseProgram(0)
  glDisable(GL_BLEND)
  hudFaces.setLen(0)
