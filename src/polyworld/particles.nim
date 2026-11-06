## Bounded GPU particle effects shared by Polyworld game renderers.

import
  std/[math, strutils],
  opengl, shady, vmath,
  particleshaders

const
  MaximumParticleEffects = 192
  ParticleUniformNames = [
    "uParticleViewProjection",
    "uParticleCameraRight",
    "uParticleCameraUp",
    "uParticleCameraForward",
    "uParticleTime",
    "uParticleStartTime",
    "uParticleTravelTime",
    "uParticleSeed",
    "uParticleEffectKind",
    "uParticleOrigin",
    "uParticleTarget"
  ]
  ParticleVertexSource =
    when defined(emscripten):
      toShader(gameParticleVertex, glsl3WebGL, shaderVertex).replace(
        "precision highp float;",
        "precision highp float;\nprecision highp int;"
      )
    else:
      toShader(gameParticleVertex, glsl4Desktop, shaderVertex)
  ParticleFragmentSource =
    when defined(emscripten):
      toShader(gameParticleFragment, glsl3WebGL, shaderFragment).replace(
        "precision highp float;",
        "precision highp float;\nprecision highp int;"
      )
    else:
      toShader(gameParticleFragment, glsl4Desktop, shaderFragment)

type
  ParticleError* = object of CatchableError

  ParticleUniform = enum
    ViewProjectionUniform,
    CameraRightUniform,
    CameraUpUniform,
    CameraForwardUniform,
    TimeUniform,
    StartTimeUniform,
    TravelTimeUniform,
    SeedUniform,
    EffectKindUniform,
    OriginUniform,
    TargetUniform

  ParticleProgram = object
    id: GLuint
    locations: array[ParticleUniform, GLint]

  ParticleEffect = object
    kind: ParticleEffectKind
    origin: Vec3
    target: Vec3
    startTime: float32
    travelTime: float32
    endTime: float32
    seed: uint32
    owner: int32
    anchor: int32
      ## What the effect travels with, or 0; see `followParticleAnchors`.

  ParticleSystem* = object
    program: ParticleProgram
    vertexArray: GLuint
    effects: seq[ParticleEffect]
    time: float32
    nextSeed: uint32

proc compileParticleStage(
    kind: GLenum,
    source,
    label: string
): GLuint =
  ## Compiles one particle shader stage or raises its full diagnostic.
  result = glCreateShader(kind)
  var sources = allocCStringArray([source])
  defer: deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok != 0:
    return
  var length: GLint
  glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
  var log = newString(max(length.int, 1))
  glGetShaderInfoLog(result, length, nil, log.cstring)
  glDeleteShader(result)
  let message = label & " failed:\n" & log.strip(chars = {'\0'}) &
    "\nExpanded source:\n" & source
  echo message
  raise newException(ParticleError, message)

proc compileParticleProgram(): ParticleProgram =
  ## Compiles and links the shared semantic particle shader pair.
  let
    vertex = compileParticleStage(
      GL_VERTEX_SHADER,
      ParticleVertexSource,
      "particle vertex shader"
    )
    fragment = compileParticleStage(
      GL_FRAGMENT_SHADER,
      ParticleFragmentSource,
      "particle fragment shader"
    )
  result.id = glCreateProgram()
  glAttachShader(result.id, vertex)
  glAttachShader(result.id, fragment)
  glLinkProgram(result.id)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var ok: GLint
  glGetProgramiv(result.id, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetProgramiv(result.id, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(max(length.int, 1))
    glGetProgramInfoLog(result.id, length, nil, log.cstring)
    glDeleteProgram(result.id)
    raise newException(
      ParticleError,
      "particle shaders failed to link:\n" & log.strip(chars = {'\0'})
    )
  for uniform in ParticleUniform:
    result.locations[uniform] = glGetUniformLocation(
      result.id,
      ParticleUniformNames[uniform.ord].cstring
    )

proc initParticleSystem*(): ParticleSystem =
  ## Creates the shared shaders and empty instanced-quad vertex array.
  result.program = compileParticleProgram()
  result.nextSeed = 1
  glGenVertexArrays(1, result.vertexArray.addr)

proc effectParticleCount(kind: ParticleEffectKind): int =
  ## Returns the bounded instance count for one semantic effect.
  case kind
  of CombatSparks:
    24
  of MagicBolt:
    36
  of MagicBurst, PortalBurst, PoisonBurst:
    32
  of Fireball:
    52
  of FireBurst:
    40
  of ArrowWake:
    24
  of PoisonCapsule:
    24
  of LeafBolt, LeafBurst:
    12
  of HealingAura, ManaAura, PoisonAura:
    48
  of BloomSeed:
    24
  of BloomPetals:
    56
  of RootLeaves:
    36
  of SolarOrb:
    48
  of SolarFlames:
    112
  of MendingAura:
    40
  of BladeFlame:
    24
  of FireWave:
    160
  of HeatEmbers:
    40

proc effectLifetime(
    kind: ParticleEffectKind,
    travelTime: float32
): float32 =
  ## Returns how long one effect must remain available for drawing.
  case kind
  of CombatSparks:
    0.9'f32
  of MagicBolt:
    travelTime + 0.7'f32
  of MagicBurst, PortalBurst, PoisonBurst:
    1.25'f32
  of Fireball:
    travelTime + 0.8'f32
  of FireBurst:
    1.0'f32
  of ArrowWake:
    travelTime + 0.35'f32
  of PoisonCapsule:
    travelTime + 0.25'f
  of LeafBolt:
    travelTime
  of LeafBurst:
    0.6'f
  of BloomSeed, SolarOrb:
    travelTime + 0.1'f32
  of BloomPetals, RootLeaves:
    1.8'f32
  of SolarFlames:
    1.65'f32
  of HealingAura, ManaAura, PoisonAura, MendingAura:
    1.75'f32
  of BladeFlame:
    0.5'f32
  of FireWave:
    0.55'f32
  of HeatEmbers:
    1.25'f32

proc addParticleEffect(
    system: var ParticleSystem,
    kind: ParticleEffectKind,
    origin,
    target: Vec3,
    travelTime,
    delay: float32,
    anchor = 0'i32,
    owner = -1'i32
) =
  ## Adds one effect while keeping the presentation queue bounded.
  if system.effects.len >= MaximumParticleEffects:
    system.effects.delete(0)
  let startTime = system.time + max(delay, 0.0'f32)
  system.effects.add ParticleEffect(
    kind: kind,
    origin: origin,
    target: target,
    startTime: startTime,
    travelTime: max(travelTime, 0.05'f32),
    endTime: startTime + kind.effectLifetime(travelTime),
    seed: system.nextSeed,
    anchor: anchor,
    owner: owner
  )
  inc system.nextSeed

proc emitParticleBurst*(
    system: var ParticleSystem,
    kind: ParticleEffectKind,
    position: Vec3,
    delay = 0.0'f32,
    anchor = 0'i32,
    owner = -1'i32
) =
  ## Emits one burst now or after a short presentation delay. It stays
  ## where it was emitted unless it has an anchor to follow.
  system.addParticleEffect(
    kind,
    position,
    position,
    0.05'f32,
    delay,
    anchor,
    owner
  )

proc emitParticleSpan*(
    system: var ParticleSystem,
    kind: ParticleEffectKind,
    origin,
    target: Vec3,
    delay = 0.0'f32
) =
  ## Emits one effect that spreads between two points without travelling.
  system.addParticleEffect(
    kind,
    origin,
    target,
    0.05'f32,
    delay
  )

proc emitParticleFlight*(
    system: var ParticleSystem,
    kind: ParticleEffectKind,
    origin, target: Vec3,
    travelTime: float32
) =
  ## A travelling visual whose impact is emitted by the simulation event.
  system.addParticleEffect(kind, origin, target,
    max(travelTime, 0.05'f32), 0.0'f32)

proc emitParticleProjectile*(
    system: var ParticleSystem,
    projectile,
    impact: ParticleEffectKind,
    origin,
    target: Vec3,
    travelTime: float32,
    owner = -1'i32
) =
  ## Emits a travelling effect and a matching impact at its destination.
  let duration = max(travelTime, 0.05'f32)
  system.addParticleEffect(
    projectile,
    origin,
    target,
    duration,
    0.0'f32,
    owner = owner
  )
  system.emitParticleBurst(impact, target, duration, owner = owner)

proc followParticleAnchors*(
    system: var ParticleSystem,
    place: proc(anchor: int32, position: var Vec3): bool
) =
  ## Moves every anchored effect to where `place` puts its anchor now, so
  ## it travels with whatever it was emitted on. An anchor `place` no
  ## longer finds leaves its effects where they last were.
  for effect in system.effects.mitems:
    if effect.anchor == 0:
      continue
    var position = effect.origin
    if place(effect.anchor, position):
      effect.target += position - effect.origin
      effect.origin = position

proc advanceParticles*(system: var ParticleSystem, delta: float32) =
  ## Advances presentation time and removes every finished effect.
  system.time += max(delta, 0.0'f32)
  var index = system.effects.high
  while index >= 0:
    if system.effects[index].endTime <= system.time:
      system.effects.delete(index)
    dec index

proc clearParticles*(system: var ParticleSystem) =
  ## Removes all active effects without rewinding presentation time.
  system.effects.setLen(0)

proc uploadParticleEffect(
    system: ParticleSystem,
    effect: ParticleEffect,
    viewProjection: var Mat4,
    cameraRight,
    cameraUp,
    cameraForward: Vec3
) =
  ## Uploads one effect and the current camera basis to the shader.
  template location(uniform: ParticleUniform): GLint =
    system.program.locations[uniform]
  glUniformMatrix4fv(
    location(ViewProjectionUniform),
    1,
    GL_FALSE,
    cast[ptr float32](viewProjection.addr)
  )
  glUniform3f(
    location(CameraRightUniform),
    cameraRight.x,
    cameraRight.y,
    cameraRight.z
  )
  glUniform3f(
    location(CameraUpUniform),
    cameraUp.x,
    cameraUp.y,
    cameraUp.z
  )
  glUniform3f(
    location(CameraForwardUniform),
    cameraForward.x,
    cameraForward.y,
    cameraForward.z
  )
  glUniform1f(location(TimeUniform), system.time)
  glUniform1f(location(StartTimeUniform), effect.startTime)
  glUniform1f(location(TravelTimeUniform), effect.travelTime)
  glUniform1f(
    location(SeedUniform),
    (effect.seed mod 65_521'u32).float32
  )
  glUniform1i(location(EffectKindUniform), effect.kind.ord.GLint)
  glUniform3f(
    location(OriginUniform),
    effect.origin.x,
    effect.origin.y,
    effect.origin.z
  )
  glUniform3f(
    location(TargetUniform),
    effect.target.x,
    effect.target.y,
    effect.target.z
  )

proc particlePathVisible*(
    origin, target: Vec3,
    visibility: openArray[uint8],
    width: int,
    mapOrigin: Vec2,
    padding = 0
): bool =
  ## Hides an effect if any part of its travel path enters unseen tiles.
  if visibility.len == 0:
    return true
  if width <= 0 or visibility.len != width * width:
    return false
  let
    delta = target - origin
    steps = max(1, int(ceil(max(abs(delta.x), abs(delta.z)) * 2)))
  for i in 0 .. steps:
    let
      point = origin + delta * (i.float32 / steps.float32)
      x = int(floor(point.x - mapOrigin.x))
      z = int(floor(point.z - mapOrigin.y))
    if x < 0 or z < 0 or x >= width or z >= width or
      visibility[z * width + x] == 0:
        return false
    if padding > 0:
      for row in z-padding .. z+padding:
        for col in x-padding .. x+padding:
          if col < 0 or row < 0 or col >= width or row >= width or
              visibility[row * width + col] == 0: return false
  true

proc drawParticles*(
    system: ParticleSystem,
    viewProjection: Mat4,
    cameraRight,
    cameraUp,
    cameraForward: Vec3,
    visibility: openArray[uint8] = [],
    visibilityWidth = 0,
    visibilityOrigin = vec2(0),
    visibilityPadding = 0,
    viewer = -1'i32
) =
  ## Draws every visible active effect with instanced, depth-tested billboards.
  if system.program.id == 0 or system.effects.len == 0:
    return
  var matrix = viewProjection
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glEnable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glUseProgram(system.program.id)
  glBindVertexArray(system.vertexArray)
  for effect in system.effects:
    if effect.startTime > system.time:
      continue
    if viewer < 0 or effect.owner != viewer:
      if not particlePathVisible(
        effect.origin,
        effect.target,
        visibility,
        visibilityWidth,
        visibilityOrigin,
        visibilityPadding
      ):
        continue
    if effect.kind in
        {ArrowWake, LeafBolt, LeafBurst, BloomSeed, BloomPetals, RootLeaves}:
      glBlendFuncSeparate(
        GL_SRC_ALPHA,
        GL_ONE_MINUS_SRC_ALPHA,
        GL_ONE,
        GL_ONE_MINUS_SRC_ALPHA
      )
    else:
      glBlendFuncSeparate(
        GL_SRC_ALPHA,
        GL_ONE,
        GL_ZERO,
        GL_ONE
      )
    system.uploadParticleEffect(
      effect,
      matrix,
      cameraRight,
      cameraUp,
      cameraForward
    )
    glDrawArraysInstanced(
      GL_TRIANGLE_STRIP,
      0,
      4,
      effect.kind.effectParticleCount.GLsizei
    )
  glBindVertexArray(0)
  glUseProgram(0)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)

proc closeParticles*(system: var ParticleSystem) =
  ## Releases particle GPU resources and clears presentation state.
  if system.program.id != 0:
    glDeleteProgram(system.program.id)
  if system.vertexArray != 0:
    glDeleteVertexArrays(1, system.vertexArray.addr)
  system = ParticleSystem()
