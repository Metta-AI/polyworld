## A modular character viewer backed by editable Blender assets.
## Run with `nim r experiments/chargen/chargen.nim`.
## Rebuild assets with Blender's background Python runner and build_model.py.
## Add meshes, outfits, colors, and clips in polyworld_art/characters/chargen.

import
  std/[os, random, sets, strformat, strutils, tables, times],
  bumpy, chroma, gltf, silky, vmath,
  polyworld/[animblend, chargen, toon], weights, lineups

when defined(takeScreenshot):
  import pixie

const
  ExperimentDir = currentSourcePath().parentDir
  AssetDir = ChargenLibrary
  ThemeDir = ExperimentDir.parentDir.parentDir.parentDir /
    "polyworld_art/themes/main"
  TempDir = ExperimentDir.parentDir.parentDir / "tmp/chargen"
  AtlasPath = TempDir / "viewer.atlas.png"
  RowWidth = 320
  AnimationFrameRate = 30

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
    raise newException(ChargenError, "Invalid number for " & name)

proc envInteger(name: string, fallback: int): int =
  ## Reads an integer launch option with an experiment-specific error.
  if not existsEnv(name):
    return fallback
  try:
    result = getEnv(name).parseInt
  except ValueError:
    raise newException(ChargenError, "Invalid integer for " & name)

proc run() =
  ## Opens the modular character and its animation controls.
  let
    directory = getEnv("CHARGEN_LIBRARY", AssetDir)
    manifest = readManifest(directory)
    builder = newAtlasBuilder(1024, 4)
  createDir(TempDir)
  builder.addDir(ThemeDir & "/", ThemeDir & "/")
  builder.addFont(ThemeDir / "IBMPlexSans-Regular.ttf", "H1", 28.0)
  builder.addFont(ThemeDir / "IBMPlexSans-Regular.ttf", "Default", 18.0)
  builder.write(AtlasPath)

  let window = newWindow(
    "Chargen",
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
    model = readCharacter(directory, manifest)
    nodes = partNodes(model.root)
    hairMaterials = initHairMaterials(nodes, manifest)
    hatMaterials = initHatMaterials(nodes, manifest)
    browMaterials = initBrowMaterials(model.root, manifest)
    player = newClipPlayer(model.root)
  pbr.attachEnvironmentMap(loadDefaultEnvironmentMap())
  var
    clothes = initClothMaterials(nodes, manifest)
    eyeTextures = readEyeTextures(model.root, directory, manifest)
    pupil = manifest.pupilColors.colorIndex(
      getEnv("PUPIL", manifest.defaultPupilColor)
    )
    pupilTint = manifest.pupilColors[pupil].rgb
    customPupil = false
    hat = manifest.hatColors.colorIndex(
      getEnv("HAT_COLOR", manifest.defaultHatColor)
    )
    hatTint = manifest.hatColors[hat].rgb
    hair = manifest.hairColors.colorIndex(
      getEnv("HAIR_COLOR", manifest.defaultHairColor)
    )
    hairTint = manifest.hairColors[hair].rgb
    matchBrows = getEnv("BROW_TINT", "Hair") != "White"
    weightPreview = initWeightPreview(model.root, directory)
    selectedBone = weightPreview.boneIndex("LeftHand")
    showBones = false
    wireframe = false
    boneLabels = false
    restWrist = false
    focusBone = false
    lineup: seq[LineupActor]
    lineupGroup = "Gnomes"
    showLineup = false
    selection = manifest.defaultSelection()
    shading = Toon
    palette = 0
    showParts = true
    showAnimations = true
    unlitFace = true
    rimLight = true
    msaa = true
    rimStrength = 0.6'f
    skin = manifest.defaultSkin
    skinRgb = [
      manifest.skins[skin].color[0] * 255,
      manifest.skins[skin].color[1] * 255,
      manifest.skins[skin].color[2] * 255
    ]
    customSkin = false
    presetIndex = 0
    presetGroup = ""
    randomTitle = ""
    hasGnomes = false
    hasGota = false
    hasGods = false
    hasGnomeParts = false
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

  for preset in manifest.presets:
    if preset.group == "Gnomes":
      hasGnomes = true
    if preset.group == "Gota":
      hasGota = true
    if preset.group == "Gota Gods":
      hasGods = true
  for category in manifest.categories:
    for item in category.items:
      if item.alignment == GnomeOnly:
        hasGnomeParts = true

  for clip in manifest.clips:
    if player.clipIndex(clip.name) < 0:
      raise newException(ChargenError, "Missing animation: " & clip.name)
    player.setRule(clip.name, ClipRule(
      loop: clip.loop, next: clip.next, hold: clip.hold
    ))

  proc playClip(name: string, duration: float32) =
    ## Plays a named clip or the bind pose and resumes the transport.
    if name.len > 0 and player.clipIndex(name) < 0:
      raise newException(ChargenError, "Unknown animation: " & name)
    player.play(name, duration)
    player.paused = false

  proc clipPosition(): float32 =
    ## Returns the displayed clip time, wrapping only looping animations.
    if player.current < 0:
      return 0
    let clip = model.root.animations[player.current]
    result = min(player.currentTime, clip.duration)
    for spec in manifest.clips:
      if spec.name == clip.name and spec.loop and clip.duration > 0:
        result = player.currentTime -
          floor(player.currentTime / clip.duration) * clip.duration

  proc applyParts() =
    ## Applies the current independent face and ear choices.
    nodes.applySelection(manifest, selection)

  proc applySkin() =
    ## Recolors the body and detachable ears without tinting face materials.
    if customSkin:
      nodes.applySkin(manifest, color(
        skinRgb[0] / 255, skinRgb[1] / 255, skinRgb[2] / 255, 1
      ))
    else:
      nodes.applySkin(manifest, skin)

  proc chooseSkin(index: int) =
    ## Restores a preset and seeds its RGB values for further editing.
    skin = index
    customSkin = false
    for i in 0 ..< 3:
      skinRgb[i] = manifest.skins[skin].color[i] * 255

  proc loadPreset(index: int) =
    ## Loads an outfit while preserving the current animation and transport.
    presetIndex = index
    randomTitle = ""
    let preset = manifest.presets[index]
    manifest.applyPreset(selection, preset)
    clothes.applyClothPreset(preset)
    chooseSkin(clamp(preset.skin, 0, max(0, manifest.skins.high)))
    applyParts()
    if preset.hatColor.len > 0:
      hat = manifest.hatColors.colorIndex(preset.hatColor)
      hatTint = manifest.hatColors[hat].rgb
    if preset.hairColor.len > 0:
      hair = manifest.hairColors.colorIndex(preset.hairColor)
      hairTint = manifest.hairColors[hair].rgb
    if preset.pupilColor.len > 0:
      pupil = manifest.pupilColors.colorIndex(preset.pupilColor)
      pupilTint = manifest.pupilColors[pupil].rgb
    if preset.group == "Gota Gods":
      distance = 7.5
      target = vec3(0.4, 1.85, 0)

  proc frameLineup() =
    ## Frames the selected lineup with room for the controls panel.
    yaw = 0
    pitch = 0
    case lineupGroup
    of "Gota":
      distance = 22
      target = vec3(3.2, 3.7, 0)
    of "Creeps":
      distance = 7.5
      target = vec3(1.6, 1.7, 0)
      lineup.poseCreeps()
    of "Gota Gods":
      distance = 10.5
      target = vec3(1.8, 1.9, 0)
    else:
      distance = 14.5
      target = vec3(2.5, 5.94, 0)
    focusBone = false

  proc gnomePose() =
    ## Uses the T pose clip when shipped, otherwise the rig's bind pose.
    playClip(if player.clipIndex("A_TPose") >= 0: "A_TPose" else: "", 0)

  proc setLineup(enabled: bool, group = "Gnomes") =
    ## Opens a preset group while sharing the normal pose controls.
    showLineup = enabled
    if enabled:
      if lineup.len == 0 or lineupGroup != group:
        lineup = readLineup(directory, manifest, model.root, group)
      lineupGroup = group
      showParts = false
      showBones = false
      restWrist = false
      shading = Toon
      frameLineup()
      if group == "Creeps":
        playClip("Sword_Attack", 0)
        player.seek(CreepStrikeTime)
        player.paused = true
    else:
      showParts = true
      yaw = 0.22
      pitch = 0.08
      distance = 5.8
      target = vec3(0, 1.52, 0)

  proc randomize(alignment = Both) =
    ## Rolls compatible parts plus skin, hair, and pupil color presets.
    if showLineup:
      setLineup(false)
    randomTitle =
      case alignment
      of Both: "Random"
      of GoodOnly: "Good random"
      of EvilOnly: "Evil random"
      of GnomeOnly: "Random gnome"
    var outfits: seq[Preset]
    if alignment == GnomeOnly:
      for preset in manifest.presets:
        if preset.group == "Gnomes":
          outfits.add preset
    if outfits.len > 0:
      let outfit = outfits[rng.rand(outfits.high)]
      chooseSkin(outfit.skin)
      clothes.applyClothPreset(outfit)
      hair = manifest.hairColors.colorIndex(
        outfits[rng.rand(outfits.high)].hairColor
      )
      pupil = manifest.pupilColors.colorIndex(
        outfits[rng.rand(outfits.high)].pupilColor
      )
    else:
      if manifest.skins.len > 0:
        chooseSkin(rng.rand(manifest.skins.high))
      clothes.applyClothPreset(Preset())
      hair = rng.rand(manifest.hairColors.high)
      pupil = rng.rand(manifest.pupilColors.high)
    selection = manifest.randomSelection(rng, alignment)
    hat = rng.rand(manifest.hatColors.high)
    hatTint = manifest.hatColors[hat].rgb
    hairTint = manifest.hairColors[hair].rgb
    pupilTint = manifest.pupilColors[pupil].rgb
    customPupil = false
    applyParts()

  if existsEnv("PRESET"):
    let index = envInteger("PRESET", 1) - 1
    if index < 0 or index >= manifest.presets.len:
      raise newException(
        ChargenError, "PRESET is outside the outfit list."
      )
    loadPreset(index)
  if existsEnv("RANDOM_SEED"):
    rng = initRand(envInteger("RANDOM_SEED", 19))
    let alignment =
      case getEnv("RANDOM_ALIGNMENT", "both")
      of "both": Both
      of "good": GoodOnly
      of "evil": EvilOnly
      of "gnome": GnomeOnly
      else:
        raise newException(ChargenError, "Unknown RANDOM_ALIGNMENT.")
    randomize(alignment)
  if existsEnv("SKIN_RGB"):
    let channels = getEnv("SKIN_RGB").split(',')
    if channels.len != 3:
      raise newException(ChargenError, "SKIN_RGB needs three values, 0 to 255.")
    for i, channel in channels:
      try:
        let value = channel.strip().parseFloat.float32
        if not (value >= 0 and value <= 255):
          raise newException(ValueError, "Channel outside 0 to 255.")
        skinRgb[i] = value
      except ValueError:
        raise newException(ChargenError, "Invalid SKIN_RGB: " & channel)
    customSkin = true
  for category in manifest.categories:
    let setting = category.key.toUpperAscii().replace(" ", "_")
    if existsEnv(setting):
      manifest.selectPart(selection, category.key, getEnv(setting))
  applyParts()
  if existsEnv("ANIM") or player.current < 0:
    let defaultClip =
      if manifest.defaultAnimation.len > 0:
        manifest.defaultAnimation
      elif player.clipIndex("Walk_Loop") >= 0:
        "Walk_Loop"
      elif manifest.clips.len > 0:
        manifest.clips[0].name
      else:
        ""
    playClip(getEnv("ANIM", defaultClip), 0)
  yaw = envNumber("CAM_YAW", yaw)
  pitch = clamp(envNumber("CAM_PITCH", pitch), -1.2, 1.4)
  distance = clamp(envNumber("CAM_DIST", distance), 2, 12)
  if existsEnv("TOON"):
    shading = Toon
  if getEnv("SHADING") == "Normal":
    shading = Clay
  palette = envInteger("TOON", 0)
  if palette < 0 or palette >= ToonPalettes.len:
    raise newException(ChargenError, "TOON is outside the palette list.")
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
      raise newException(ChargenError, "Unknown WEIGHTS bone.")
  showBones = getEnv("BONES", if showBones: "1" else: "0") != "0"
  focusBone = getEnv("FOCUS_BONE", "0") != "0"
  if focusBone:
    distance = envNumber("CAM_DIST", 1.6)
  restWrist = getEnv("REST_WRIST", "0") != "0"
  wireframe = getEnv("WIREFRAME", if shading == Weights: "1" else: "0") != "0"
  if getEnv("GNOME_LINEUP", "0") == "1":
    setLineup(true)
  if getEnv("GOTA_LINEUP", "0") == "1":
    setLineup(true, "Gota")
  if getEnv("CREEP_REVIEW", "0") == "1":
    setLineup(true, "Creeps")
  if getEnv("GODS_LINEUP", "0") == "1":
    setLineup(true, "Gota Gods")

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
      distance = clamp(
        distance * pow(0.92'f, window.scrollDelta.y),
        0.6,
        if showLineup: 20.0 else: 12.0
      )

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
        pupil = (pupil + manifest.pupilColors.len - 1) mod manifest.pupilColors.len
        pupilTint = manifest.pupilColors[pupil].rgb
      button ">":
        pupil = (pupil + 1) mod manifest.pupilColors.len
        pupilTint = manifest.pupilColors[pupil].rgb
      text "Pupil: " &
        (if pupilTint == manifest.pupilColors[pupil].rgb: manifest.pupilColors[pupil].name
         else: "Custom")
    checkBox("Custom pupil color", customPupil)
    if customPupil:
      for i, channel in ["Red", "Green", "Blue"]:
        scrubber(channel, pupilTint[i], 0.0'f, 1.0'f, "")

  proc skinControls() =
    ## Offers live RGB skin editing using familiar zero-to-255 channels.
    checkBox("Custom skin RGB", customSkin)
    if customSkin:
      for i, channel in ["Red", "Green", "Blue"]:
        scrubber(
          "Skin " & channel,
          skinRgb[i],
          0.0'f,
          255.0'f,
          channel & ": " & $(skinRgb[i] + 0.5).int
        )

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
      let
        title = category.key & ": " &
          (if selected < 0: "None" else: category.items[selected].name)
        titleSize = sk.getTextSize(sk.textStyle, title)
        titleRect = rect(sk.placedAt(titleSize), titleSize)
      text title
      if selected >= 0 and
        sk.mousePos.overlaps(titleRect) and
        sk.mousePos.overlaps(sk.clipRect) and
        sk.mouseIdleTime >= sk.tooltipThreshold:
          sk.tooltipAnchor = titleRect
          let label =
            case category.items[selected].alignment
            of Both: "Shared random part"
            of GoodOnly: "Good and gnome random"
            of EvilOnly: "Evil random only"
            of GnomeOnly: "Gnome random only"
          tooltip label

  proc hairControls() =
    ## Offers natural and vivid colors shared by scalp and facial hair.
    group "hair color":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 5
      button "<":
        hair = (hair + manifest.hairColors.len - 1) mod manifest.hairColors.len
        hairTint = manifest.hairColors[hair].rgb
      button ">":
        hair = (hair + 1) mod manifest.hairColors.len
        hairTint = manifest.hairColors[hair].rgb
      text "Color: " &
        (if hairTint == manifest.hairColors[hair].rgb: manifest.hairColors[hair].name
         else: "Custom")
    for i, channel in ["Red", "Green", "Blue"]:
      scrubber(
        "Hair " & channel,
        hairTint[i],
        0.0'f,
        1.0'f,
        channel
      )

  proc hatControls() =
    ## Tints the hat fabric while retaining fixed-color ornament materials.
    group "hat color":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 5
      button "<":
        hat = (hat + manifest.hatColors.len - 1) mod manifest.hatColors.len
        hatTint = manifest.hatColors[hat].rgb
      button ">":
        hat = (hat + 1) mod manifest.hatColors.len
        hatTint = manifest.hatColors[hat].rgb
      text "Hat: " &
        (if hatTint == manifest.hatColors[hat].rgb:
          manifest.hatColors[hat].name
        else:
          "Custom")
    for i, channel in ["Red", "Green", "Blue"]:
      scrubber("Hat " & channel, hatTint[i], 0.0'f, 1.0'f, channel)

  proc selectedPreset(index: int) =
    ## Applies a character preset without changing animation playback.
    if showLineup:
      setLineup(false)
    loadPreset(index)

  proc clothControls(category: string) =
    ## Edits a garment slot's fabric without tinting its metal details.
    for cloth in clothes.mitems:
      if cloth.category != category:
        continue
      checkBox("Custom " & category & " color", cloth.enabled)
      if cloth.enabled:
        for i, channel in ["Red", "Green", "Blue"]:
          scrubber(
            category & " " & channel, cloth.tint[i], 0.0'f, 1.0'f, channel
          )

  proc partsPanel() =
    ## Browses generated character parts and presets.
    subWindow("Character", showParts, vec2(10, 10), vec2(360, 880)):
      let source = manifest
      if source.presets.len > 0:
        let choice = presetIndex
        text:
          if randomTitle.len > 0:
            randomTitle
          else:
            source.presets[choice].name
        group "preset":
          box RowWidth, 34
          layout LeftToRight
          itemSpacing 4
          button "<":
            selectedPreset((choice + source.presets.len - 1) mod
              source.presets.len)
          button ">":
            selectedPreset((choice + 1) mod source.presets.len)
          button "Random":
            randomize()
          button "Clear":
            selection = manifest.defaultSelection()
            for i, category in manifest.categories:
              if category.key notin ["Body", "Face"]:
                selection[i] = -1
            applyParts()
      group "preset groups":
        box RowWidth, 34
        layout LeftToRight
        itemSpacing 4
        if hasGota:
          button "Gota presets":
            presetGroup =
              if presetGroup == "Gota": "" else: "Gota"
        if hasGnomes:
          button "Gnome presets":
            presetGroup =
              if presetGroup == "Gnomes": "" else: "Gnomes"
      if hasGods:
        button "God presets":
          presetGroup =
            if presetGroup == "Gota Gods": "" else: "Gota Gods"
      if presetGroup.len > 0:
        for i, preset in manifest.presets:
          if preset.group == presetGroup:
            button preset.name:
              selectedPreset(i)
      group "aligned random":
        box RowWidth, 34
        layout LeftToRight
        itemSpacing 4
        button "Good random":
          randomize(GoodOnly)
        button "Evil random":
          randomize(EvilOnly)
      if hasGnomeParts:
        button "Random gnome":
          randomize(GnomeOnly)
      if source.skins.len > 0:
        var
          choice = skin
          changed = false
        group "skin":
          box RowWidth, 34
          layout LeftToRight
          itemSpacing 4
          button "<":
            choice = (choice + source.skins.len - 1) mod source.skins.len
            changed = true
          button ">":
            choice = (choice + 1) mod source.skins.len
            changed = true
          text "Skin: " &
            (if customSkin: "Custom"
             else: source.skins[choice].name)
        if changed:
          chooseSkin(choice)
        skinControls()
      var categoryOrder: seq[int]
      for key in ["Headgear", "Chest", "Belt", "Jacket",
                  "Suspenders", "Leg", "Foot", "Left hand",
                  "Right hand", "Back"]:
        for i, category in source.categories:
          if category.key == key:
            categoryOrder.add i
      for i, category in source.categories:
        if category.key notin ["Headgear", "Chest", "Jacket", "Belt",
                              "Suspenders", "Leg", "Foot", "Left hand",
                              "Right hand", "Back"]:
          categoryOrder.add i
      for i in categoryOrder:
        let category = source.categories[i]
        if category.items.len == 0:
          continue
        var choice = selection[i]
        if partPicker(category, choice):
          selection[i] = choice
          applyParts()
        if category.key == "Headgear":
          hatControls()
        if choice >= 0:
          clothControls(category.key)
        if category.key == "Hair":
          hairControls()
        if category.key == "Brow":
          checkBox("Brows match hair color", matchBrows)
        if category.key == "Beard":
          text "Beard uses hair color."
      pupilControls()
      button "Reset parts":
        selection = manifest.defaultSelection()
        applyParts()
      text "Drag: orbit. Right drag: pan."
      text "Scroll: zoom. P: parts. A: controls."
      button "Reset camera":
        focusBone = false
        if showLineup:
          frameLineup()
        else:
          yaw = 0.22
          pitch = 0.08
          distance = 5.8
          target = vec3(0, 1.52, 0)

  proc clipButtons() =
    ## Packs supported animations into readable button rows.
    proc label(name: string): string =
      ## Shortens button labels while keeping the exported clip names intact.
      if name == "A_TPose":
        "T pose"
      else:
        name.replace("_Loop", "").replace("_", " ")
    var
      rows: seq[seq[string]] = @[@[]]
      used = 0.0'f
    for clip in manifest.clips:
      let width = sk.getTextSize(sk.textStyle, label(clip.name)).x +
        sk.theme.padding.float32 * 3
      if used + width > RowWidth.float32 and rows[^1].len > 0:
        rows.add @[]
        used = 0
      rows[^1].add clip.name
      used += width
    for i, names in rows:
      if names.len == 0:
        continue
      group "clips " & $i:
        box RowWidth, 36
        layout LeftToRight
        itemSpacing 4
        for name in names:
          button label(name):
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
        if not showLineup:
          radioButton("Weights", shading, Weights)
      checkBox("Polygon overlay (V)", wireframe)
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

      if hasGnomes:
        var enabled = showLineup and lineupGroup == "Gnomes"
        let previous = enabled
        checkBox("Nine gnomes", enabled)
        if enabled != previous:
          setLineup(enabled)
      if hasGota:
        var enabled = showLineup and lineupGroup == "Gota"
        let previous = enabled
        checkBox("Ten Gota heroes", enabled)
        if enabled != previous:
          setLineup(enabled, "Gota")
        button "Creep sword pose":
          setLineup(true, "Creeps")
      if hasGods:
        var enabled = showLineup and lineupGroup == "Gota Gods"
        let previous = enabled
        checkBox("Gota gods", enabled)
        if enabled != previous:
          setLineup(enabled, "Gota Gods")
      if showLineup:
        text lineupGroup & " character lineup"
        if lineupGroup == "Creeps":
          group "creep views":
            box RowWidth, 36
            layout LeftToRight
            itemSpacing 5
            for view, label in ["Front", "Side", "Top"]:
              button label:
                frameLineup()
                lineup.poseCreeps(LineupView(view))
        button "Lineup T pose":
          gnomePose()
          frameLineup()
      text "Parts: P. Controls: A."
      group "playback":
        box RowWidth, 36
        layout LeftToRight
        itemSpacing 5
        button(if player.paused: "Resume" else: "Pause"):
          player.paused = not player.paused
        button "Restart":
          player.restart()
        button "Bind pose":
          playClip("", fade)
      if player.current >= 0:
        let
          clip = model.root.animations[player.current]
          lastFrame = round(clip.duration * AnimationFrameRate).int
        text "Playing: " & clip.name
        var
          position = clipPosition()
          frame = clamp(round(position * AnimationFrameRate).int, 0, lastFrame)
          stepped = false
        let
          previous = position
          previousFrame = frame
        text &"Frame: {frame} / {lastFrame} (30 fps, starts at 0)"
        scrubber("animation frame", frame, 0, lastFrame, "Frame " & $frame)
        group "frame steps":
          box RowWidth, 36
          layout LeftToRight
          itemSpacing 5
          button "Previous frame":
            frame = max(0, frame - 1)
            stepped = true
          button "Next frame":
            frame = min(lastFrame, frame + 1)
            stepped = true
        if frame != previousFrame or stepped:
          position = min(frame.float32 / AnimationFrameRate, clip.duration)
        text &"Time: {position:.3f} / {clip.duration:.3f}s"
        scrubber("time", position, 0.0'f, clip.duration, "")
        if position != previous or stepped:
          player.paused = true
          player.seek(position)
      else:
        text "Playing: bind pose"
      text &"Speed: {speed:.2f}x"
      scrubber("speed", speed, 0.0'f, 3.0'f, "")
      text &"Cross-fade: {fade:.2f}s"
      scrubber("fade", fade, 0.0'f, 1.0'f, "")
      if not showLineup:
        checkBox("Bones overlay", showBones)
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
      text "Quaternius Standard - in-place"
      clipButtons()

  when defined(takeScreenshot):
    var screenshotFrame = 0
    let
      shotPath = getEnv("SHOT", TempDir / "chargen_shot.png")
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
    if window.buttonPressed[KeyW] and not showLineup:
      shading = if shading == Weights: Clay else: Weights
      showBones = shading == Weights
    if window.buttonPressed[KeyV]:
      wireframe = not wireframe
    if window.buttonPressed[KeyB] and not showLineup:
      showBones = not showBones
    if window.buttonPressed[KeyF] and not showLineup:
      focusBone = true
      distance = 1.6
    player.timeScale = speed
    player.update(dt)
    if restWrist and weightPreview.bones[selectedBone].name.endsWith("Hand"):
      let joint = weightPreview.bones[selectedBone].node
      joint.rot = joint.baseRot
    let modelTransform = mat4()
    model.root.updateTransforms(modelTransform)
    if showLineup:
      lineup.sync()
    if focusBone:
      let ends = weightPreview.bones[selectedBone].endpoints()
      target = (ends.head + ends.tail) / 2
      focusBone = false
    weightPreview.updateWeights(shading == Weights, selectedBone)
    eyeTextures.applyPupilTint(pupilTint)
    if shading != Weights:
      applySkin()
      hairMaterials.applyHairTint(hairTint)
      hatMaterials.applyHatTint(hatTint)
      clothes.applyClothTint()
      browMaterials.applyBrowTint(
        if matchBrows: hairTint else: WhiteBrows
      )
    let
      aspect = window.size.x.float32 / max(window.size.y.float32, 1)
      view = cameraView()
      projection =
        if showLineup:
          let halfHeight = distance * 0.44'f
          ortho(-halfHeight * aspect, halfHeight * aspect,
            -halfHeight, halfHeight, 0.02'f, 100.0'f)
        else:
          perspective(45.0'f, aspect, 0.02'f, 100.0'f)
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
    toon.view = view
    toon.proj = projection
    toon.transform = modelTransform
    toon.cameraPosition = eye
    toon.lightDirection = pbr.sunLightDirection
    toon.rimColor = color(1, 1, 1, if rimLight: rimStrength else: 0)
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.07, 0.08, 0.11, 1))
    if msaa:
      glEnable(GL_MULTISAMPLE)
    else:
      glDisable(GL_MULTISAMPLE)
    case shading
    of Clay, Weights:
      if showLineup:
        for actor in lineup:
          pbr.transform = actor.transform
          pbr.draw(actor.root)
      else:
        pbr.draw(model.root)
    of Toon:
      toon.drawBackground()
      toon.unlitNodes.clear()
      for name in nodes.keys:
        if name.startsWith("Eyes_") or
          (unlitFace and (name.startsWith("Mouth_") or
                         name.startsWith("Brow_"))):
            toon.unlitNodes.incl name
      if showLineup:
        for actor in lineup:
          toon.transform = actor.transform
          toon.draw(actor.root)
      else:
        toon.draw(model.root)
    if wireframe:
      glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
      glEnable(GL_POLYGON_OFFSET_LINE)
      glPolygonOffset(-1, -1)
      toon.tint = color(0, 0, 0, 1)
      if showLineup:
        for actor in lineup:
          toon.transform = actor.transform
          toon.draw(actor.root)
      else:
        toon.draw(model.root)
      toon.tint = color(1, 1, 1, 1)
      glDisable(GL_POLYGON_OFFSET_LINE)
      glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
    renderer.endFrame()
    glDisable(GL_DEPTH_TEST)
    glDisable(GL_CULL_FACE)
    glDisable(GL_BLEND)
    glDisable(GL_MULTISAMPLE)
    sk.beginUi(window, window.size)
    if showLineup and lineupGroup == "Creeps" and player.current >= 0:
      let
        clip = model.root.animations[player.current]
        frame = round(clipPosition() * AnimationFrameRate).int
        lastFrame = round(clip.duration * AnimationFrameRate).int
        title = &"{clip.name}  |  Frame {frame} / {lastFrame}"
      discard sk.drawText(
        sk.textStyle, title, vec2(24, 24), rgbx(235, 241, 249, 255)
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
      if not showLineup:
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
