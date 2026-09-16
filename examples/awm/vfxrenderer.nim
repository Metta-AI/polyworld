## Additive VFX with an authored lightning texture and procedural particles.
## World-space effects respect scene depth and never write into it.
import std/[math, os]
import opengl, pixie, shady, vmath
import awmcore

type
  ActiveVfx* = object
    kind*: VfxKind
    target*: Choice
    position*: Vec3
    elapsed*, duration*: float32
    seed*: int

  VfxRenderer* = object
    program, vertexArray, vertexBuffer: GLuint
    lightningTexture: GLuint
    lightningAspect: float32
    vertices: seq[float32]

const
  HoverGold* = vec4(1.0, 0.82, 0.42, 1.0)
  TargetRed* = vec4(1.0, 0.035, 0.065, 1.0)

var
  vfxViewProjection: Uniform[Mat4]
  vfxLightningSampler: Uniform[Sampler2D]

proc vfxVertex(position: Vec3, uv: Vec2, ink: Vec4, style: float32,
    dimensions: Vec2, gl_Position: var Vec4, fragmentUv: var Vec2,
    fragmentInk: var Vec4, fragmentStyle: var float32,
    fragmentDimensions: var Vec2) =
  gl_Position = vfxViewProjection * vec4(position, 1)
  fragmentUv = uv
  fragmentInk = ink
  fragmentStyle = style
  fragmentDimensions = dimensions

proc vfxFragment(fragmentUv: Vec2, fragmentInk: Vec4,
    fragmentStyle: float32, fragmentDimensions: Vec2,
    outputColor: var Vec4) =
  var
    alpha = fragmentInk.a
    light = fragmentInk.rgb
  if fragmentStyle > 4.5'f32:
    # The mesh supplies the random path. Small ripples and changing branch
    # brightness animate the texture's fine detail without moving its terminals.
    var uv = fragmentUv
    let along = clamp((uv.y - 0.05'f32) / 0.9'f32, 0.0'f32, 1.0'f32)
    uv.x += sin(uv.y * 43.0'f32 + fragmentDimensions.x) *
      sin(along * 3.14159265'f32) * 0.006'f32
    let
      band = floor(uv.y * 10.0'f32)
      bandMix = fract(uv.y * 10.0'f32)
      branchSeed = fragmentDimensions.y + floor(uv.x + 0.5'f32) * 17.0'f32
      lower = fract(sin(band * 127.1'f32 + branchSeed * 311.7'f32) * 43758.5453'f32)
      upper = fract(sin((band + 1.0'f32) * 127.1'f32 + branchSeed * 311.7'f32) * 43758.5453'f32)
      branchLight = mix(lower, upper, bandMix * bandMix * (3.0'f32 - 2.0'f32 * bandMix))
      branches = smoothstep(0.08'f32, 0.24'f32, abs(uv.x - 0.5'f32))
    let bolt = texture(vfxLightningSampler, uv)
    # Pixie pixels are premultiplied; SRC_ALPHA additive blending needs this
    # conversion exactly once. Keep the core bright while forks vary softly.
    light *= bolt.rgb / max(bolt.a, 0.001'f32)
    alpha *= bolt.a * mix(1.0'f32, 0.3'f32 + branchLight, branches)
  elif fragmentStyle > 3.5'f32:
    let r = length(fragmentUv)
    alpha *= exp(-r * r * 8.0'f32) * max(0.0'f32, 1.0'f32 - r)
  elif fragmentStyle > 2.5'f32:
    let r2 = dot(fragmentUv, fragmentUv)
    if r2 >= 1.0'f32: discardFragment()
    let
      depth = sqrt(max(0.0'f32, 1.0'f32 - r2))
      rim = pow(1.0'f32 - depth, 3.0'f32)
      specular = exp(-dot(fragmentUv - vec2(-0.34, -0.42),
        fragmentUv - vec2(-0.34, -0.42)) * 95.0'f32)
      edge = exp(-pow(sqrt(r2) - 0.965'f32, 2.0'f32) * 4200.0'f32)
    light = mix(vec3(0.15, 0.73, 1.0), vec3(0.77, 0.38, 1.0),
      clamp(fragmentUv.x * 0.6'f32 + 0.5'f32, 0.0'f32, 1.0'f32))
    light += vec3(specular * 1.6'f32 + edge * 0.6'f32)
    alpha *= 0.025'f32 + rim * 0.6'f32 + edge * 0.75'f32 + specular
  elif fragmentStyle > 1.5'f32:
    let
      q = abs(fragmentUv) - (fragmentDimensions - vec2(0.08))
      distance = length(max(q, vec2(0))) +
        min(max(q.x, q.y), 0.0'f32) - 0.08'f32
    if distance < -0.045'f32: discardFragment()
    let
      haze = exp(-abs(distance) * 11.0'f32)
      core = exp(-distance * distance * 2300.0'f32)
    alpha *= haze * 0.65'f32 + core * 0.85'f32
    light += vec3(core * 0.32'f32)
  elif fragmentStyle > 0.5'f32:
    alpha *= exp(-fragmentUv.y * fragmentUv.y * 4.5'f32)
  outputColor = vec4(light, alpha)

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
    raise newException(CatchableError, "VFX shader failed: " & log)

proc initVfxRenderer*(textureRoot: string): VfxRenderer =
  const target = when defined(emscripten): glsl3WebGL else: glsl4Desktop
  let
    vertex = compileStage(GL_VERTEX_SHADER,
      toShader(vfxVertex, target, shaderVertex))
    fragment = compileStage(GL_FRAGMENT_SHADER,
      toShader(vfxFragment, target, shaderFragment))
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
    raise newException(CatchableError, "VFX shader link failed: " & log)
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  for attribute in [
    (name: "position", count: 3, offset: 0),
    (name: "uv", count: 2, offset: 3),
    (name: "ink", count: 4, offset: 5),
    (name: "style", count: 1, offset: 9),
    (name: "dimensions", count: 2, offset: 10)
  ]:
    let location = glGetAttribLocation(result.program, attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(location.GLuint, attribute.count.GLint, cGL_FLOAT,
      GL_FALSE, (12 * sizeof(float32)).GLsizei,
      cast[pointer](attribute.offset * sizeof(float32)))
  glBindVertexArray(0)

  let lightning = readImage(textureRoot / "lightning-strike.png")
  result.lightningAspect = lightning.width.float32 / lightning.height.float32
  glGenTextures(1, result.lightningTexture.addr)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, result.lightningTexture)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA.GLint, lightning.width.GLsizei,
    lightning.height.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, lightning.data[0].addr)
  glGenerateMipmap(GL_TEXTURE_2D)

proc clear*(renderer: var VfxRenderer) =
  renderer.vertices.setLen(0)

proc addQuad(renderer: var VfxRenderer, corners: array[4, Vec3],
    uvs: array[4, Vec2], ink: Vec4, style: float32, dimensions = vec2(1)) =
  for i in [0, 1, 2, 0, 2, 3]:
    let p = corners[i]
    renderer.vertices.add [p.x, p.y, p.z, uvs[i].x, uvs[i].y,
      ink.x, ink.y, ink.z, ink.w, style, dimensions.x, dimensions.y]

proc addCardHalo*(renderer: var VfxRenderer, center, right, down: Vec3,
    size: Vec2, ink: Vec4, strength = 1.0'f32) =
  let
    half = size * 0.5'f32
    extent = half + vec2(0.4)
    x = right * extent.x
    y = down * extent.y
  renderer.addQuad([center - x - y, center - x + y,
    center + x + y, center + x - y],
    [vec2(-extent.x, -extent.y), vec2(-extent.x, extent.y),
      extent, vec2(extent.x, -extent.y)],
    vec4(ink.xyz, ink.w * strength), 2, half)

proc addLine(renderer: var VfxRenderer, a, b, eye: Vec3,
    width: float32, ink: Vec4) =
  let normal = cross(b - a, eye - (a + b) * 0.5'f32)
  if length(normal) < 0.00001'f32: return
  let side = normalize(normal) * width
  renderer.addQuad([a - side, b - side, b + side, a + side],
    [vec2(0, -1), vec2(1, -1), vec2(1, 1), vec2(0, 1)], ink, 1)

proc addGlowLine(renderer: var VfxRenderer, a, b, eye: Vec3,
    width: float32, ink: Vec4) =
  renderer.addLine(a, b, eye, width * 4, vec4(ink.xyz, ink.w * 0.24))
  renderer.addLine(a, b, eye, width * 1.8, vec4(ink.xyz, ink.w * 0.55))
  renderer.addLine(a, b, eye, width * 0.45,
    vec4(mix(ink.xyz, vec3(1), 0.72'f32), ink.w))

proc addBillboard(renderer: var VfxRenderer, center: Vec3, radius: float32,
    eye: Vec3, ink: Vec4, style: float32) =
  let
    forward = normalize(eye - center)
    right = normalize(cross(vec3(0, 1, 0), forward)) * radius
    up = normalize(cross(forward, right)) * radius
  renderer.addQuad([center - right + up, center - right - up,
    center + right - up, center + right + up],
    [vec2(-1, -1), vec2(-1, 1), vec2(1, 1), vec2(1, -1)], ink, style)

proc addTargetRing*(renderer: var VfxRenderer, center, eye: Vec3,
    radius: float32, strength: float32) =
  for i in 0 ..< 64:
    let
      a = i.float32 * 2 * PI.float32 / 64
      b = (i + 1).float32 * 2 * PI.float32 / 64
    renderer.addGlowLine(center + vec3(cos(a), 0, sin(a)) * radius,
      center + vec3(cos(b), 0, sin(b)) * radius, eye, 0.025,
      vec4(TargetRed.xyz, strength))

proc newVfx*(kind: VfxKind, target: Choice, position: Vec3, seed: int): ActiveVfx =
  ActiveVfx(kind: kind, target: target, position: position, seed: seed,
    duration: case kind
      of LightningVfx: 0.95'f32
      of BubbleVfx: 1.05'f32
      of DamageFlashVfx: 0.55'f32
      of ArrowVfx: 0.75'f32
      of ManyArrowsVfx: 1.1'f32
      of SwordsIntoTheWindVfx: 1.15'f32
      of MightyShieldsVfx: 1.1'f32
      of SwordAndShieldVfx: 1.0'f32
      of MeleeVfx: 1.0'f32
      of SwordClashVfx: 0.9'f32
      of SwordBreakVfx: 1.0'f32
      of OozeSplatVfx: 1.0'f32
      of NoVfx, DeathVfx: 0.0'f32)

proc advance*(effects: var seq[ActiveVfx], dt: float32) =
  for effect in effects.mitems:
    effect.elapsed += dt
  for i in countdown(effects.high, 0):
    if effects[i].elapsed >= effects[i].duration:
      effects.delete(i)

proc flashStrength*(effects: openArray[ActiveVfx], target: Choice): float32 =
  for effect in effects:
    if effect.kind == DamageFlashVfx and effect.target == target:
      # Hold the impact long enough to read, then smoothly restore the model.
      let fade = clamp((effect.duration - effect.elapsed) / 0.35'f32,
        0.0'f32, 1.0'f32)
      result = max(result, fade * fade * (3 - 2 * fade))

proc particleNoise(index, salt, seed: int): float32 =
  ## A stable hash keeps each particle's trajectory continuous across frames.
  ## Only a new cast gets a new seed; drawing never consumes a random stream.
  var bits = uint32(seed) xor (uint32(index + 1) * 0x9e3779b9'u32) xor
    (uint32(salt) * 0x85ebca6b'u32)
  bits = (bits xor (bits shr 16)) * 0x7feb352d'u32
  bits = (bits xor (bits shr 15)) * 0x846ca68b'u32
  bits = bits xor (bits shr 16)
  (bits shr 8).float32 / 16777216.0'f32

proc addLightningTexture(renderer: var VfxRenderer, start, finish, eye: Vec3,
    age, strength: float32, seed, discharge: int) =
  if strength <= 0.002'f32: return
  let
    axis = finish - start
    normal = cross(axis, eye - (start + finish) * 0.5'f32)
  if length(normal) < 0.00001'f32: return
  let
    side = normalize(normal)
    packet = discharge * 64
    mirrored = particleNoise(packet, 20, seed) > 0.5'f32
    leftU = if mirrored: 1.0'f32 else: 0.0'f32
    rightU = 1.0'f32 - leftU
    halfWidth = length(axis) / 0.9'f32 * renderer.lightningAspect * 0.5'f32 *
      (0.78'f32 + particleNoise(packet, 21, seed) * 0.32'f32)
  # Midpoint displacement creates large bends with progressively smaller kinks.
  # Both endpoints stay at zero, anchoring every discharge to the same target.
  var offsets: array[17, float32]
  var
    step = 16
    spread = length(axis) * 0.16'f32
  while step > 1:
    let half = step div 2
    for left in countup(0, 16 - step, step):
      let middle = left + half
      offsets[middle] = (offsets[left] + offsets[left + step]) * 0.5'f32 +
        (particleNoise(packet + middle, step + 22, seed) * 2 - 1) * spread
    step = half
    spread *= 0.52'f32
  var
    centers: array[35, Vec3]
    widths: array[35, Vec3]
    rows: array[35, float32]
  for row in 0 ..< 35:
    # Include the transparent caps and exact 5%/95% texture terminals.
    let
      t = if row == 0: -0.05'f32 / 0.9'f32
        elif row == 34: 1 + 0.05'f32 / 0.9'f32
        else: (row - 1).float32 / 32
      along = clamp(t, 0.0'f32, 1.0'f32) * 16
      knot = min(15, int(along))
      offset = mix(offsets[knot], offsets[knot + 1], along - knot.float32)
    centers[row] = start + axis * t + side * offset
    widths[row] = side * halfWidth
    rows[row] = 0.05'f32 + t * 0.9'f32
  for row in 0 ..< 34:
    renderer.addQuad([centers[row] - widths[row], centers[row + 1] - widths[row + 1],
      centers[row + 1] + widths[row + 1], centers[row] + widths[row]],
      [vec2(leftU, rows[row]), vec2(leftU, rows[row + 1]),
        vec2(rightU, rows[row + 1]), vec2(rightU, rows[row])],
      vec4(1.15, 1.2, 1.3, strength), 5,
      vec2(age * 45, (seed mod 4096 + discharge * 37).float32))

proc addLightning(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  let
    age = effect.elapsed
    seed = effect.seed
    cameraRight = normalize(cross(vec3(0, 1, 0), normalize(eye - effect.position)))
    inward = if dot(effect.position, cameraRight) > 0: -1.0'f32 else: 1.0'f32
    start = effect.position + cameraRight * inward * (1.25'f32 + particleNoise(0, 30, seed) * 1.75'f32) +
      vec3(0, 4.6'f32 + particleNoise(0, 31, seed) * 0.55'f32, 0)
    interval = 0.055'f32 + particleNoise(0, 32, seed) * 0.025'f32
    discharge = int(age / interval)
    phase = age / interval - discharge.float32
    strikeFade = clamp(1 - age / 0.43'f32, 0.0'f32, 1.0'f32)
    flicker = 0.72'f32 + 0.28'f32 * exp(-phase * 5)
    restrikeTime = 0.11'f32 + particleNoise(0, 33, seed) * 0.07'f32
    restrike = exp(-pow((age - restrikeTime) / 0.04'f32, 2.0'f32))
    pulse = strikeFade * flicker + restrike * 0.35'f32
  renderer.addLightningTexture(start, effect.position, eye, age, pulse, seed, discharge)
  # Shapes snap on a time-based cadence, leaving only a short, faint afterimage.
  if discharge > 0:
    renderer.addLightningTexture(start, effect.position, eye, age,
      strikeFade * 0.18'f32 * exp(-phase * 8), seed, discharge - 1)
  renderer.addBillboard(effect.position, 1.55, eye,
    vec4(0.25, 0.63, 1.0, pulse * 1.15'f32), 4)
  renderer.addBillboard(effect.position, 0.46, eye,
    vec4(0.8, 0.93, 1.0, pulse * 1.7'f32), 4)

  # 88 ballistic sparks: varied launch times, directions, speeds, lengths,
  # and lifetimes give the impact a dense, irregular shower of white/cyan fire.
  for i in 0 ..< 88:
    let
      delay = particleNoise(i, 1, seed) * 0.07'f32
      elapsed = age - delay
      lifetime = 0.28'f32 + particleNoise(i, 2, seed) * 0.48'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 3, seed) * 2 * PI.float32
      elevation = particleNoise(i, 4, seed) * 1.7'f32 - 0.3'f32
      speed = 2.3'f32 + particleNoise(i, 5, seed) * 4.8'f32
      velocity = normalize(vec3(cos(angle), elevation, sin(angle))) * speed
      tailTime = max(0.0'f32, elapsed - 0.018'f32 - particleNoise(i, 6, seed) * 0.024'f32)
      head = effect.position + velocity * elapsed + vec3(0, -2.3'f32 * elapsed * elapsed, 0)
      tail = effect.position + velocity * tailTime + vec3(0, -2.3'f32 * tailTime * tailTime, 0)
      fade = clamp((lifetime - elapsed) / 0.2'f32, 0.0'f32, 1.0'f32)
      width = 0.009'f32 + particleNoise(i, 7, seed) * 0.016'f32
      ink = mix(vec3(0.09, 0.43, 1.0), vec3(0.5, 0.94, 1.0), particleNoise(i, 8, seed))
    renderer.addGlowLine(tail, head, eye, width, vec4(ink, fade * 0.92'f32))
    if i mod 3 == 0:
      renderer.addBillboard(head, width * 5, eye, vec4(0.7, 0.9, 1, fade), 4)

  # 40 slower ions hang around the impact after the trunk has burned away.
  for i in 0 ..< 40:
    let
      delay = particleNoise(i, 11, seed) * 0.13'f32
      elapsed = age - delay
      lifetime = 0.45'f32 + particleNoise(i, 12, seed) * 0.36'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 13, seed) * 2 * PI.float32
      velocity = vec3(cos(angle), particleNoise(i, 14, seed) * 1.3'f32, sin(angle)) *
        (0.8'f32 + particleNoise(i, 15, seed) * 1.7'f32)
      position = effect.position + velocity * elapsed + vec3(0, elapsed * 0.3'f32, 0)
      fade = pow(max(0.0'f32, 1 - elapsed / lifetime), 0.7'f32)
      shimmer = 0.6'f32 + 0.4'f32 * abs(sin(elapsed * 29 + i.float32))
    renderer.addBillboard(position, 0.035'f32 + particleNoise(i, 16, seed) * 0.07'f32,
      eye, vec4(0.16, 0.65, 1.0, fade * shimmer), 4)

proc addBubble(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  let
    t = effect.elapsed / effect.duration
    appear = min(1.0'f32, effect.elapsed / 0.12'f32)
    pop = clamp((t - 0.8'f32) / 0.2'f32, 0.0'f32, 1.0'f32)
    radius = (1.27'f32 + sin(t * 10) * 0.035'f32 + pop * 0.55'f32) *
      (0.45'f32 + appear * 0.55'f32)
  renderer.addBillboard(effect.position, radius, eye,
    vec4(1, 1, 1, appear * (1 - pop)), 3)
  for i in 0 ..< 9:
    let
      angle = i.float32 * 2 * PI.float32 / 9 + t * 0.9'f32
      offset = vec3(cos(angle), sin(angle) * 0.65'f32 + 0.15'f32,
        sin(angle) * 0.5'f32) * (radius + pop * 0.7'f32)
    renderer.addBillboard(effect.position + offset, 0.07'f32 + pop * 0.045'f32,
      eye, vec4(0.5, 0.8, 1, appear * (1 - pop)), 3)

proc addArrowShot(renderer: var VfxRenderer, target, start: Vec3,
    age: float32, seed: int, eye: Vec3, lift = 1.1'f32, glow = 1.0'f32) =
  ## One fletched arrow flies from `start`, sticks in `target`, then splinters.
  const flight = 0.22'f32
  let
    t = min(1.0'f32, age / flight)
    tip = mix(start, target, t) + vec3(0, lift * 4 * t * (1 - t), 0)
    direction = normalize(target - start +
      vec3(0, lift * 4 * (1 - 2 * t), 0))
    impactAge = age - flight
    fade = if impactAge < 0: 1.0'f32
      else: clamp(1 - impactAge / 0.4'f32, 0.0'f32, 1.0'f32)
    normal = cross(direction, eye - tip)
  if fade > 0.002'f32 and length(normal) > 0.00001'f32:
    let
      side = normalize(normal)
      tail = tip - direction * 1.05'f32
      barb = tip - direction * 0.22'f32
      ink = vec4(1.0, 0.72, 0.32, fade)
    if impactAge < 0:
      # A short streak behind the arrow sells its speed during flight.
      let
        t0 = max(0.0'f32, t - 0.45'f32)
        trail = mix(start, target, t0) +
          vec3(0, lift * 4 * t0 * (1 - t0), 0)
      renderer.addLine(trail, tail, eye, 0.035, vec4(1.0, 0.85, 0.55, 0.22))
    renderer.addGlowLine(tail, tip, eye, 0.016, ink)
    renderer.addGlowLine(barb + side * 0.11'f32, tip, eye, 0.013, ink)
    renderer.addGlowLine(barb - side * 0.11'f32, tip, eye, 0.013, ink)
    for offset in [-0.1'f32, 0.1'f32]:
      renderer.addGlowLine(tail + direction * 0.2'f32, tail + side * offset,
        eye, 0.011, vec4(1.0, 0.9, 0.7, fade * 0.8'f32))
  if impactAge < 0: return

  renderer.addBillboard(target, 0.95, eye,
    vec4(1.0, 0.62, 0.22, exp(-impactAge * 9) * 1.1'f32 * glow), 4)
  # Splinters kick back toward the shooter, falling under a light gravity.
  for i in 0 ..< 36:
    let
      delay = particleNoise(i, 42, seed) * 0.04'f32
      elapsed = impactAge - delay
      lifetime = 0.2'f32 + particleNoise(i, 43, seed) * 0.3'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 44, seed) * 2 * PI.float32
      scatter = vec3(cos(angle), particleNoise(i, 45, seed) * 1.4'f32, sin(angle))
      speed = 1.8'f32 + particleNoise(i, 46, seed) * 3.2'f32
      velocity = normalize(scatter - direction * 1.2'f32) * speed
      tailTime = max(0.0'f32, elapsed - 0.02'f32)
      head = target + velocity * elapsed +
        vec3(0, -3.0'f32 * elapsed * elapsed, 0)
      back = target + velocity * tailTime +
        vec3(0, -3.0'f32 * tailTime * tailTime, 0)
      sparkFade = clamp((lifetime - elapsed) / 0.15'f32, 0.0'f32, 1.0'f32)
      ink = mix(vec3(0.95, 0.42, 0.12), vec3(1.0, 0.86, 0.5),
        particleNoise(i, 47, seed))
    renderer.addGlowLine(back, head, eye,
      0.008'f32 + particleNoise(i, 48, seed) * 0.012'f32,
      vec4(ink, sparkFade * 0.9'f32))

proc addArrow(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A fletched arrow arcs in from the table side, sticks, then splinters.
  let
    seed = effect.seed
    cameraRight = normalize(cross(vec3(0, 1, 0), normalize(eye - effect.position)))
    inward = if dot(effect.position, cameraRight) > 0: -1.0'f32 else: 1.0'f32
    start = effect.position +
      cameraRight * inward * (4.5'f32 + particleNoise(0, 40, seed)) +
      vec3(0, 1.4'f32 + particleNoise(0, 41, seed) * 0.6'f32, 0)
  renderer.addArrowShot(effect.position, start, effect.elapsed, seed, eye)

proc addArrowVolley(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A staggered volley drops steeply around the target from overhead.
  const volley = 5
  for i in 0 ..< volley:
    let
      delay = i.float32 * 0.07'f32 + particleNoise(i, 50, effect.seed) * 0.05'f32
      age = effect.elapsed - delay
    if age < 0: continue
    let
      angle = particleNoise(i, 51, effect.seed) * 2 * PI.float32
      around = vec3(cos(angle), 0, sin(angle))
      target = effect.position +
        around * (0.2'f32 + particleNoise(i, 52, effect.seed) * 0.45'f32)
      start = target + around * 1.1'f32 +
        vec3(0, 5.0'f32 + particleNoise(i, 53, effect.seed), 0)
    renderer.addArrowShot(target, start, age, effect.seed + i * 7919, eye,
      lift = 0.25'f32, glow = 0.55'f32)

proc addSword(renderer: var VfxRenderer, hilt, direction, eye: Vec3,
    alpha: float32) =
  ## A steel blade with a gold crossguard and grip, pointing along `direction`.
  let normal = cross(direction, eye - hilt)
  if alpha <= 0.002'f32 or length(normal) < 0.00001'f32: return
  let
    side = normalize(normal)
    tip = hilt + direction * 0.95'f32
    gold = vec4(1.0, 0.76, 0.3, alpha)
  renderer.addGlowLine(hilt, tip, eye, 0.022, vec4(0.78, 0.88, 1.0, alpha))
  renderer.addGlowLine(hilt - side * 0.17'f32, hilt + side * 0.17'f32, eye,
    0.016, gold)
  renderer.addGlowLine(hilt, hilt - direction * 0.24'f32, eye, 0.018, gold)
  renderer.addBillboard(tip, 0.14, eye, vec4(0.9, 0.96, 1, alpha * 0.9'f32), 4)

proc addSwordsIntoTheWind(renderer: var VfxRenderer, effect: ActiveVfx,
    eye: Vec3) =
  ## Three blades rise from the minion and spiral away on a gust, while a
  ## warm flash marks the minion growing stronger.
  const blades = 3
  let
    seed = effect.seed
    age = effect.elapsed
  renderer.addBillboard(effect.position, 1.35, eye,
    vec4(1.0, 0.72, 0.28, exp(-age * 5) * 0.8'f32), 4)
  # The gust: short helical streaks sweeping upward around the minion.
  for i in 0 ..< 7:
    let
      delay = particleNoise(i, 60, seed) * 0.3'f32
      lifetime = 0.45'f32 + particleNoise(i, 61, seed) * 0.25'f32
      t = (age - delay) / lifetime
    if t <= 0 or t >= 1: continue
    let
      start = particleNoise(i, 62, seed) * 2 * PI.float32
      radius = 0.8'f32 + particleNoise(i, 63, seed) * 0.5'f32
      alpha = sin(t * PI.float32) * 0.32'f32
    var previous: Vec3
    for step in 0 .. 8:
      let
        k = step.float32 / 8
        sweep = t + k * 0.35'f32
        angle = start + sweep * 3.2'f32
        point = effect.position +
          vec3(cos(angle) * radius, 0.2'f32 + sweep * 2.2'f32, sin(angle) * radius)
      if step > 0:
        renderer.addLine(previous, point, eye, 0.012'f32 * (0.4'f32 + k),
          vec4(0.85, 0.93, 1.0, alpha * k))
      previous = point
  for i in 0 ..< blades:
    let delay = i.float32 * 0.08'f32
    if age < delay: continue
    let
      t = clamp((age - delay) / (effect.duration - 0.2'f32), 0.0'f32, 1.0'f32)
      rise = t * t * (3 - 2 * t)
      angle = i.float32 * 2 * PI.float32 / blades +
        particleNoise(i, 64, seed) * 0.6'f32 + rise * 3.4'f32
      around = vec3(cos(angle), 0, sin(angle))
      tangent = vec3(-sin(angle), 0, cos(angle))
      hilt = effect.position + around * (1.0'f32 - 0.4'f32 * rise) +
        vec3(0, 0.15'f32 + rise * 2.8'f32, 0)
      # Blades point up and lean into the gust's spin.
      direction = normalize(vec3(0, 1, 0) + tangent * 0.45'f32 +
        around * 0.15'f32)
      appear = min(1.0'f32, (age - delay) / 0.12'f32)
      fade = clamp((1 - t) / 0.35'f32, 0.0'f32, 1.0'f32)
    renderer.addSword(hilt, direction, eye, appear * fade)

proc facing(center, eye: Vec3): tuple[right, up: Vec3] =
  ## Axes of a camera-facing plane at `center`.
  let
    forward = normalize(eye - center)
    right = normalize(cross(vec3(0, 1, 0), forward))
  (right, normalize(cross(forward, right)))

proc addShield(renderer: var VfxRenderer, center, eye: Vec3, size: float32,
    ink: Vec4) =
  ## A camera-facing kite shield outline with a glowing boss.
  let
    axes = facing(center, eye)
    outline = [vec2(-0.85, 0.75), vec2(0, 1), vec2(0.85, 0.75),
      vec2(0.8, -0.15), vec2(0, -1), vec2(-0.8, -0.15)]
  proc at(point: Vec2): Vec3 =
    center + axes.right * (point.x * size) + axes.up * (point.y * size)
  for i in 0 ..< outline.len:
    renderer.addGlowLine(at(outline[i]), at(outline[(i + 1) mod outline.len]),
      eye, 0.03'f32 * size, ink)
  renderer.addBillboard(center + axes.up * (0.1'f32 * size), 0.2'f32 * size,
    eye, vec4(ink.xyz, ink.w * 0.9'f32), 4)

proc addMightyShields(renderer: var VfxRenderer, effect: ActiveVfx,
    eye: Vec3) =
  ## A shield descends onto the minion and flares; a blue ring spreads out
  ## over the table as it lands.
  let
    age = effect.elapsed
    t = age / effect.duration
    settle = min(1.0'f32, age / 0.35'f32)
    ease = 1 - (1 - settle) * (1 - settle)
    fade = clamp((1 - t) / 0.35'f32, 0.0'f32, 1.0'f32)
    # Small and low, so each shield reads as its own minion's.
    center = effect.position + vec3(0, 0.9'f32 - 0.45'f32 * ease, 0)
    flare = exp(-max(0.0'f32, age - 0.35'f32) * 7) * settle
  renderer.addShield(center, eye, 0.3'f32 + 0.12'f32 * ease,
    vec4(0.45, 0.75, 1.0, fade))
  renderer.addBillboard(center, 0.8, eye, vec4(0.3, 0.6, 1.0, flare * 0.7'f32), 4)
  let ringAge = age - 0.3'f32
  if ringAge > 0:
    let
      radius = 0.6'f32 + ringAge * 2.2'f32
      alpha = clamp(1 - ringAge / 0.6'f32, 0.0'f32, 1.0'f32) * 0.8'f32
    for i in 0 ..< 48:
      let
        a = i.float32 * 2 * PI.float32 / 48
        b = (i + 1).float32 * 2 * PI.float32 / 48
      renderer.addGlowLine(
        effect.position + vec3(cos(a), 0, sin(a)) * radius,
        effect.position + vec3(cos(b), 0, sin(b)) * radius,
        eye, 0.02, vec4(0.4, 0.7, 1.0, alpha))

proc addSwordAndShield(renderer: var VfxRenderer, effect: ActiveVfx,
    eye: Vec3) =
  ## A sword crossed behind a shield rises over the minion, then fades.
  let
    age = effect.elapsed
    t = age / effect.duration
    alpha = min(1.0'f32, age / 0.15'f32) *
      clamp((1 - t) / 0.35'f32, 0.0'f32, 1.0'f32)
    # Kept low: from the player's seat, anything higher reads as belonging
    # to the minion across the table.
    center = effect.position + vec3(0, 0.45'f32 + (1 - exp(-age * 4)) * 0.4'f32, 0)
    axes = facing(center, eye)
    blade = normalize(axes.up + axes.right * 0.8'f32)
  renderer.addBillboard(center, 1.2, eye,
    vec4(1.0, 0.72, 0.3, exp(-age * 5) * 0.7'f32), 4)
  renderer.addSword(center - blade * 0.55'f32, blade, eye, alpha)
  renderer.addShield(center - axes.up * 0.05'f32, eye, 0.42,
    vec4(1.0, 0.78, 0.35, alpha))

proc addMelee(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## An arrow hangs over the minion, trembles, snaps in two, and its halves
  ## tumble away: the minion is no longer a ranged fighter.
  const snapAt = 0.3'f32
  let
    age = effect.elapsed
    seed = effect.seed
    center = effect.position + vec3(0, 0.7, 0)
    axes = facing(center, eye)
    fade = clamp((effect.duration - age) / 0.3'f32, 0.0'f32, 1.0'f32)
    wood = vec4(1.0, 0.72, 0.32, min(1.0'f32, age / 0.12'f32) * fade)
    fall = max(0.0'f32, age - snapAt)
    tremble =
      if age < snapAt: sin(age * 90) * 0.03'f32 * (age / snapAt) else: 0.0'f32
  for side in [-1.0'f32, 1.0'f32]:
    # Each half pivots down at the break and drops away from it.
    let
      angle = fall * 2.4'f32
      outward = axes.right * (side * cos(angle)) - axes.up * sin(angle)
      normal = axes.up * cos(angle) + axes.right * (side * sin(angle))
      inner = center + axes.up * tremble + axes.right * (side * fall * 0.6'f32) -
        axes.up * (2.6'f32 * fall * fall)
      outer = inner + outward * 0.75'f32
      back = outer - outward * 0.2'f32
    renderer.addGlowLine(inner, outer, eye, 0.018, wood)
    if side > 0:
      renderer.addGlowLine(back + normal * 0.1'f32, outer, eye, 0.014, wood)
      renderer.addGlowLine(back - normal * 0.1'f32, outer, eye, 0.014, wood)
    else:
      for offset in [-0.1'f32, 0.1'f32]:
        renderer.addGlowLine(outer, back + normal * offset, eye, 0.011,
          vec4(1.0, 0.9, 0.7, wood.w * 0.8'f32))
  if age < snapAt: return
  let snapAge = age - snapAt
  renderer.addBillboard(center, 0.9, eye,
    vec4(1.0, 0.3, 0.15, exp(-snapAge * 8) * 0.9'f32), 4)
  for i in 0 ..< 16:
    let lifetime = 0.2'f32 + particleNoise(i, 80, seed) * 0.25'f32
    if snapAge >= lifetime: continue
    let
      angle = particleNoise(i, 81, seed) * 2 * PI.float32
      velocity = normalize(vec3(cos(angle), particleNoise(i, 82, seed) * 1.2'f32,
        sin(angle))) * (1.5'f32 + particleNoise(i, 83, seed) * 2.5'f32)
      head = center + velocity * snapAge + vec3(0, -3.0'f32 * snapAge * snapAge, 0)
      tail = center + velocity * max(0.0'f32, snapAge - 0.03'f32)
      sparkFade = clamp((lifetime - snapAge) / 0.12'f32, 0.0'f32, 1.0'f32)
    renderer.addGlowLine(tail, head, eye, 0.01, vec4(1.0, 0.6, 0.25, sparkFade))

proc addSwordClash(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## Two blades swing in and cross over the minion; sparks burst on impact.
  const strike = 0.22'f32
  let
    age = effect.elapsed
    seed = effect.seed
    center = effect.position + vec3(0, 1.1, 0)
    axes = facing(center, eye)
    swing = min(1.0'f32, age / strike)
    ease = swing * swing
    fade = clamp((effect.duration - age) / 0.3'f32, 0.0'f32, 1.0'f32)
    recoil = if age > strike: min(0.12'f32, (age - strike) * 0.6'f32) else: 0.0'f32
  for side in [-1.0'f32, 1.0'f32]:
    # Each blade swings from upright and wide to leaning across the center.
    let
      angle = 0.2'f32 + ease * 0.55'f32
      direction = normalize(axes.up * cos(angle) - axes.right * (side * sin(angle)))
      hilt = center +
        axes.right * (side * (1.2'f32 - 0.55'f32 * ease + recoil)) -
        axes.up * 0.45'f32
    renderer.addSword(hilt, direction, eye, fade)
  if age < strike: return
  let
    impact = age - strike
    spark = center + axes.up * 0.2'f32
  renderer.addBillboard(spark, 1.0, eye,
    vec4(1.0, 0.9, 0.6, exp(-impact * 9) * 1.2'f32), 4)
  for i in 0 ..< 40:
    let
      elapsed = impact - particleNoise(i, 70, seed) * 0.03'f32
      lifetime = 0.25'f32 + particleNoise(i, 71, seed) * 0.3'f32
    if elapsed < 0 or elapsed >= lifetime: continue
    let
      angle = particleNoise(i, 72, seed) * 2 * PI.float32
      velocity = normalize(vec3(cos(angle),
        particleNoise(i, 73, seed) * 1.6'f32 - 0.2'f32, sin(angle))) *
        (2.0'f32 + particleNoise(i, 74, seed) * 3.5'f32)
      tailTime = max(0.0'f32, elapsed - 0.025'f32)
      head = spark + velocity * elapsed + vec3(0, -3.0'f32 * elapsed * elapsed, 0)
      tail = spark + velocity * tailTime + vec3(0, -3.0'f32 * tailTime * tailTime, 0)
      sparkFade = clamp((lifetime - elapsed) / 0.15'f32, 0.0'f32, 1.0'f32)
      ink = mix(vec3(1.0, 0.55, 0.15), vec3(1.0, 0.95, 0.7),
        particleNoise(i, 75, seed))
    renderer.addGlowLine(tail, head, eye, 0.01, vec4(ink, sparkFade))

proc addSwordBreak(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A sword hangs point-down over the minion, trembles, cracks, and its
  ## halves tumble apart: the minion hits less hard.
  const snapAt = 0.3'f32
  let
    age = effect.elapsed
    seed = effect.seed
    center = effect.position + vec3(0, 0.7, 0)
    axes = facing(center, eye)
    alpha = min(1.0'f32, age / 0.12'f32) *
      clamp((effect.duration - age) / 0.3'f32, 0.0'f32, 1.0'f32)
    steel = vec4(0.78, 0.88, 1.0, alpha)
    gold = vec4(1.0, 0.76, 0.3, alpha)
    fall = max(0.0'f32, age - snapAt)
    tremble =
      if age < snapAt: sin(age * 90) * 0.03'f32 * (age / snapAt) else: 0.0'f32
  for side in [-1.0'f32, 1.0'f32]:
    # +1 is the hilt half above the crack, -1 the point half below it; they
    # spin in opposite directions as they drop.
    let
      tilt = fall * 2.2'f32 * side
      along = axes.up * (side * cos(tilt)) + axes.right * sin(tilt)
      across = axes.right * cos(tilt) - axes.up * (side * sin(tilt))
      pivot = center + axes.right * (tremble + side * fall * 0.5'f32) -
        axes.up * (2.6'f32 * fall * fall)
      outer = pivot + along * 0.5'f32
    renderer.addGlowLine(pivot, outer, eye, 0.022, steel)
    if side > 0:
      renderer.addGlowLine(outer - across * 0.17'f32,
        outer + across * 0.17'f32, eye, 0.016, gold)
      renderer.addGlowLine(outer, outer + along * 0.24'f32, eye, 0.018, gold)
  if age < snapAt: return
  let snapAge = age - snapAt
  renderer.addBillboard(center, 0.8, eye,
    vec4(0.85, 0.92, 1.0, exp(-snapAge * 8) * 0.9'f32), 4)
  for i in 0 ..< 18:
    let lifetime = 0.2'f32 + particleNoise(i, 90, seed) * 0.25'f32
    if snapAge >= lifetime: continue
    let
      angle = particleNoise(i, 91, seed) * 2 * PI.float32
      velocity = normalize(vec3(cos(angle), particleNoise(i, 92, seed) * 1.2'f32,
        sin(angle))) * (1.5'f32 + particleNoise(i, 93, seed) * 2.5'f32)
      head = center + velocity * snapAge + vec3(0, -3.0'f32 * snapAge * snapAge, 0)
      tail = center + velocity * max(0.0'f32, snapAge - 0.03'f32)
      sparkFade = clamp((lifetime - snapAge) / 0.12'f32, 0.0'f32, 1.0'f32)
    renderer.addGlowLine(tail, head, eye, 0.01, vec4(0.9, 0.95, 1.0, sparkFade))

proc addOozeSplat(renderer: var VfxRenderer, effect: ActiveVfx, eye: Vec3) =
  ## A glob of ooze drops onto the minion and bursts into droplets and a
  ## spreading green puddle.
  const impact = 0.28'f32
  let
    age = effect.elapsed
    seed = effect.seed
  if age < impact:
    let
      t = age / impact
      drop = effect.position + vec3(0, 3.2'f32 * (1 - t * t), 0)
    renderer.addBillboard(drop, 0.45, eye, vec4(0.35, 1.0, 0.3, 0.9), 4)
    renderer.addBillboard(drop, 0.2, eye, vec4(0.8, 1.0, 0.6, 1.0), 4)
    return
  let
    splat = age - impact
    fade = clamp((effect.duration - age) / 0.3'f32, 0.0'f32, 1.0'f32)
    radius = 0.4'f32 + (1 - exp(-splat * 5)) * 1.1'f32
  renderer.addBillboard(effect.position, 1.3, eye,
    vec4(0.3, 0.95, 0.25, exp(-splat * 6) * 0.9'f32), 4)
  for i in 0 ..< 40:
    let
      a = i.float32 * 2 * PI.float32 / 40
      b = (i + 1).float32 * 2 * PI.float32 / 40
    renderer.addGlowLine(
      effect.position + vec3(cos(a), 0, sin(a)) * radius,
      effect.position + vec3(cos(b), 0, sin(b)) * radius,
      eye, 0.025, vec4(0.35, 0.95, 0.3, 0.6'f32 * fade))
  for i in 0 ..< 24:
    let lifetime = 0.35'f32 + particleNoise(i, 100, seed) * 0.35'f32
    if splat >= lifetime: continue
    let
      angle = particleNoise(i, 101, seed) * 2 * PI.float32
      speed = 1.2'f32 + particleNoise(i, 102, seed) * 2.0'f32
      velocity = vec3(cos(angle) * speed,
        2.0'f32 + particleNoise(i, 103, seed) * 2.5'f32, sin(angle) * speed)
      droplet = effect.position + velocity * splat +
        vec3(0, -6.0'f32 * splat * splat, 0)
      alpha = clamp((lifetime - splat) / 0.15'f32, 0.0'f32, 1.0'f32)
    renderer.addBillboard(droplet,
      0.08'f32 + particleNoise(i, 104, seed) * 0.1'f32, eye,
      vec4(0.4, 1.0, 0.35, alpha), 4)

proc addEffects*(renderer: var VfxRenderer, effects: openArray[ActiveVfx],
    eye: Vec3) =
  for effect in effects:
    case effect.kind
    of LightningVfx: renderer.addLightning(effect, eye)
    of BubbleVfx: renderer.addBubble(effect, eye)
    of ArrowVfx: renderer.addArrow(effect, eye)
    of ManyArrowsVfx: renderer.addArrowVolley(effect, eye)
    of SwordsIntoTheWindVfx: renderer.addSwordsIntoTheWind(effect, eye)
    of MightyShieldsVfx: renderer.addMightyShields(effect, eye)
    of SwordAndShieldVfx: renderer.addSwordAndShield(effect, eye)
    of MeleeVfx: renderer.addMelee(effect, eye)
    of SwordClashVfx: renderer.addSwordClash(effect, eye)
    of SwordBreakVfx: renderer.addSwordBreak(effect, eye)
    of OozeSplatVfx: renderer.addOozeSplat(effect, eye)
    of DamageFlashVfx:
      let t = effect.elapsed / effect.duration
      renderer.addBillboard(effect.position, 1.2'f32 + t * 0.8'f32, eye,
        vec4(1, 0.025, 0.05, (1 - t) * 0.38'f32), 4)
    of NoVfx, DeathVfx: discard

proc draw*(renderer: var VfxRenderer, viewProjection: Mat4,
    additive = true, depthTest = true) =
  if renderer.vertices.len == 0: return
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(GL_ARRAY_BUFFER, renderer.vertices.len * sizeof(float32),
    renderer.vertices[0].addr, GL_DYNAMIC_DRAW)
  if depthTest: glEnable(GL_DEPTH_TEST)
  else: glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, if additive: GL_ONE else: GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(renderer.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, renderer.lightningTexture)
  glUniform1i(glGetUniformLocation(renderer.program, "vfxLightningSampler"), 0)
  vfxViewProjection = viewProjection
  glUniformMatrix4fv(glGetUniformLocation(renderer.program, "vfxViewProjection"),
    1, GL_FALSE, cast[ptr float32](vfxViewProjection.addr))
  glBindVertexArray(renderer.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, (renderer.vertices.len div 12).GLsizei)
  glBindVertexArray(0)
  glDepthMask(GL_TRUE)

proc drawCharacterFlash*(renderer: var VfxRenderer, stencilRef: int,
    strength: float32) =
  ## Stencil retains the visible character silhouette, including skinning and
  ## cutout materials. A red overlay stays bright even on blue/dark clothing.
  if strength <= 0: return
  var savedVertices = move(renderer.vertices)
  renderer.addQuad([vec3(-1, 1, 0), vec3(-1, -1, 0),
    vec3(1, -1, 0), vec3(1, 1, 0)],
    [vec2(0), vec2(0), vec2(0), vec2(0)],
    vec4(1, 0.025, 0.045, strength * 0.88'f32), 0)
  glEnable(GL_STENCIL_TEST)
  glStencilMask(0)
  glStencilFunc(GL_EQUAL, stencilRef.GLint, 0xff)
  glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP)
  renderer.draw(mat4(), additive = false, depthTest = false)
  glDisable(GL_STENCIL_TEST)
  glStencilMask(0xff)
  renderer.vertices = move(savedVertices)
