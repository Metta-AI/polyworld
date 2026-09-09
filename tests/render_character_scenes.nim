## Run under a real OpenGL context (xvfb + Mesa works). No art pack required.
import std/[os, sets]
import chroma, gltf, opengl, pixie, vmath, windy
import polyworld/[characters, shadows, toon, animblend, picking, frustums]
import std/options

const Size = 256
let window = newWindow("Model rendering proof", ivec2(Size), vsync = false)
window.makeContextCurrent()
loadExtensions()
let renderer = newRenderer(window)
let scene = CharacterScene(renderer: renderer,
  context: newPbrContext(renderer), toon: newToonContext())
let view = lookAt(vec3(0, 0, 20), vec3(0), vec3(0, 1, 0))
let projection = ortho(-1'f32, 8'f32, -1'f32, 9'f32, 0.1'f32, 40'f32)
let staticModel = loadStaticSceneModel("tests/data/composed_static_scene.glb")
let character = CharacterModel(
  file: readGltfFile("tests/data/animated_hand_socket.gltf"),
  baseTransform: translate(vec3(-10, -20, -30)))
let gear = scene.attachGear(character, "tests/data/socket_gear.gltf", RightHandSlot)
# Enlarge the tiny fixture mesh, retaining its independently authored offset.
gear.file.root.nodes[0].scale = vec3(8)
# A diffuse fixture needs no external environment map to be visible in PBR.
gear.file.root.nodes[0].mesh.primitives[0].material.metallicFactor = 0
createDir("tmp/model-render-proof")

proc beginImage(shading: CharacterShading) =
  scene.shading = shading
  scene.sunDepthPass = false
  scene.beginCharacters(window, view, projection, vec3(0, 0, 20))
  renderer.clearScreen(color(0, 0, 0, 1))

proc capture(label: string, visible = true): Vec2 =
  glFinish()
  doAssert glGetError() == GL_NO_ERROR, label & " GL error"
  let image = renderer.captureScreenshot()
  var count = 0
  for y in 0 ..< Size:
    for x in 0 ..< Size:
      let pixel = image[x, y]
      if max(pixel.r, max(pixel.g, pixel.b)) > 8:
        inc count
        result += vec2(x.float32, y.float32)
  image.writeFile("tmp/model-render-proof/" & label & ".png")
  if visible:
    doAssert count > 20, label & " must render visible geometry"
    result /= count.float32
  else:
    doAssert count == 0, label & " must not render hidden gear"
  echo label, ": ", count, " visible pixels, center ", result

let root = character.file.root
let arm = root.nodes[0]
let socket = arm.nodes[0]

sunShadowsEnabled = false
for shading in CharacterShading:
  beginImage(shading)
  scene.toon.unlitNodes.incl "stale-character-node"
  scene.drawStaticSceneModel(staticModel, vec3(0))
  if shading == ToonCharacters:
    doAssert scene.toon.unlitNodes.len == 0
  discard capture($shading & "-static")
  beginImage(shading)
  scene.drawCharacter(character, vec3(0), 0, 0, 0, [gear])
  let start = capture($shading & "-gear-start")
  beginImage(shading)
  scene.drawCharacter(character, vec3(0), 0, 0, 1, [gear])
  let finish = capture($shading & "-gear-finish")
  # The authored hand moves +3 X and +4 Y over one second.
  doAssert abs((finish.x - start.x) - Size.float32 * 3 / 9) < 2
  doAssert abs((finish.y - start.y) + Size.float32 * 4 / 10) < 2

  for hidden in [root, arm, socket]:
    hidden.baseVisible = false
    beginImage(shading)
    scene.drawCharacter(character, vec3(0), 0, 0, 1, [gear])
    discard capture($shading & "-hidden-" & hidden.name, visible = false)
    hidden.baseVisible = true
  beginImage(shading)
  scene.drawCharacter(character, vec3(0), 0, 0, 1, [gear])
  discard capture($shading & "-gear-restored")

block:
  # Exercise the other audited PRs through the rendered scene on this temporary
  # integration branch. The engine PRs keep their independent focused fixtures.
  let root = staticModel.file.root
  let target = root.nodes[0]
  root.animations = @[AnimationClip(name: "slide", duration: 1,
    channels: @[AnimationChannel(target: target, path: AnimTranslation,
      interpolation: aiLinear, times: @[0'f32, 1'f32],
      valuesVec3: @[target.pos, target.pos + vec3(2, 0, 0)])])]
  let player = newClipPlayer(root)
  player.play(0, fade = 0)
  player.timeScale = 0.5
  player.update(0.5)
  beginImage(ToonCharacters)
  scene.drawStaticSceneModel(staticModel, vec3(0))
  let beforePause = capture("animation-quarter")
  player.paused = true
  target.pos = vec3(100)
  player.update(10)
  beginImage(ToonCharacters)
  scene.drawStaticSceneModel(staticModel, vec3(0))
  let paused = capture("animation-paused")
  doAssert length(beforePause - paused) < 0.01
  player.paused = false
  player.update(0.5)
  beginImage(ToonCharacters)
  scene.drawStaticSceneModel(staticModel, vec3(0))
  let resumed = capture("animation-resumed")
  doAssert abs(resumed.x - paused.x - Size.float32 * 0.5 / 9) < 2
  player.paused = true
  player.seek(0.25)
  beginImage(ToonCharacters)
  scene.drawStaticSceneModel(staticModel, vec3(0))
  let seeked = capture("animation-seeked")
  doAssert length(seeked - beforePause) < 0.01
  player.paused = false
  player.play(-1, fade = 1)
  player.update(0.25)
  beginImage(ToonCharacters)
  scene.drawStaticSceneModel(staticModel, vec3(0))
  let fading = capture("animation-fading-to-bind")
  player.play(0, fade = 1)
  player.update(0)
  beginImage(ToonCharacters)
  scene.drawStaticSceneModel(staticModel, vec3(0))
  let interrupted = capture("animation-interrupted")
  doAssert length(interrupted - fading) < 0.01
  player.update(2)
  doAssert not player.fading
  let bounds = root.getAABounds()
  doAssert boundsVisible(bounds.min, bounds.max, projection * view)
  doAssert not boundsVisible(bounds.min, bounds.max,
    projection * view * translate(vec3(100, 0, 0)))
  for node in root.walkNodes:
    if node.mesh != nil:
      let points = node.mesh.primitives[0].points
      let center = node.mat * ((points[0] + points[1] + points[2]) / 3)
      doAssert pickRay(center + vec3(0, 0, 10), vec3(0, 0, -1)).pickMesh(root, true).isSome
      break

sunShadowsEnabled = true
initSunShadows(10, 20)
sunLightMvp0 = projection * view
scene.sunDepthPass = true
for attached in [false, true]:
  beginSunDepthPass(0)
  glViewport(0, 0, Size, Size)
  if attached:
    scene.drawCharacter(character, vec3(0), 0, 0, 1, [gear])
  else:
    scene.drawStaticSceneModel(staticModel, vec3(0))
  when not defined(emscripten):
    var depth = newSeq[float32](Size * Size)
    glReadPixels(0, 0, Size, Size, GL_DEPTH_COMPONENT, cGL_FLOAT, depth[0].addr)
    doAssert glGetError() == GL_NO_ERROR
    var covered = 0
    for value in depth:
      if value < 1: inc covered
    doAssert covered > 20, "model must write shadow depth"
    echo "Shadow attached=", attached, ": ", covered, " covered pixels"
  else:
    doAssert glGetError() == GL_NO_ERROR
for hidden in [root, arm, socket]:
  hidden.baseVisible = false
  beginSunDepthPass(0)
  glViewport(0, 0, Size, Size)
  scene.drawCharacter(character, vec3(0), 0, 0, 1, [gear])
  when not defined(emscripten):
    var depth = newSeq[float32](Size * Size)
    glReadPixels(0, 0, Size, Size, GL_DEPTH_COMPONENT, cGL_FLOAT, depth[0].addr)
    doAssert glGetError() == GL_NO_ERROR
    for value in depth:
      doAssert value == 1, "hidden gear must not write shadow depth"
  else:
    doAssert glGetError() == GL_NO_ERROR
  hidden.baseVisible = true
endSunDepthPass(window.size)
echo "Model GPU proof passed"

when defined(emscripten):
  proc runScript(script: cstring) {.importc: "emscripten_run_script", header: "<emscripten.h>".}
  runScript("""
    const names = ['PbrCharacters-static', 'PbrCharacters-gear-start',
      'PbrCharacters-gear-finish', 'ToonCharacters-static',
      'ToonCharacters-gear-start', 'ToonCharacters-gear-finish',
      'animation-quarter', 'animation-paused', 'animation-resumed',
      'animation-seeked', 'animation-fading-to-bind', 'animation-interrupted',
      'PbrCharacters-gear-restored', 'ToonCharacters-gear-restored'];
    const gallery = document.createElement('div');
    gallery.style = 'display:grid;grid-template-columns:repeat(3,256px);gap:12px;background:white;color:black;padding:12px';
    for (const name of names) {
      const figure = document.createElement('figure');
      figure.style.margin = '0';
      const caption = document.createElement('figcaption');
      caption.textContent = name;
      const img = document.createElement('img');
      img.src = URL.createObjectURL(new Blob([FS.readFile('tmp/model-render-proof/' + name + '.png')], {type:'image/png'}));
      figure.append(caption, img);
      gallery.append(figure);
    }
    document.body.prepend(gallery);
    window.__modelProof = {passed: true, captures: names.length};
  """)
