## Hidden native FBO readback of real harvest transitions and strict fog.
import std/os
import opengl, pixie, vmath, windy
import polyworld/worldbars
import ../[content, maps, sim, harvestpresentation]

let window = newWindow("Harvest VFX fixture", ivec2(640, 640),
  visible = false, vsync = false)
window.makeContextCurrent()
loadExtensions()
var framebuffer, texture, depth: GLuint
glGenFramebuffers(1, framebuffer.addr)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 640, 640, 0,
  GL_RGBA, GL_UNSIGNED_BYTE, nil)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
glGenRenderbuffers(1, depth.addr)
glBindRenderbuffer(GL_RENDERBUFFER, depth)
glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, 640, 640)
glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
var renderer = initWorldBarRenderer()
let map = generateMap(DefaultSeed)
let game = newGame(map, TickRate * 180)
let w = game.world
let worker = w.units[0]
var fx: HarvestPresentation
var centre: Vec3
let half = map.side.float32 / 2
proc anchor(site: HarvestSite): Vec3 =
  vec3(site.tilePoint.x - half,
    (if site.kind == MineSparks: 0.3'f32 else: 1.1'f32),
    site.tilePoint.y - half)
proc draw(viewer: int32): Image =
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glViewport(0, 0, 640, 640)
  glClearColor(0.08, 0.10, 0.12, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  renderer.clear()
  renderer.addHarvestBillboards(fx, w, viewer, anchor)
  let view = lookAt(centre + vec3(0, 3, 4), centre, vec3(0, 1, 0))
  let projection = ortho(-1.1'f32, 1.1'f32, -1.1'f32, 1.1'f32, 0.1'f32, 50'f32)
  renderer.draw(projection * view, vec3(1, 0, 0), vec3(0, 0.8, -0.6))
  result = newImage(640, 640)
  glReadPixels(0, 0, 640, 640, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()
proc changed(a, b: Image): int =
  for i in 0 ..< a.data.len:
    if a.data[i] != b.data[i]: inc result

for kind in HarvestKind:
  fx.clearHarvest()
  var target = -1'i32
  var best = int32.high
  if kind == MineSparks:
    for mine in w.buildings:
      if mine.kind == GoldMineBuilding:
        let distance = tileDistance(worker.tile, mine.origin)
        if distance < best:
          best = distance
          target = mine.id
  else:
    for i, wood in w.treeWood:
      if wood > 0:
        let distance = tileDistance(worker.tile, tile2(i.int32 mod map.side, i.int32 div map.side))
        if distance < best:
          best = distance
          target = i.int32
  doAssert w.applyHarvest(worker.owner, worker.id, target, (if kind == ChopLeaves: 1 else: 0))
  let blank = draw(-1)
  for _ in 0 ..< TickRate * 60:
    w.tickWorld(nil)
    if worker.state in {UnitInMine, UnitChopping}: break
  doAssert worker.state in {UnitInMine, UnitChopping}
  fx.updateHarvest(w, 0.01, -1)
  doAssert fx.siteCount == 1
  centre = anchor(fx.sites[0])
  for _ in 0 ..< 2: fx.updateHarvest(w, 0.08, -1)
  let before = game.stateHash()
  let active = draw(-1)
  let pixels = changed(blank, active)
  doAssert pixels > 10, "real particle geometry must reach GPU"
  var warm, green: int
  for p in active.data:
    if p.r > p.g and p.g > p.b and p.r > 70: inc warm
    if p.g > p.r and p.g > p.b and p.g > 70: inc green
  doAssert (if kind == MineSparks: warm > 0 else: green > 0)
  fx.updateHarvest(w, 0.1, -1, paused = true)
  doAssert changed(active, draw(-1)) == 0
  doAssert game.stateHash() == before
  active.writeFile(getEnv("LVD_HARVEST_FIXTURE", getTempDir()) / ($kind & ".png"))
  let snapshot = fx
  fx.updateHarvest(w, 0.07, -1)
  doAssert changed(active, draw(-1)) > 10, "particles must animate"
  fx = snapshot
  # The source stays visible while all particles drift to explored-only fog.
  for stamp in w.visibleStamp[0].mitems: stamp = 0
  let source = fx.sites[0].tilePoint
  w.visibleStamp[0][w.map.tileIndex(source.x.int32, source.y.int32)] = w.visionGeneration[0]
  doAssert w.pointVisible(0, source)
  for particle in fx.particles.mitems:
    if particle.active: particle.offset.x = 0.8
  doAssert changed(blank, draw(0)) == 0, "visible source must not leak drifting particles"
  # Even a quad centred on the visible side is suppressed if its edge crosses.
  for particle in fx.particles.mitems:
    if particle.active:
      particle.offset = vec3(0.499, 0, 0)
  doAssert changed(blank, draw(0)) == 0, "billboard extent must not cross fog edge"
  fx = snapshot
  # Shared worldbars depth testing must retain occlusion (not HUD-overlay VFX).
  glClearDepth(0)
  doAssert changed(blank, draw(-1)) == 0
  glClearDepth(1)
  # Full explored memory is not current sight. Hide existing particles at draw
  # time without an update, then prove update removes them even while paused.
  for stamp in w.visibleStamp[0].mitems: stamp = 0
  for seen in w.explored[0].mitems: seen = 1
  doAssert changed(blank, draw(0)) == 0
  fx.updateHarvest(w, 0.1, 0, paused = true)
  doAssert fx.particleCount == 0
  echo kind, " rendered pixels=", pixels, " warm=", warm, " green=", green,
    " hidden pixels=0 pause identical"
  if kind == MineSparks:
    for _ in 0 ..< MineTicks + 5:
      w.tickWorld(nil)
      if worker.state != UnitInMine: break
  else:
    doAssert w.applyCancel(worker.owner, worker.id)
  fx.updateHarvest(w, 0.1, -1)
  doAssert fx.particleCount == 0
  doAssert changed(blank, draw(-1)) == 0
renderer.closeWorldBarRenderer()
window.close()
