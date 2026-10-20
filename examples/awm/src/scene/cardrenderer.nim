## Card surfaces share the UI atlas, so a face drawn on the table and in the
## reading view comes from the same parts. A face is drawn live, every frame,
## from its layers (facelayers.nim): the art crop, the chrome (frame and
## icons) and a patch per block of text, one quad each. Source art, frames,
## icons and fonts stay independent.

import std/[algorithm, hashes, math, sets, tables]
import chroma, opengl, pixie, silky, silky/allocator, vmath
import ../core/core, ../baseset, ../ui/[cardfaces, facelayers]
export facelayers.FaceState

type
  CardRenderer* = object
    program, vertexArray, vertexBuffer: GLuint
    vertices: seq[float32]
    planes: seq[CardPlane]

  CardPlane = object
    ## One card's corners and the vertices of every quad drawn on it.
    corners: array[4, Vec3]
    first, last: int

const
  CardBackKey* = "card/back"
  FloatsPerVertex = 14
  PlaneOffset = 9  ## Where a vertex's card plane starts.

# Every layer of a card writes the depth of the card's own plane, worked out
# once per card (`draw`), so a card's layers tie exactly and stack in draw
# order, while everything else meets the card as it would one flat quad.
# Shady has no flat float varyings, so these are written out.
const
  CardVertexSource = """
uniform mat4 cardViewProjection;
uniform vec2 cardAtlasSize;

in vec3 position;
in vec2 uv;
in vec4 tint;
in vec3 plane;
in vec2 planeAt;
out vec2 fragmentUv;
out vec4 fragmentTint;
flat out vec3 fragmentPlane;
flat out vec2 fragmentPlaneAt;

void main() {
  gl_Position = cardViewProjection * vec4(position, 1.0);
  fragmentUv = uv / cardAtlasSize;
  fragmentTint = tint;
  fragmentPlane = plane;
  fragmentPlaneAt = planeAt;
}
"""
  CardFragmentSource = """
uniform sampler2D cardAtlasSampler;

in vec2 fragmentUv;
in vec4 fragmentTint;
flat in vec3 fragmentPlane;
flat in vec2 fragmentPlaneAt;
out vec4 outputColor;

void main() {
  vec4 surface = texture(cardAtlasSampler, fragmentUv);
  if (surface.a < 0.01) {
    discard;
  }
  // The plane's slopes per pixel and its depth at planeAt; a negative depth
  // marks a card seen edge-on, which keeps its rasterized depth.
  vec2 offset = gl_FragCoord.xy - fragmentPlaneAt;
  gl_FragDepth = fragmentPlane.z < 0.0 ? gl_FragCoord.z :
    fragmentPlane.z + fragmentPlane.x * offset.x + fragmentPlane.y * offset.y;
  outputColor = vec4(mix(surface.rgb * fragmentTint.rgb, vec3(1.0, 0.025, 0.045) * surface.a, fragmentTint.w * 0.88), surface.a);
}
"""

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

proc initCardRenderer*(): CardRenderer =
  const header =
    when defined(emscripten):
      "#version 300 es\nprecision highp float;\nprecision highp sampler2D;\n"
    else: "#version 410\n"
  let
    vertex = compileStage(GL_VERTEX_SHADER, header & CardVertexSource)
    fragment = compileStage(GL_FRAGMENT_SHADER, header & CardFragmentSource)
  result.program = glCreateProgram()
  glAttachShader(result.program, vertex)
  glAttachShader(result.program, fragment)
  glLinkProgram(result.program)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var status: GLint
  glGetProgramiv(result.program, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result.program, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result.program, length, nil, log.cstring)
    raise newException(CatchableError, "Card shader link failed: " & log)
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  for attribute in [
    (name: "position", count: 3, offset: 0),
    (name: "uv", count: 2, offset: 3 * sizeof(float32)),
    (name: "tint", count: 4, offset: 5 * sizeof(float32)),
    (name: "plane", count: 3, offset: PlaneOffset * sizeof(float32)),
    (name: "planeAt", count: 2, offset: (PlaneOffset + 3) * sizeof(float32))
  ]:
    let location = glGetAttribLocation(result.program, attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(location.GLuint, attribute.count.GLint, cGL_FLOAT,
      GL_FALSE, (FloatsPerVertex * sizeof(float32)).GLsizei,
      cast[pointer](attribute.offset))
  glBindVertexArray(0)

const
  PartMargin = 16
    ## Clear atlas texels between face parts, so the mipmaps a far card
    ## samples never reach a neighbour.
  PartPhase = 16
    ## Each part sits in the atlas at its face position modulo this, so its
    ## mipmaps average the same texels together as a whole face's would.
  LiveRows = 320
    ## Atlas rows kept free for parts first needed mid-game: text the table
    ## had not shown before, such as a stat past 40 or changed rules. When
    ## they fill up, they are cleared and packed again (`clear`).

type
  ResolvedLayer = object
    ## A face layer with its place in the atlas found.
    at, size: Vec2  ## In face pixels.
    uv: Vec2  ## Its top left in the atlas, in texels.


var
  faceIndex: Table[FaceState, int]
  faceLayouts: seq[seq[ResolvedLayer]]
    ## Every face drawn so far, resolved once: drawing one again is a hash
    ## lookup, with no layout and no strings.
  regionAt: Vec2  ## The face region's top left in the atlas.
  regionRows = high(int)  ## The face region's height.
  packer: SkylineAllocator  ## Packs parts in the face region.
  partAt: Table[string, Vec2]  ## Each packed part's top left in the atlas.
  pendingUploads: seq[string]  ## Packed since the last flush.
  startupPacker: SkylineAllocator
    ## The packer as startup left it, with the live rows still free.
  liveParts: seq[string]  ## Parts packed in the live rows.
  liveRowsFull = false
    ## A part found no room in the live rows: they are cleared before the
    ## next frame's faces.
  unplaced: HashSet[string]
    ## Parts too big for even empty live rows: never tried again. Their
    ## faces are drawn without them.

proc place(size, phase: Vec2): (bool, Vec2) =
  ## Room in the face region for a part this size whose top left keeps
  ## `phase` (its face position) modulo PartPhase. The packer's square
  ## reaches past the region's rows; room found there is given back.
  let
    width = size.x.int
    height = size.y.int
    before = packer[]
    room = packer.allocate(width + PartPhase - 1, height + PartPhase - 1)
  if not room.success:
    return
  let
    x = room.x + floorMod(phase.x.int - room.x, PartPhase)
    y = room.y + floorMod(phase.y.int - room.y, PartPhase)
  if y + height + PartMargin div 2 <= regionRows:
    result = (true, vec2(x.float32, y.float32))
  else:
    packer[] = before

proc flatName(card: Card): string =
  "face/flat/" & $hash(FaceState(card: card, power: -1, toughness: -1))

proc addFaceParts*(builder: AtlasBuilder) =
  ## Reserves the atlas region faces are drawn from, and packs into it
  ## every part of every face the table can show today (art, chrome and
  ## text) and the whole face of every choice's branch, for the choose
  ## screen, tallest first. The rest of the region stays free for parts
  ## first needed mid-game. Also packs the card back.
  if not builder.addImage(CardBackKey, renderCardBack()):
    raise newException(IOError, "The card back does not fit the UI atlas")
  for state in everyFaceState(baseCards):
    discard state.faceLayers()
  var names = takeNewParts()
  for card in baseCards:
    for option in card.everyOption():
      let branch = card.optionCard(option)
      registerPart(branch.flatName, FacePart(image: branch.renderCardFace(),
        at: vec2(0, 0)))
      names.add branch.flatName
  names.sort(proc(a, b: string): int =
    cmp(b.facePart.image.height, a.facePart.image.height))
  let width = builder.size - builder.margin * 2 - PartPhase
  packer = newSkylineAllocator(width, PartMargin div 2)
  regionRows = high(int)
  var
    local: seq[Vec2]
    used = 0
  for name in names:
    let part = name.facePart
    let (fits, at) = place(
      vec2(part.image.width.float32, part.image.height.float32), part.at)
    if not fits:
      raise newException(IOError, "Card face parts do not fit the UI atlas")
    local.add at
    used = max(used, at.y.int + part.image.height)
  # The region is a whole part-phase wider and taller than it needs, so its
  # top left can round up to a multiple of the phase wherever it lands.
  regionRows = used + PartMargin + LiveRows
  # Only room is taken: the builder's image is clear there already.
  let room = builder.allocator.allocate(width + PartPhase,
    regionRows + PartPhase)
  if not room.success:
    raise newException(IOError, "Card face parts do not fit the UI atlas")
  builder.atlas.entries["face/region"] = Entry(x: room.x, y: room.y,
    width: width + PartPhase, height: regionRows + PartPhase)
  regionAt = vec2(
    (ceil(room.x.float32 / PartPhase) * PartPhase),
    (ceil(room.y.float32 / PartPhase) * PartPhase))
  for i, name in names:
    let at = regionAt + local[i]
    partAt[name] = at
    builder.atlasImage.draw(name.facePart.image, translate(at),
      OverwriteBlend)
  startupPacker = SkylineAllocator()
  startupPacker[] = packer[]

proc packLiveParts(sk: Silky, names: openArray[string]) =
  ## Packs parts first needed mid-game into the region's free rows, on the
  ## CPU copy of the atlas; `flushCardFaces` uploads them.
  for name in names:
    let part = name.facePart
    let (fits, local) = place(
      vec2(part.image.width.float32, part.image.height.float32), part.at)
    if not fits:
      if liveParts.len > 0:
        liveRowsFull = true
      else:
        stderr.writeLine "A card face part is too big for the atlas: " &
          name
        unplaced.incl name
      continue
    let at = regionAt + local
    partAt[name] = at
    liveParts.add name
    sk.image.draw(part.image, translate(at), OverwriteBlend)
    pendingUploads.add name

proc flushCardFaces*(sk: Silky) =
  ## Uploads the parts packed since the last flush, one rectangle each, and
  ## rebuilds the atlas mipmaps once. Call before anything samples the
  ## atlas: the card renderer does before drawing, and the HUD must before
  ## `endUi`.
  if pendingUploads.len == 0:
    return
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
  for name in pendingUploads:
    let
      image = name.facePart.image
      at = partAt[name]
    glTexSubImage2D(GL_TEXTURE_2D, 0, at.x.GLint, at.y.GLint,
      image.width.GLsizei, image.height.GLsizei, GL_RGBA, GL_UNSIGNED_BYTE,
      image.data[0].addr)
  glGenerateMipmap(GL_TEXTURE_2D)
  pendingUploads.setLen(0)

proc faceLayout(sk: Silky, state: FaceState): int =
  ## The index of this face's resolved layers, laying it out the first time.
  result = faceIndex.getOrDefault(state, -1)
  if result >= 0:
    return
  let layers = state.faceLayers()
  discard takeNewParts()
  # Its parts that aren't in the atlas: new ones, and any cleared from the
  # live rows since they were made.
  var missing: seq[string]
  for layer in layers:
    if layer.part notin partAt and layer.part notin unplaced:
      missing.add layer.part
  sk.packLiveParts(missing)
  var resolved: seq[ResolvedLayer]
  for layer in layers:
    if layer.part notin partAt:
      continue
    let part = layer.part.facePart
    resolved.add ResolvedLayer(at: part.at,
      size: vec2(part.image.width.float32, part.image.height.float32),
      uv: partAt[layer.part])
  result = faceLayouts.len
  faceLayouts.add resolved
  faceIndex[state] = result

proc flatFace(sk: Silky, card: Card): ResolvedLayer =
  ## A printed face composed whole: every choice's branch is packed at
  ## startup; any other face the first time it is needed.
  let name = card.flatName
  if name notin partAt and name notin unplaced:
    if not hasPart(name):
      registerPart(name, FacePart(image: card.renderCardFace(),
        at: vec2(0, 0)))
    sk.packLiveParts([name])
  ResolvedLayer(size: vec2(CardFaceWidth.float32, CardFaceHeight.float32),
    uv: partAt.getOrDefault(name, vec2(-1, -1)))

proc clearLiveRows() =
  ## Takes back every part packed mid-game. The faces shown from now on
  ## lay out again, from the parts already made, and pack what they need.
  packer[] = startupPacker[]
  for name in liveParts:
    partAt.del name
  liveParts.setLen(0)
  pendingUploads.setLen(0)
  faceIndex.clear()
  faceLayouts.setLen(0)
  liveRowsFull = false

proc clear*(renderer: var CardRenderer) =
  ## Starts a frame's cards. Live rows that filled up last frame are
  ## cleared here, before any face of this frame is resolved.
  renderer.vertices.setLen(0)
  renderer.planes.setLen(0)
  if liveRowsFull:
    clearLiveRows()

proc quadCount*(renderer: CardRenderer): int =
  ## Quads queued this frame, for the benchmark.
  renderer.vertices.len div (6 * FloatsPerVertex)

proc addQuad(renderer: var CardRenderer, corners: array[4, Vec3],
    uvs: array[4, Vec2], brightness, damageFlash: float32, tint: Vec3) =
  ## Its card's plane is filled in by `draw`.
  for i in [0, 1, 2, 0, 2, 3]:
    let p = corners[i]
    renderer.vertices.add [p.x, p.y, p.z, uvs[i].x, uvs[i].y,
      brightness * tint.x, brightness * tint.y, brightness * tint.z,
      damageFlash, 0, 0, 0, 0, 0]

proc addPlane(renderer: var CardRenderer, corners: array[4, Vec3],
    first: int) =
  ## The quads added since `first` (a vertex index) lie on these corners.
  renderer.planes.add CardPlane(corners: corners, first: first,
    last: renderer.vertices.len div FloatsPerVertex)

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
  let first = renderer.vertices.len div FloatsPerVertex
  renderer.addQuad(corners, [vec2(left, top), vec2(left, bottom),
    vec2(right, bottom), vec2(right, top)], brightness, damageFlash, tint)
  renderer.addPlane(corners, first)

proc addFace*(renderer: var CardRenderer, sk: Silky,
    corners: array[4, Vec3], state: FaceState, brightness = 1.0'f32,
    damageFlash = 0.0'f32) =
  ## A card face over these corners (as addSurface), drawn from its layers,
  ## each over the last. Each layer samples the atlas exactly where a single
  ## face image spread over the same corners would: half a texel in at the
  ## face's edges.
  let
    first = renderer.vertices.len div FloatsPerVertex
    origin = corners[0]
    across = (corners[3] - corners[0]) / CardFaceWidth.float32
    down = (corners[1] - corners[0]) / CardFaceHeight.float32
    tint = vec3(1, 1, 1)
  proc uv(layer: ResolvedLayer, x, y: float32): Vec2 =
    vec2(layer.uv.x + x - layer.at.x + 0.5'f32 - x / CardFaceWidth.float32,
      layer.uv.y + y - layer.at.y + 0.5'f32 - y / CardFaceHeight.float32)
  for layer in faceLayouts[sk.faceLayout(state)]:
    let
      left = layer.at.x
      top = layer.at.y
      right = left + layer.size.x
      bottom = top + layer.size.y
    renderer.addQuad([origin + across * left + down * top,
      origin + across * left + down * bottom,
      origin + across * right + down * bottom,
      origin + across * right + down * top],
      [layer.uv(left, top), layer.uv(left, bottom), layer.uv(right, bottom),
      layer.uv(right, top)], brightness, damageFlash, tint)
  renderer.addPlane(corners, first)

proc det3(a, b, c: array[3, float64]): float64 =
  a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) +
    a[2] * (b[0] * c[1] - b[1] * c[0])

proc without(v: array[4, float64], skip: int): array[3, float64] =
  var j = 0
  for i in 0 .. 3:
    if i != skip:
      result[j] = v[i]
      inc j

proc clip(viewProjection: Mat4, p: Vec3): array[4, float64] =
  for row in 0 .. 3:
    result[row] = viewProjection[0, row].float64 * p.x.float64 +
      viewProjection[1, row].float64 * p.y.float64 +
      viewProjection[2, row].float64 * p.z.float64 +
      viewProjection[3, row].float64

proc planeDepth(viewProjection: Mat4, corners: array[4, Vec3],
    viewport: array[4, GLint]): array[5, float32] =
  ## A card's window depth as a plane over window pixels: its slopes per
  ## pixel, its depth at the card's centre and that centre. Worked out in
  ## doubles from the plane's equation in clip space, which holds wherever
  ## the corners project. A card seen edge-on, or whose centre isn't in
  ## front of the eye, gets a depth of -1 and keeps its rasterized depth.
  result[2] = -1
  let
    origin = viewProjection.clip(corners[0])
    across = viewProjection.clip(corners[3])
    down = viewProjection.clip(corners[1])
  var rows: array[3, array[4, float64]]
  for i in 0 .. 3:
    rows[0][i] = origin[i]
    rows[1][i] = across[i] - origin[i]
    rows[2][i] = down[i] - origin[i]
  # Every point of the plane has clip coordinates (x, y, z, w) with
  # n . (x, y, z, w) = 0, for the n orthogonal to all three rows.
  var n: array[4, float64]
  for i in 0 .. 3:
    n[i] = det3(rows[0].without(i), rows[1].without(i), rows[2].without(i))
    if i mod 2 == 1:
      n[i] = -n[i]
  if abs(n[2]) <= 1e-12 * (abs(n[0]) + abs(n[1]) + abs(n[2]) + abs(n[3])):
    return
  let centre = viewProjection.clip((corners[0] + corners[2]) * 0.5'f32)
  if centre[3] <= 0:
    return
  let
    width = viewport[2].float64
    height = viewport[3].float64
    # The centre on whole float32s, as the shader will read it.
    x = (viewport[0].float64 + (centre[0] / centre[3] + 1) * width * 0.5).float32
    y = (viewport[1].float64 + (centre[1] / centre[3] + 1) * height * 0.5).float32
    ndcX = (x.float64 - viewport[0].float64) * 2 / width - 1
    ndcY = (y.float64 - viewport[1].float64) * 2 / height - 1
    depth = (1 - (n[0] * ndcX + n[1] * ndcY + n[3]) / n[2]) * 0.5
  if depth < 0 or depth > 1:
    return
  [(-n[0] / (n[2] * width)).float32, (-n[1] / (n[2] * height)).float32,
    depth.float32, x, y]

proc draw*(renderer: var CardRenderer, sk: Silky, viewProjection: Mat4) =
  sk.flushCardFaces()
  if renderer.vertices.len == 0: return
  var viewport: array[4, GLint]
  glGetIntegerv(GL_VIEWPORT, viewport[0].addr)
  for plane in renderer.planes:
    let values = viewProjection.planeDepth(plane.corners, viewport)
    for vertex in plane.first ..< plane.last:
      for i, value in values:
        renderer.vertices[vertex * FloatsPerVertex + PlaneOffset + i] = value
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(GL_ARRAY_BUFFER, renderer.vertices.len * sizeof(float32),
    renderer.vertices[0].addr, GL_DYNAMIC_DRAW)
  var depthFunction: GLint
  glGetIntegerv(GL_DEPTH_FUNC, depthFunction.addr)
  glEnable(GL_DEPTH_TEST)
  # A card's later layers meet its earlier ones at exactly the same depth.
  glDepthFunc(GL_LEQUAL)
  glDepthMask(GL_TRUE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(renderer.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
  var matrix = viewProjection
  glUniformMatrix4fv(glGetUniformLocation(renderer.program, "cardViewProjection"),
    1, GL_FALSE, cast[ptr float32](matrix.addr))
  let atlasSize = sk.atlasImageSize()
  glUniform2f(glGetUniformLocation(renderer.program, "cardAtlasSize"),
    atlasSize.x.float32, atlasSize.y.float32)
  glUniform1i(glGetUniformLocation(renderer.program, "cardAtlasSampler"), 0)
  glBindVertexArray(renderer.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0,
    (renderer.vertices.len div FloatsPerVertex).GLsizei)
  glBindVertexArray(0)
  glDepthFunc(depthFunction.GLenum)

proc drawFace*(sk: Silky, state: FaceState, origin, size: Vec2,
    tint = rgbx(255, 255, 255, 255)) =
  ## A card face in the HUD, from the same layers as on the table. Drawn at
  ## its own 600x850 size on whole pixels, it is the reference composite.
  let scaleFactor = size / vec2(CardFaceWidth.float32, CardFaceHeight.float32)
  for layer in faceLayouts[sk.faceLayout(state)]:
    sk.drawQuad(origin + layer.at * scaleFactor, layer.size * scaleFactor,
      layer.uv, layer.size, tint)

proc drawFlatFace*(sk: Silky, card: Card, origin, size: Vec2,
    tint = rgbx(255, 255, 255, 255)) =
  ## A printed face as one image, for the choose screen: it fades and
  ## scales as a whole card, as it always has.
  let face = sk.flatFace(card)
  if face.uv.x >= 0:
    sk.drawQuad(origin, size, face.uv, face.size, tint)
