## Native FBO regression exercising the game's model and clip selectors.
import std/os
include ../graphics

let testWindow = newWindow("Woodcutting model regression", ivec2(800, 800), visible = false, vsync = false)
testWindow.makeContextCurrent()
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
initSunShadows()
sunShadowsEnabled = false
let scene = CharacterScene(toon: newToonContext(), shading: ToonCharacters)
scene.toon.view = lookAt(vec3(2, 2.2, 4), vec3(0, 0.65, 0), vec3(0, 1, 0))
scene.toon.proj = ortho(-1.2'f, 1.2'f, -1.2'f, 1.2'f, 0.1'f, 100'f)
scene.toon.cameraPosition = vec3(2, 2.2, 4)
setEnvironmentPalette(scene.toon)
let manifest = readManifest(ChargenLibrary)
let roster = readCharacterRoster([PeterRiver])
var cache: UnitModelCache
let ordinary = cache.loadUnitModel(manifest, roster.players[0][PeonUnit.ord], PeonUnit)
let axe = cache.loadUnitModel(manifest, roster.players[0][PeonUnit.ord], PeonUnit, woodAxe = true)
woodAxeModels = @[axe]
let unit = Unit(owner: 0, kind: PeonUnit, hp: 30, state: UnitIdle)
proc imageFor(unit: Unit, time: float32): Image =
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glViewport(0, 0, 800, 800)
  glDepthMask(GL_TRUE)
  glClearColor(0.12, 0.14, 0.16, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  let model = renderUnitModel(unit, ordinary)
  let clip = renderUnitClip(unit, model, model.clipIndex("Idle_Loop"))
  var pose: CharacterPose
  scene.prepareCharacter(pose, model, vec3(0), 0, clip, time)
  scene.drawCharacter(pose)
  result = newImage(800, 800)
  glReadPixels(0, 0, 800, 800, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()
let idle = imageFor(unit, 0)
unit.state = UnitToTree
let walk = imageFor(unit, 0)
doAssert renderUnitModel(unit, ordinary) == axe
var difference = 0
for i in 0 ..< idle.data.len:
  if idle.data[i] != walk.data[i]: inc difference
doAssert difference > 200, "axe must change real rendered pixels"
unit.state = UnitChopping
unit.stateTicks = ChopTicks
let clip = renderUnitClip(unit, axe, axe.clipIndex("Interact"))
doAssert clip == axe.clipIndex("Sword_Attack")
let first = imageFor(unit, 0)
let second = imageFor(unit, axe.clipDuration(clip) * 0.5'f)
var moved = 0
for i in 0 ..< first.data.len:
  if first.data[i] != second.data[i]: inc moved
doAssert moved > 500, "sword animation must move the actual rendered peon"
first.writeFile(getTempDir() / "lvd-wood-axe-first.png")
second.writeFile(getTempDir() / "lvd-wood-axe-swing.png")
echo "PASS equipped pixels=", difference, " swing pixels=", moved
