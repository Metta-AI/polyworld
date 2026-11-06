## Native real-asset/FBO test of production graphics baked-building submission.
## Legacy switch reproduces unconditional baked-building submission.
import std/macros
import opengl, pixie, vmath, windy
import polyworld/[assets, groves, quadterrain, shadows, toon, particles, particleshaders]
import ../[buildings, factions, rendervisibility, groves]
import trafficfixture

const Size = 256
let window = newWindow("LvD strict visibility", ivec2(Size, Size),
  visible = false, vsync = false)
window.makeContextCurrent()
loadExtensions()
var framebuffer, texture, depth: GLuint
glGenFramebuffers(1, framebuffer.addr)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, Size, Size, 0,
  GL_RGBA, GL_UNSIGNED_BYTE, nil)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
glGenRenderbuffers(1, depth.addr)
glBindRenderbuffer(GL_RENDERBUFFER, depth)
glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, Size, Size)
glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
initTerrain(treeStyle = NoTrees, rockStyle = NoRocks,
  terrainStyle = GeneratedTerrain, settings = TerrainAssets(size: 256))
initSunShadows(lightRadius = 60)
let art = loadBuildingArt(Grove(), factions = [Emerald, Emerald])
let world = trafficFixture(0, "open").world
var enemyIndex = -1
for i, b in world.buildings:
  if b.owner == 1: enemyIndex = i
doAssert enemyIndex >= 0
let isolatedBuilding = world.buildings[enemyIndex]
world.buildings = @[isolatedBuilding]
enemyIndex = 0
template building: untyped = world.buildings[enemyIndex]
let half = world.map.side.float32 / 2
# Complete the shared ambient sampler even when ambient shading is disabled.
uploadAmbientOcclusion(@[255'u8, 255, 255, 255], 1, vec2(-half), vec2(half * 2))
let center = vec3(building.origin.x.float32 + building.footprint.width.float32 / 2 - half,
  0, building.origin.y.float32 + building.footprint.depth.float32 / 2 - half)
let view = lookAt(center + vec3(6, 9, 12), center + vec3(0, 1, 0), vec3(0, 1, 0))
let projection = ortho(-5'f32, 5'f32, -5'f32, 5'f32, 0.1'f32, 100'f32)
let vp = projection * view
let toonContext = newToonContext()
setEnvironmentPalette(toonContext)
let scoutId = world.spawnUnit(0, SoldierUnit, tile2(68, 73))
let scout = world.units[world.unitIndex(scoutId)]
world.rebuildVision()
var effectPosition = center
block chooseVisibleEffectCell:
  for y in building.origin.y.int32 ..< building.origin.y.int32 + building.footprint.depth:
    for x in building.origin.x.int32 ..< building.origin.x.int32 + building.footprint.width:
      if world.visible(0, x, y):
        effectPosition = vec3(x.float32 + 0.5'f32 - half, 2, y.float32 + 0.5'f32 - half)
        break chooseVisibleEffectCell
var effects = initParticleSystem()
effects.emitParticleBurst(FireBurst, effectPosition)
effects.advanceParticles(0.2'f32)

let run = Game(world: world)
let viewMode = 1'i32
let grove = Grove()
let scenery: seq[GrovePlacement] = @[]
let buildingArt = art
proc shownBuilding(b: Building): bool = world.renderBuildingVisible(1, b)
proc buildingCentre(b: Building): Vec3 =
  vec3(b.origin.x.float32 + b.footprint.width.float32 / 2 - half, 0,
    b.origin.y.float32 + b.footprint.depth.float32 / 2 - half)
macro productionPlacement(): untyped =
  for node in parseStmt(staticRead("../graphics.nim")):
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkProcDef and child[0].repr == "placeSceneProps":
          result = child
          result[4] = newEmptyNode() # profiling pragma is not relevant here
          return
  error("Missing production placement")
productionPlacement()

proc draw(kind: int): int =
  ## 0 real building color, 1 actual shadow-map depth, 2 actual particle color.
  let hashBefore = Game(world: world).stateHash()
  uploadTerrainVisibility(world.renderVisibilityValues(1, TerrainMemoryMask), world.map.side.int)
  placeSceneProps()
  bakeProps()
  if kind == 1:
    beginSunDepthPass(0)
    drawTerrainSunDepth(vertexCount = 0)
    var pixels = newSeq[float32](SunShadowMapSize * SunShadowMapSize)
    glReadPixels(0, 0, SunShadowMapSize, SunShadowMapSize,
      GL_DEPTH_COMPONENT, cGL_FLOAT, pixels[0].addr)
    for pixel in pixels:
      if pixel < 0.99999'f32: inc result
    endSunDepthPass(ivec2(Size, Size))
  else:
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
    glViewport(0, 0, Size, Size)
    glDepthMask(GL_TRUE)
    glClearColor(0, 0, 0, 1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    if kind == 0:
      drawTerrain(vp, drawGround = false)
    if kind == 2:
      let forward = normalize(center - (center + vec3(6, 9, 12)))
      let right = normalize(cross(forward, vec3(0, 1, 0)))
      let up = normalize(cross(right, forward))
      when defined(legacyRenderVisibility):
        effects.drawParticles(vp, right, up, forward)
      else:
        effects.drawParticles(vp, right, up, forward,
          world.renderVisibilityValues(1, CurrentSightMask), world.map.side.int, vec2(-half))
    var pixels = newSeq[uint8](Size * Size * 4)
    glReadPixels(0, 0, Size, Size, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)
    for i in 0 ..< Size * Size:
      if pixels[i*4] != 0 or pixels[i*4+1] != 0 or pixels[i*4+2] != 0: inc result
  doAssert glGetError() == GL_NO_ERROR
  doAssert Game(world: world).stateHash() == hashBefore

world.rebuildVision()
doAssert world.renderBuildingVisible(1, building)
var initial: array[3, int]
for kind in 0 .. 2:
  initial[kind] = draw(kind)
  echo "visible kind=", kind, " pixels=", initial[kind]
  doAssert initial[kind] > 10
world.place(scout, tile2(20, 20))
world.rebuildVision()
doAssert not world.renderBuildingVisible(1, building)
doAssert world.explored(0, building.origin.x.int32, building.origin.y.int32)
for kind in 0 .. 2:
  let count = draw(kind)
  echo "explored hidden kind=", kind, " pixels=", count
  doAssert count == 0, "Hidden building/shadow/effect must submit no pixels"
world.place(scout, tile2(68, 73))
world.rebuildVision()
for kind in 0 .. 2:
  let count = draw(kind)
  echo "restored kind=", kind, " pixels=", count
  doAssert count == initial[kind]
effects.closeParticles()
window.close()
echo "Native real building, shadow depth and persistent effect visibility transitions passed (production placement + baked GPU passes)"
