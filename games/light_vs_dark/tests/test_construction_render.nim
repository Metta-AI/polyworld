## Native asset/GL evidence: real queued farm and barracks, both build stages.
## Writes PNGs to TMPDIR, not the repository. No graphics.nim integration needed.
import std/os
import opengl, pixie, vmath, windy
import polyworld/[assets, characters, chargen, groves, quadterrain, shadows, toon]
import ../[appearances, assets, buildings, constructionpresentation, content,
  controls, factions, maps, sim]

let window = newWindow("LvD construction presentation", ivec2(800, 800),
  visible = false, vsync = false)
window.makeContextCurrent()
loadExtensions()
var framebuffer, texture, depth: GLuint
glGenFramebuffers(1, framebuffer.addr)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 800, 800, 0,
  GL_RGBA, GL_UNSIGNED_BYTE, nil)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
glGenRenderbuffers(1, depth.addr)
glBindRenderbuffer(GL_RENDERBUFFER, depth)
glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, 800, 800)
glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
initTerrain(treeStyle = NoTrees, rockStyle = NoRocks,
  terrainStyle = GeneratedTerrain, settings = TerrainAssets(size: 256))
initSunShadows()
sunShadowsEnabled = false
let art = loadBuildingArt(Grove(), factions = [Emerald])
let scene = CharacterScene(toon: newToonContext(), shading: ToonCharacters)
let roster = readCharacterRoster([Emerald])
let model = loadUnitModel(readManifest(ChargenLibrary),
  roster.players[0][PeonUnit.ord], PeonUnit)
let clip = model.clipIndex(unitClip(PeonUnit, AttackAnimation))
doAssert clip >= 0 and model.clipDuration(clip) > 0
scene.toon.view = lookAt(vec3(3, 5, 6), vec3(0, 0.3, 0), vec3(0, 1, 0))
scene.toon.proj = ortho(-1.7'f32, 1.7'f32, -1.7'f32, 1.7'f32, 0.1'f32, 100'f32)
scene.toon.cameraPosition = vec3(3, 5, 6)
setEnvironmentPalette(scene.toon)

proc draw(site: Building, pose: ConstructionPresentation, time: float32,
    withWorker: bool): Image =
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glViewport(0, 0, 800, 800)
  glDepthMask(GL_TRUE)
  glClearColor(0.13, 0.17, 0.19, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  for part in art.buildingParts(site, vec3(0)):
    part.pack.drawProp(part.name, part.position, part.rotation, part.scale,
      scene.toon.proj * scene.toon.view)
  if withWorker:
    let centre = vec2(site.origin.x.float32 + site.footprint.width.float32 / 2,
      site.origin.y.float32 + site.footprint.depth.float32 / 2)
    let offset = pose.tilePoint - centre
    var character: CharacterPose
    scene.prepareCharacter(character, model, vec3(offset.x, pose.floorLift, offset.y),
      pose.yaw, clip, time)
    scene.drawCharacter(character)
  result = newImage(800, 800)
  glReadPixels(0, 0, 800, 800, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()

for kind in [FarmBuilding, BarracksBuilding]:
  clearPlayerCommands()
  let map = generateMap(DefaultSeed)
  let game = newGame(map, TickRate * 180)
  let w = game.world
  let worker = w.units[0]
  w.players[0].gold = 10000
  w.players[0].wood = 10000
  w.place(worker, tile2(map.side div 2 - 10, map.side div 2))
  queueBuild(0, worker.id, kind.ord.int32, map.side div 2 - 4, map.side div 2)
  for _ in 0 ..< TickRate * 30:
    w.tickWorld(proc(world: World) = game.flushPlayerCommands())
    if worker.state == UnitBuilding: break
  doAssert worker.state == UnitBuilding
  let index = w.buildingIndex(worker.targetId)
  for stage in [FoundationStage, WallsStage]:
    while w.buildings[index].constructionStage() != stage:
      w.tickWorld(proc(world: World) = game.flushPlayerCommands())
    let site = w.buildings[index]
    let pose = w.constructionPresentation(worker)
    doAssert pose.active
    let before = game.stateHash()
    let empty = draw(site, pose, 0, false)
    let first = draw(site, pose, model.clipDuration(clip) * 0.35'f32, true)
    let second = draw(site, pose, model.clipDuration(clip) * 0.65'f32, true)
    var visiblePixels, animatedPixels: int
    for i in 0 ..< first.data.len:
      if first.data[i] != empty.data[i]: inc visiblePixels
      if first.data[i] != second.data[i]: inc animatedPixels
    let path = getTempDir() / ("lvd-builder-" & $kind & "-" & $stage & ".png")
    first.writeFile(path)
    second.writeFile(getTempDir() / ("lvd-builder-" & $kind & "-" & $stage & "-work.png"))
    echo path, " visible=", visiblePixels, " animated=", animatedPixels
    doAssert visiblePixels > 300, "Worker must remain visible inside shell"
    doAssert animatedPixels > 100, "Existing Interact clip must visibly animate"
    doAssert game.stateHash() == before
window.close()
