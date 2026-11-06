## Native FBO integration: production selectors, roster/cache, real harvest lifecycle.
## Run from repo root with a private --nimcache and TMPDIR in Hermes scratch.
include ../graphics

let fixtureWindow = newWindow("LvD woodcutting render", ivec2(800, 800),
  visible = false, vsync = false)
fixtureWindow.makeContextCurrent()
loadExtensions()
var fixtureFb, fixtureTexture, fixtureDepth: GLuint
glGenFramebuffers(1, fixtureFb.addr)
glBindFramebuffer(GL_FRAMEBUFFER, fixtureFb)
glGenTextures(1, fixtureTexture.addr)
glBindTexture(GL_TEXTURE_2D, fixtureTexture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 800, 800, 0,
  GL_RGBA, GL_UNSIGNED_BYTE, nil)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fixtureTexture, 0)
glGenRenderbuffers(1, fixtureDepth.addr)
glBindRenderbuffer(GL_RENDERBUFFER, fixtureDepth)
glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, 800, 800)
glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, fixtureDepth)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
initSunShadows()
sunShadowsEnabled = false
let fixtureScene = CharacterScene(toon: newToonContext(), shading: ToonCharacters)
fixtureScene.toon.view = lookAt(vec3(3, 3, 6), vec3(0, 0.6, 0), vec3(0, 1, 0))
fixtureScene.toon.proj = ortho(-1.25'f32, 1.25'f32, -1.25'f32, 1.25'f32, 0.1'f32, 100'f32)
fixtureScene.toon.cameraPosition = vec3(3, 3, 6)
setEnvironmentPalette(fixtureScene.toon)

let fixtureManifest = readManifest(ChargenLibrary)
let fixtureRoster = readCharacterRoster([Emerald])
var fixtureCache: UnitModelCache
let fixtureEntry = fixtureRoster.players[0][PeonUnit.ord]
let ordinaryModel = fixtureCache.loadUnitModel(fixtureManifest, fixtureEntry, PeonUnit)
woodAxeModels = @[fixtureCache.loadUnitModel(
  fixtureManifest, fixtureEntry, PeonUnit, woodAxe = true)]
resourceModels = newSeq[array[ResourcePack, array[bool, CharacterModel]]](1)
for pack in WoodPack .. GoldPack:
  for axe in false .. true:
    resourceModels[0][pack][axe] = fixtureCache.loadBackpackModel(
      fixtureManifest, fixtureEntry, pack, woodAxe = axe)

proc renderFixture(unit: Unit, slot: AnimationSlot, fallbackTime: float32): Image =
  let model = renderUnitModel(unit, ordinaryModel)
  let ordinaryClip = ordinaryModel.clipIndex(unitClip(PeonUnit, slot))
  let clip = renderUnitClip(unit, model, ordinaryClip)
  doAssert clip >= 0 and model.clipDuration(clip) > 0
  glBindFramebuffer(GL_FRAMEBUFFER, fixtureFb)
  glViewport(0, 0, 800, 800)
  glDepthMask(GL_TRUE)
  glClearColor(0.13, 0.17, 0.19, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  var pose: CharacterPose
  fixtureScene.prepareCharacter(pose, model, vec3(0), 0, clip,
    unit.woodAnimationTime(fallbackTime, 0))
  fixtureScene.drawCharacter(pose)
  result = newImage(800, 800)
  glReadPixels(0, 0, 800, 800, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()
  doAssert glGetError() == GL_NO_ERROR

proc differences(a, b: Image): int =
  for i in 0 ..< a.data.len:
    if a.data[i] != b.data[i]: inc result

let fixtureGame = newGame(generateMap(DefaultSeed), TickRate * 180)
let fixtureWorld = fixtureGame.world
let worker = fixtureWorld.units[0]
var tree = -1'i32
var distance = int32.high
for i, wood in fixtureWorld.treeWood:
  if wood > 0:
    let d = tileDistance(worker.tile,
      tile2(i.int32 mod fixtureWorld.map.side, i.int32 div fixtureWorld.map.side))
    if d < distance:
      tree = i.int32
      distance = d
doAssert tree >= 0
let initialHash = fixtureGame.stateHash()
doAssert renderUnitModel(worker, ordinaryModel) == ordinaryModel
let idle = renderFixture(worker, IdleAnimation, 0.2)
doAssert fixtureGame.stateHash() == initialHash
idle.writeFile(getTempDir() / "lvd-wood-idle.png")
doAssert fixtureWorld.applyHarvest(worker.owner, worker.id, tree, 1)
doAssert worker.state == UnitToTree
let armed = renderUnitModel(worker, ordinaryModel)
doAssert armed == woodAxeModels[0] and armed != ordinaryModel
doAssert renderUnitClip(worker, armed, ordinaryModel.clipIndex("Idle_Loop")) == ordinaryModel.clipIndex("Idle_Loop")
let axe = renderFixture(worker, IdleAnimation, 0.2)
axe.writeFile(getTempDir() / "lvd-wood-axe.png")
let axePixels = differences(idle, axe)
doAssert axePixels > 100, "equipped axe must produce visibly different pixels"
for _ in 0 ..< TickRate * 60:
  fixtureWorld.tickWorld(nil)
  if worker.state == UnitChopping: break
doAssert worker.state == UnitChopping
let chopModel = renderUnitModel(worker, ordinaryModel)
let interact = ordinaryModel.clipIndex("Interact")
let chopClip = renderUnitClip(worker, chopModel, interact)
doAssert chopClip == chopModel.clipIndex("Sword_Attack") and chopClip != interact
let chopHash = fixtureGame.stateHash()
let chop0 = renderFixture(worker, AttackAnimation, 99)
doAssert fixtureGame.stateHash() == chopHash
chop0.writeFile(getTempDir() / "lvd-wood-chop-start.png")
for _ in 0 ..< 5: fixtureWorld.tickWorld(nil)
doAssert worker.state == UnitChopping
let chop1 = renderFixture(worker, AttackAnimation, 99)
chop1.writeFile(getTempDir() / "lvd-wood-chop-next.png")
let animPixels = differences(chop0, chop1)
doAssert animPixels > 100, "actual chopping ticks must change rendered pose"
for _ in 0 ..< TickRate * 60:
  fixtureWorld.tickWorld(nil)
  if worker.state in {UnitToDropWood, UnitDepositWood}: break
doAssert worker.state in {UnitToDropWood, UnitDepositWood}
doAssert worker.carryWood > 0
doAssert renderUnitModel(worker, ordinaryModel) == resourceModels[0][WoodPack][true]
let carrying = renderFixture(worker, RunAnimation, 0.2)
carrying.writeFile(getTempDir() / "lvd-wood-carry.png")
doAssert fixtureWorld.applyCancel(worker.owner, worker.id)
doAssert not worker.woodAxeVisible
doAssert renderUnitModel(worker, ordinaryModel) == resourceModels[0][WoodPack][false]
let stopped = renderFixture(worker, IdleAnimation, 0.2)
stopped.writeFile(getTempDir() / "lvd-wood-stopped.png")
let stopPixels = differences(carrying, stopped)
doAssert stopPixels > 100
fixtureWindow.close()
echo "PASS native FBO: axe pixels=", axePixels, " chopping pixels=", animPixels,
  " stopped pixels=", stopPixels, " screenshots=", getTempDir()
