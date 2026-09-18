## A modular character viewer backed by editable Blender assets.
## Run with `nim r experiments/blender_chars/blender_chars.nim`.
## Rebuild assets with Blender's background Python runner and build_model.py.
## Add meshes, outfits, colors, and clips through assets/manifest.json.

import
  std/[os, random, sets, strformat, strutils, tables, times],
  bumpy, chroma, gltf, silky, vmath,
  polyworld/[animblend, toon], brows, eyes, hairs, parts, references, weights

when defined(takeScreenshot):
  import pixie

const
  ExperimentDir = currentSourcePath().parentDir
  AssetDir = ExperimentDir / "assets"
  ThemeDir = ExperimentDir.parentDir.parentDir.parentDir /
    "polyworld_data/themes/main"
  TempDir = ExperimentDir.parentDir.parentDir / "tmp/blender_chars"
  AtlasPath = TempDir / "viewer.atlas.png"
  RowWidth = 320

type
  Shading = enum
    Clay, Toon, Weights

proc cycle(current, step, count: int): int =
  ## Cycles through None and the available choices in either direction.
  let length = count + 1
  ((current + 1 + step) mod length + length) mod length - 1

proc envNumber(name: string, fallback: float32): float32 =
  ## Reads a numeric launch option with an experiment-specific error.
  if not existsEnv(name):
    return fallback
  try:
    result = getEnv(name).parseFloat.float32
  except ValueError:
    raise newException(BlenderCharsError, "Invalid number for " & name)

proc envInteger(name: string, fallback: int): int =
  ## Reads an integer launch option with an experiment-specific error.
  if not existsEnv(name):
    return fallback
  try:
    result = getEnv(name).parseInt
  except ValueError:
    raise newException(BlenderCharsError, "Invalid integer for " & name)

proc run() =
  ## Opens the modular Blender character and its animation controls.
  let
    manifest = readManifest(AssetDir)
    builder = newAtlasBuilder(1024, 4)
  createDir(TempDir)
  builder.addDir(ThemeDir & "/", ThemeDir & "/")
  builder.addFont(ThemeDir / "IBMPlexSans-Regular.ttf", "H1", 28.0)
  builder.addFont(ThemeDir / "IBMPlexSans-Regular.ttf", "Default", 18.0)
  builder.write(AtlasPath)

  let window = newWindow(
    "Blender Characters",
    ivec2(1400, 900),
    vsync = true,
    msaa = msaa4x
  )
  makeContextCurrent(window)
  loadExtensions()
  let
    sk = newSilky(window, AtlasPath)
    renderer = newRenderer(window)
    pbr = newPbrContext(renderer)
    toon = newToonContext()
    model = readGltfFile(AssetDir / manifest.model)
    nodes = partNodes(model.root)
    hairMaterials = initHairMaterials(nodes, manifest)
    browMaterials = initBrowMaterials(model.root)
    player = newClipPlayer(model.root)
  pbr.attachEnvironmentMap(loadDefaultEnvironmentMap())
  var
    eyeTextures = readEyeTextures(model.root, AssetDir)
    pupil = pupilColor(getEnv("PUPIL", "Gray"))
    pupilTint = PupilColors[pupil].rgb
    customPupil = false
    hair = hairColor(getEnv("HAIR_COLOR", "Chestnut"))
    hairTint = HairColors[hair].rgb
    matchBrows = getEnv("BROW_TINT", "Hair") != "White"
    weightPreview = initWeightPreview(model.root, AssetDir)
    selectedBone = weightPreview.boneIndex("LeftHand")
    showBones = false
    wireframe = true
    boneLabels = false
    restWrist = false
    focusBone = false
    compareOriginal = getEnv("COMPARE_ORIGINAL", "1") == "1"
    originalOutfit = getEnv("ORIGINAL_OUTFIT", "0") == "1"
    reference: Reference
    selection = manifest.defaultSelection()
    shading = Toon
    palette = 0
    showParts = true
    showAnimations = true
    editingOriginal = getEnv("PARTS_MODEL", "Blender") == "Original"
    unlitFace = true
    rimLight = true
    msaa = true
    rimStrength = 0.6'f
    skin = manifest.defaultSkin
    presetIndex = 0
    speed = 1.0'f
    fade = 0.20'f
    yaw = 0.22'f
    pitch = 0.08'f
    distance = 5.8'f
    target = vec3(0, 1.52, 0)
    eye = vec3(0, 0, 0)
    rotating = false
    panning = false
    rng = initRand(19)
    lastFrameTime = epochTime()

  for clip in manifest.clips:
    if player.clipIndex(clip.name) < 0:
      raise newException(BlenderCharsError, "Missing animation: " & clip.name)
    player.setRule(clip.name, ClipRule(loop: clip.loop, next: clip.next))

  proc playClip(name: string, duration: float32) =
    ## Plays a named clip or the bind pose and resumes the transport.
    if name.len > 0 and player.clipIndex(name) < 0:
      raise newException(BlenderCharsError, "Unknown animation: " & name)
    player.play(name, duration)
    if reference != nil:
      reference.player.play(name, duration)
    player.paused = false

  proc prepareComparison() =
    ## Loads the original once and frames both independently skinned models.
    if reference == nil:
      reference = readReference(manifest.clips)
      reference.setOutfit(originalOutfit)
      reference.sync(player)
    yaw = 0
    pitch = 0.04
    distance = 7.5
    target = vec3(0, 1.52, 0)
    focusBone = false

  proc applyParts() =
    ## Applies the current independent face and ear choices.
    nodes.applySelection(manifest, selection)

  proc applySkin() =
    ## Recolors the body and detachable ears without tinting face materials.
    nodes.applySkin(manifest, skin)

  proc loadPreset(index: int) =
    ## Loads an outfit and its suggested animation.
    presetIndex = index
    let preset = manifest.presets[index]
    manifest.applyPreset(selection, preset)
    skin = clamp(preset.skin, 0, max(0, manifest.skins.high))
    applyParts()
    playClip(preset.pose, fade)

  proc randomize() =
    ## Rolls parts while retaining a body and face when available.
    if manifest.skins.len > 0:
      skin = rng.rand(manifest.skins.high)
    for i, category in manifest.categories:
      if category.items.len == 0:
        selection[i] = -1
      elif category.key in ["Body", "Face", "Eyes", "Mouth"]:
        selection[i] = rng.rand(category.items.high)
      else:
        selection[i] = rng.rand(category.items.len) - 1
    applyParts()

  if existsEnv("PRESET"):
    let index = envInteger("PRESET", 1) - 1
    if index < 0 or index >= manifest.presets.len:
      raise newException(
        BlenderCharsError, "PRESET is outside the outfit list."
      )
    loadPreset(index)
  if existsEnv("RANDOM_SEED"):
    rng = initRand(envInteger("RANDOM_SEED", 19))
    randomize()
  for category in manifest.categories:
    let setting = category.key.toUpperAscii().replace(" ", "_")
    if existsEnv(setting):
      manifest.selectPart(selection, category.key, getEnv(setting))
  applyParts()
  if existsEnv("ANIM") or player.current < 0:
    playClip(getEnv("ANIM", "Walk"), 0)
  if compareOriginal or editingOriginal:
    compareOriginal = true
    prepareComparison()
  yaw = envNumber("CAM_YAW", yaw)
  pitch = clamp(envNumber("CAM_PITCH", pitch), -1.2, 1.4)
  distance = clamp(envNumber("CAM_DIST", distance), 2, 12)
  if existsEnv("TOON"):
    shading = Toon
  if getEnv("SHADING") == "Normal":
    shading = Clay
  palette = envInteger("TOON", 0)
  if palette < 0 or palette >= ToonPalettes.len:
    raise newException(BlenderCharsError, "TOON is outside the palette list.")
  toon.setPalette(ToonPalettes[palette])
  rimLight = getEnv("RIM", "1") != "0"
  unlitFace = getEnv("UNLIT", "1") != "0"
  msaa = getEnv("MSAA", "1") != "0"
  if existsEnv("POSE_TIME"):
    player.seek(envNumber("POSE_TIME", 0))
    player.paused = true
  if existsEnv("WEIGHTS"):
    shading = Weights
    showBones = true
    selectedBone = weightPreview.boneIndex(getEnv("WEIGHTS", "LeftHand"))
    if selectedBone < 0:
      raise newException(BlenderCharsError, "Unknown WEIGHTS bone.")
  showBones = getEnv("BONES", if showBones: "1" else: "0") != "0"
  focusBone = getEnv("FOCUS_BONE", "0") != "0"
  if focusBone:
    distance = envNumber("CAM_DIST", 1.6)
  restWrist = getEnv("REST_WRIST", "0") != "0"
  wireframe = getEnv("WIREFRAME", "1") != "0"
  if reference != nil:
    reference.sync(player)

  proc mouseOverUi(): bool =
    ## Prevents camera gestures from starting over either controls panel.
    for state in subWindowStates.values:
      if state.visible and sk.mousePos.overlaps(rect(state.pos, state.size)):
        return true

  proc updateCamera() =
    ## Orbits, pans, and zooms the model with mouse gestures.
    let overUi = mouseOverUi()
    if window.buttonPressed[MouseLeft] and not overUi:
      if window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]:
        panning = true
      else:
        rotating = true
    if window.buttonPressed[MouseRight] and not overUi:
      panning = true
    if not window.buttonDown[MouseLeft] and not window.buttonDown[MouseRight]:
      rotating = false
      panning = false
    let delta = window.mouseDelta.vec2
    if rotating:
      yaw -= delta.x * 0.01
      pitch = clamp(pitch + delta.y * 0.01, -1.2, 1.4)
    if panning:
      focusBone = false
      let
        right = vec3(cos(yaw), 0, -sin(yaw))
        scale = distance * 0.0012
      target -= right * delta.x * scale
      target.y += delta.y * scale
    if not overUi and window.scrollDelta.y != 0:
      distance = clamp(distance * pow(0.92'f, window.scrollDelta.y), 0.6, 12)

  proc cameraView(): Mat4 =
    ## Builds a view matrix around the character's center.
    eye = target + vec3(
      sin(yaw) * cos(pitch),
      sin(pitch),
      cos(yaw) * cos(pitch)
    ) * distance
    lookAt(eye, target, vec3(0, 1, 0))

  proc pupilControls() =
    ## Changes iris color while preserving the white and black eye artwork.
    group "pupil color":
      box RowWidth, 36
      layout LeftToRight
      itemSpacing 5
      button "<":
        pupil = (pupil + PupilColors.len - 1) mod PupilColors.len
        pupilTint = PupilColors[pupil].rgb
      button ">":
        pupil = (pupil + 1) mod PupilColors.len
        pupilTint = PupilColors[pupil].rgb
      text "Pupil: " &
        (if pupilTint == PupilColors[pupil].rgb: PupilColors[pupil].name
         else: "Custom")
    checkBox("Custom pupil color", customPupil)
    if customPupil:
      for i, channel in ["Red", "Green", "Blue"]:
        scrubber(channel, pupilTint[i], 0.0'f, 1.0'f, "")

  proc partPicker(category: Category, selected: var int): bool =
    ## Draws the same style and color controls for either model's parts.
    group "part " & category.key:
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      button "<":
        selected = cycle(selected, -1, category.items.len)
        result = true
      button ">":
        selected = cycle(selected, 1, category.items.len)
        result = true
      var colors: HashSet[string]
      for item in category.items:
        colors.incl item.color
      if colors.len > 1:
        button "Color":
          category.cycleColor(selected)
          result = true
      text category.key & ": " &
        (if selected < 0: "None" else: category.items[selected].name)

  proc hairControls() =
    ## Offers natural and vivid presets plus independent RGB hair sliders.
    group "hair color":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 5
      button "<":
        hair = (hair + HairColors.len - 1) mod HairColors.len
        hairTint = HairColors[hair].rgb
      button ">":
        hair = (hair + 1) mod HairColors.len
        hairTint = HairColors[hair].rgb
      text "Color: " &
        (if hairTint == HairColors[hair].rgb: HairColors[hair].name
         else: "Custom")
    for i, channel in ["Red", "Green", "Blue"]:
      scrubber(
        "Hair " & channel,
        hairTint[i],
        0.0'f,
        1.0'f,
        channel
      )

  proc selectedPreset(index: int) =
    ## Applies the active model's preset and the shared animation.
    if editingOriginal:
      reference.loadPreset(index)
      playClip(reference.manifest.presets[index].pose, fade)
    else:
      loadPreset(index)

  proc partsPanel() =
    ## Keeps the complete part browser available during side-by-side playback.
    subWindow("Character", showParts, vec2(10, 10), vec2(360, 880)):
      let wasOriginal = editingOriginal
      group "model parts":
        box RowWidth, 34
        layout LeftToRight
        radioButton("Blender", editingOriginal, false)
        radioButton("Original", editingOriginal, true)
      if editingOriginal and not wasOriginal and not compareOriginal:
        compareOriginal = true
        prepareComparison()
      let source = if editingOriginal: reference.manifest else: manifest
      if source.presets.len > 0:
        let choice = if editingOriginal: reference.preset else: presetIndex
        group "preset":
          box RowWidth, 34
          layout LeftToRight
          itemSpacing 4
          button "<":
            selectedPreset((choice + source.presets.len - 1) mod
              source.presets.len)
          button ">":
            selectedPreset((choice + 1) mod source.presets.len)
          text source.presets[choice].name
          button "Random":
            if editingOriginal:
              reference.randomize(rng)
            else:
              randomize()
          button "Clear":
            if editingOriginal:
              reference.clearParts()
            else:
              selection = manifest.defaultSelection()
              for i, category in manifest.categories:
                if category.key notin ["Body", "Face"]:
                  selection[i] = -1
              applyParts()
      if source.skins.len > 0:
        var choice = if editingOriginal: reference.skin else: skin
        let previous = choice
        group "skin":
          box RowWidth, 34
          layout LeftToRight
          itemSpacing 4
          button "<":
            choice = (choice + source.skins.len - 1) mod source.skins.len
          button ">":
            choice = (choice + 1) mod source.skins.len
          text "Skin: " & source.skins[choice].name
        if choice != previous:
          if editingOriginal:
            reference.skin = choice
            reference.applyParts()
          else:
            skin = choice
      for i, category in source.categories:
        if category.items.len == 0:
          continue
        var choice =
          if editingOriginal: reference.selection[i] else: selection[i]
        if partPicker(category, choice):
          if editingOriginal:
            reference.selection[i] = choice
            reference.applyParts()
          else:
            selection[i] = choice
            applyParts()
        if not editingOriginal and category.key == "Hair":
          hairControls()
        if not editingOriginal and category.key == "Brow":
          checkBox("Brows match hair color", matchBrows)
      if not editingOriginal:
        pupilControls()
        text "Clothing and props: not modeled yet."
      button "Reset parts":
        if editingOriginal:
          reference.clearParts()
        else:
          selection = manifest.defaultSelection()
          applyParts()
      text "Drag: orbit. Right drag: pan."
      text "Scroll: zoom. P: parts. A: controls."
      button "Reset camera":
        focusBone = false
        if compareOriginal:
          prepareComparison()
        else:
          yaw = 0.22
          pitch = 0.08
          distance = 5.8
          target = vec3(0, 1.52, 0)

  proc clipButtons(poses: bool) =
    ## Packs clip buttons into rows while keeping held poses in their own group.
    var
      rows: seq[seq[string]] = @[@[]]
      used = 0.0'f
    for clip in manifest.clips:
      if (clip.kind == "pose") != poses:
        continue
      let width = sk.getTextSize(sk.textStyle, clip.name).x +
        sk.theme.padding.float32 * 3
      if used + width > RowWidth.float32 and rows[^1].len > 0:
        rows.add @[]
        used = 0
      rows[^1].add clip.name
      used += width
    for i, names in rows:
      if names.len == 0:
        continue
      group "clips " & $poses & " " & $i:
        box RowWidth, 36
        layout LeftToRight
        itemSpacing 4
        for name in names:
          button name:
            playClip(name, fade)

  proc animationsPanel() =
    ## Selects clips and exposes pause, speed, blending, and scrubbing.
    subWindow(
      "Animations",
      showAnimations,
      vec2(window.size.x.float32 - 370, 10),
      vec2(360, 880)
    ):
      group "shading":
        box RowWidth, 36
        layout LeftToRight
        radioButton("Normal", shading, Clay)
        radioButton("Toon", shading, Toon)
        radioButton("Weights", shading, Weights)
      checkBox("MSAA 4x", msaa)
      if shading == Toon:
        group "palette":
          box RowWidth, 36
          layout LeftToRight
          button "<":
            palette = (palette + ToonPalettes.len - 1) mod ToonPalettes.len
            toon.setPalette(ToonPalettes[palette])
          button ">":
            palette = (palette + 1) mod ToonPalettes.len
            toon.setPalette(ToonPalettes[palette])
          text ToonPalettes[palette].name
        checkBox("Unlit mouth and brows", unlitFace)
        text "Eyes always keep their texture colors."
        checkBox("Rim light", rimLight)
        if rimLight:
          text &"Rim strength: {rimStrength:.2f}"
          scrubber("rim", rimStrength, 0.0'f, 1.0'f, "")

      let previousComparison = compareOriginal
      checkBox("Side by side with original", compareOriginal)
      if compareOriginal and not previousComparison:
        prepareComparison()
      elif not compareOriginal and previousComparison:
        editingOriginal = false
        target = vec3(0, 1.52, 0)
        distance = 5.8
      text "Parts: P. Controls: A."
      group "playback":
        box RowWidth, 36
        layout LeftToRight
        itemSpacing 5
        button(if player.paused: "Resume" else: "Pause"):
          player.paused = not player.paused
        button "Restart":
          player.restart()
          if reference != nil:
            reference.player.restart()
        button "Bind pose":
          playClip("", fade)
      if player.current >= 0:
        let clip = model.root.animations[player.current]
        text "Playing: " & clip.name
        var position = min(player.currentTime, clip.duration)
        for spec in manifest.clips:
          if spec.name == clip.name and spec.loop and clip.duration > 0:
            position = player.currentTime -
              floor(player.currentTime / clip.duration) * clip.duration
        let previous = position
        text &"Time: {position:.2f} / {clip.duration:.2f}s"
        scrubber("time", position, 0.0'f, clip.duration, "")
        if position != previous:
          player.paused = true
          player.seek(position)
          if reference != nil:
            reference.sync(player)
      else:
        text "Playing: bind pose"
      text &"Speed: {speed:.2f}x"
      scrubber("speed", speed, 0.0'f, 3.0'f, "")
      text &"Cross-fade: {fade:.2f}s"
      scrubber("fade", fade, 0.0'f, 1.0'f, "")
      checkBox("Bones overlay", showBones)
      if shading == Weights:
        checkBox("Mesh edges", wireframe)
      if shading == Weights or showBones:
        group "bone choice":
          box RowWidth, 36
          layout LeftToRight
          itemSpacing 5
          button "<":
            selectedBone = (selectedBone + weightPreview.bones.len - 1) mod
              weightPreview.bones.len
          button ">":
            selectedBone = (selectedBone + 1) mod weightPreview.bones.len
          text weightPreview.bones[selectedBone].name
        group "hands":
          box RowWidth, 36
          layout LeftToRight
          itemSpacing 5
          button "Left hand":
            selectedBone = weightPreview.boneIndex("LeftHand")
          button "Right hand":
            selectedBone = weightPreview.boneIndex("RightHand")
          button "Forearm":
            let side =
              if weightPreview.bones[selectedBone].name.startsWith("Right"):
                "Right"
              else:
                "Left"
            selectedBone = weightPreview.boneIndex(side & "ForeArm")
        group "bone camera":
          box RowWidth, 36
          layout LeftToRight
          itemSpacing 5
          button "Focus bone":
            focusBone = true
            distance = 1.6
          button "Whole model":
            focusBone = false
            distance = 5.8
            target = vec3(0, 1.52, 0)
        checkBox("Bone names", boneLabels)
        if weightPreview.bones[selectedBone].name.endsWith("Hand"):
          checkBox("Rest wrist (preview only)", restWrist)
          text &"Joint gap: {weightPreview.jointGap(selectedBone):.5f}"
          text &"Wrist bend: {weightPreview.jointBend(selectedBone):.1f} deg"
        text "W: weights. B: bones. F: focus."
      text "Animation clips"
      clipButtons(false)
      for clip in manifest.clips:
        if clip.kind == "pose":
          text "Poses"
          clipButtons(true)
          break

  when defined(takeScreenshot):
    var screenshotFrame = 0
    let
      shotPath = getEnv("SHOT", TempDir / "blender_chars_shot.png")
      shotFrame = envInteger("SHOT_FRAME", 40)
      anim2Frame = envInteger("ANIM2_FRAME", -1)

  window.onFrame = proc() =
    ## Advances the animation, draws the selected parts, and updates controls.
    let now = epochTime()
    var dt = clamp(now - lastFrameTime, 0.0, 0.1).float32
    lastFrameTime = now
    when defined(takeScreenshot):
      dt = 1.0 / 60.0
    updateCamera()
    if window.buttonPressed[KeyP]:
      showParts = not showParts
    if window.buttonPressed[KeyA]:
      showAnimations = not showAnimations
    if window.buttonPressed[KeyW]:
      shading = if shading == Weights: Clay else: Weights
      showBones = shading == Weights
    if window.buttonPressed[KeyB]:
      showBones = not showBones
    if window.buttonPressed[KeyF]:
      focusBone = true
      distance = 1.6
    player.timeScale = speed
    player.update(dt)
    if restWrist and weightPreview.bones[selectedBone].name.endsWith("Hand"):
      let joint = weightPreview.bones[selectedBone].node
      joint.rot = joint.baseRot
    let modelTransform =
      if compareOriginal:
        translate(vec3(1.2, 0, 0))
      else:
        mat4()
    model.root.updateTransforms(modelTransform)
    if reference != nil:
      reference.player.paused = player.paused
      reference.player.timeScale = speed
      reference.player.update(dt)
      reference.root.updateTransforms(reference.transform)
    if focusBone:
      let ends = weightPreview.bones[selectedBone].endpoints()
      target = (ends.head + ends.tail) / 2
      focusBone = false
    weightPreview.updateWeights(shading == Weights, selectedBone)
    eyeTextures.applyPupilTint(pupilTint)
    if shading != Weights:
      applySkin()
      hairMaterials.applyHairTint(hairTint)
      browMaterials.applyBrowTint(
        if matchBrows: hairTint else: WhiteBrows
      )
    let
      aspect = window.size.x.float32 / max(window.size.y.float32, 1)
      view = cameraView()
      projection = perspective(45.0'f, aspect, 0.02'f, 100.0'f)
      forward = normalize(target - eye)
      right = normalize(cross(forward, vec3(0, 1, 0)))
      up = cross(right, forward)
      key = normalize(-right * 0.6 + up * 0.45 - forward * 0.7)
    pbr.size = window.size
    pbr.clearColor = color(0.07, 0.08, 0.11, 1)
    pbr.transform = modelTransform
    pbr.view = view
    pbr.proj = projection
    pbr.tint = color(1, 1, 1, 1)
    pbr.useTrs = true
    pbr.ambientLightColor = color(0.32, 0.36, 0.46, 0.35)
    pbr.sunLightDirection = -key
    pbr.sunLightColor = color(0.95, 0.96, 1, 1)
    pbr.rimLightDirection = normalize(vec3(-1, 1, -1))
    pbr.rimLightColor = color(0.95, 0.72, 0.46, 0.25)
    pbr.debugView = dvLit
    pbr.cameraPosition = eye
    pbr.useShadows = false
    pbr.drawSkybox = false
    pbr.vsync = true
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.07, 0.08, 0.11, 1))
    if msaa:
      glEnable(GL_MULTISAMPLE)
    else:
      glDisable(GL_MULTISAMPLE)
    case shading
    of Clay, Weights:
      if compareOriginal:
        pbr.transform = reference.transform
        pbr.draw(reference.root)
        pbr.transform = modelTransform
      pbr.draw(model.root)
      if shading == Weights and wireframe:
        glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
        glEnable(GL_POLYGON_OFFSET_LINE)
        glPolygonOffset(-1, -1)
        pbr.tint = color(0.10, 0.13, 0.20, 1)
        pbr.draw(model.root)
        glDisable(GL_POLYGON_OFFSET_LINE)
        glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
    of Toon:
      toon.drawBackground()
      toon.view = view
      toon.proj = projection
      toon.transform = modelTransform
      toon.cameraPosition = eye
      toon.lightDirection = pbr.sunLightDirection
      toon.rimColor = color(1, 1, 1, if rimLight: rimStrength else: 0)
      toon.unlitNodes.clear()
      for name in nodes.keys:
        if name.startsWith("Eyes_") or
          (unlitFace and (name.startsWith("Mouth_") or
                         name.startsWith("Brow_"))):
            toon.unlitNodes.incl name
      if reference != nil:
        for name in reference.nodes.keys:
          if name.startsWith("Eye_") or
            (unlitFace and (name.startsWith("Mouth_") or
                           name.startsWith("Brow_"))):
              toon.unlitNodes.incl name
      if compareOriginal:
        toon.transform = reference.transform
        toon.draw(reference.root)
        toon.transform = modelTransform
      toon.draw(model.root)
    renderer.endFrame()
    glDisable(GL_DEPTH_TEST)
    glDisable(GL_CULL_FACE)
    glDisable(GL_BLEND)
    glDisable(GL_MULTISAMPLE)
    sk.beginUi(window, window.size)
    if compareOriginal:
      for (x, title) in [(-1.2'f, "ORIGINAL KIT"),
                         (1.2'f, "BLENDER MODEL")]:
        let
          point = projection * view * vec4(x, 3.18, 0, 1)
          size = sk.getTextSize(sk.textStyle, title)
          position = vec2(
            (point.x / point.w + 1) * window.size.x.float32 / 2 - size.x / 2,
            35
          )
        discard sk.drawText(
          sk.textStyle, title, position, rgbx(235, 241, 249, 255)
        )
    if showBones:
      weightPreview.drawSkeleton(
        sk, projection * view, window.size.vec2, selectedBone, boneLabels
      )
    if shading == Weights:
      sk.drawLegend(
        vec2(window.size.x.float32 / 2, window.size.y.float32 - 100),
        weightPreview.bones[selectedBone].name
      )
    ui:
      partsPanel()
      animationsPanel()
    sk.endUi()
    when defined(takeScreenshot):
      inc screenshotFrame
      if screenshotFrame == anim2Frame:
        playClip(getEnv("ANIM2"), fade)
      if screenshotFrame == shotFrame:
        let screenshot = newImage(window.size.x, window.size.y)
        glReadPixels(
          0, 0, window.size.x, window.size.y,
          GL_RGBA, GL_UNSIGNED_BYTE, screenshot.data[0].addr
        )
        screenshot.flipVertical()
        screenshot.writeFile(shotPath)
        quit(0)
    window.swapBuffers()

  while not window.closeRequested:
    pollEvents()

run()
