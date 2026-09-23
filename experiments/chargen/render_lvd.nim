import
  std/[os, sets, strutils, tables],
  chroma, gltf, jsony, opengl, pixie, vmath, windy,
  polyworld/[characters, chargen, shadows]

const
  RecipePath = currentSourcePath().parentDir / "lvd_roster.json"
  OutputPath = currentSourcePath().parentDir.parentDir.parentDir /
    "tmp/chargen/lvd-roster-all"
  DataPath = ChargenLibrary.parentDir.parentDir
  RenderSize = 800
  CardSize = 480
  LabelWidth = 420
  Margin = 32
  HeaderHeight = 240
  FooterHeight = 132
  PreviewClips = ["Idle_Loop", "Sword_Idle", "Spell_Simple_Idle_Loop"]
  FaceCategories = ["Eyes", "Mouth", "Brow"]

type
  PlayerLook = object
    name, skin, ears, eyes, mouth, pupil: string
  Role = object
    name, previous, notes, missing, pose, skin: string
    height: float32
    parts: seq[PresetPart]
  Recipe = object
    players: seq[PlayerLook]
    roles: seq[Role]
    skins: seq[chargen.Skin]
  Actor = object
    model: CharacterModel
    preset: Preset
    clip: int

proc slug(value: string): string =
  ## Converts a review label into a stable output basename.
  value.toLowerAscii.replace(" / ", "-").replace(' ', '-')

proc readRecipe(): Recipe {.raises: [ChargenError].} =
  ## Loads the explicit role and player selections for this review.
  try:
    result = readFile(getEnv("LVD_REVIEW_RECIPE", RecipePath)).fromJson(Recipe)
  except IOError, JsonError, ValueError:
    raise newException(ChargenError, getCurrentExceptionMsg())
  if result.players.len != 3 or result.roles.len == 0:
    raise newException(ChargenError, "Review needs three looks and roles.")

proc setPart(preset: var Preset, part: PresetPart) =
  ## Updates an explicit preset slot without inheriting unrelated equipment.
  for selected in preset.parts.mitems:
    if selected.category == part.category:
      selected = part
      return
  raise newException(ChargenError, "Unknown preset slot: " & part.category)

proc makePreset(manifest: Manifest, role: Role, look: PlayerLook): Preset =
  ## Combines fixed equipment with only the player's face and skin choices.
  let skinName =
    if role.skin.len > 0:
      role.skin
    else:
      look.skin
  result = Preset(
    name: "LvD " & role.name & " " & look.name,
    group: "LvD review",
    pose: role.pose,
    hairColor: "Dark brown",
    pupilColor: look.pupil,
    hatColor: manifest.defaultHatColor,
    skin: -1
  )
  for i, skin in manifest.skins:
    if skin.name == skinName:
      result.skin = i
  if result.skin < 0:
    raise newException(ChargenError, "Unknown skin: " & skinName)
  for category in manifest.categories:
    result.parts.add PresetPart(category: category.key, item: "None")
  for part in [
    PresetPart(category: "Face", item: "Base"),
    PresetPart(category: "Nose", item: "Tiny"),
    PresetPart(category: "Brow", item: "02 Confident"),
    PresetPart(category: "Ears", item: look.ears),
    PresetPart(category: "Eyes", item: look.eyes),
    PresetPart(category: "Mouth", item: look.mouth)
  ]:
    result.setPart(part)
  for part in role.parts:
    result.setPart(part)

proc validateInventory(manifest: Manifest, preset: Preset) =
  ## Rejects the library's documented legacy eye and animation exceptions.
  let inventory = manifest.presetManifest(preset)
  for category in inventory.categories:
    for item in category.items:
      if item.id in [
        "eyes/original2", "eyes/neutral", "eyes/happy", "eyes/angry"
      ]:
        raise newException(ChargenError, "Uncleared eye part: " & item.id)
  for name in PreviewClips:
    var found = false
    for clip in manifest.clips:
      if clip.name == name:
        found = true
        if clip.kind != "universal":
          raise newException(ChargenError, "Non-CC0 animation: " & name)
    if not found:
      raise newException(ChargenError, "Missing animation: " & name)

proc loadActor(manifest: Manifest, preset: Preset, height: float32): Actor =
  ## Uses the games' CharGen loader, skin materials, and character model.
  manifest.validateInventory(preset)
  let inventory = manifest.presetManifest(preset)
  result.preset = preset
  result.model = loadCharacterModel(
    readPresetCharacter(ChargenLibrary, manifest, preset, PreviewClips),
    height
  )
  for category in inventory.categories:
    if category.key in FaceCategories:
      for item in category.items:
        result.model.unlitParts.add item.nodes
  var
    visibility: Table[string, bool]
    bodyNodes: HashSet[string]
  for category in inventory.categories:
    if category.key in ["Body", "Face"]:
      for item in category.items:
        for name in item.nodes:
          bodyNodes.incl name
  for name, node in partNodes(result.model.file.root):
    visibility[name] = node.visible
    node.visible = name in bodyNodes
    node.baseVisible = node.visible
  result.model.fitCharacterHeight(
    height,
    result.model.clipIndex("Idle_Loop")
  )
  for name, node in partNodes(result.model.file.root):
    node.visible = visibility[name]
    node.baseVisible = node.visible
  result.clip = result.model.clipIndex(preset.pose)

proc label(
  image: Image,
  font: Font,
  value: string,
  x, y, width: int,
  size: float32,
  tint = color(0.12, 0.15, 0.19)
) =
  ## Places readable labels outside the untouched game-rendered character.
  font.size = size
  font.paint.color = tint
  image.fillText(
    font.typeset(value, vec2(width.float32, 180)),
    translate(vec2(x.float32, y.float32))
  )

proc renderActor(
  window: Window,
  scene: CharacterScene,
  actor: Actor,
  angle, pitch: float32
): Image =
  ## Captures the actual shared toon shader with a fixed common camera scale.
  let
    target = vec3(0, 1.10, 0)
    eye = target + vec3(0, sin(pitch), -cos(pitch)) * 10
    view = lookAt(eye, target, vec3(0, 1, 0))
    projection = ortho(-1.55'f, 1.55'f, -1.55'f, 1.55'f, 0.02'f, 50'f)
  for frame in 0 ..< 4:
    sunDepthPasses(window.size):
      scene.sunDepthPass = true
      scene.drawCharacter(
        actor.model,
        vec3(0),
        PI.float32 + angle,
        actor.clip,
        0.35'f
      )
    scene.sunDepthPass = false
    scene.beginCharacters(window, view, projection, eye)
    scene.renderer.clearScreen(color(0.96, 0.97, 0.98, 1))
    glEnable(GL_MULTISAMPLE)
    scene.drawCharacter(
      actor.model,
      vec3(0),
      PI.float32 + angle,
      actor.clip,
      0.35'f
    )
    scene.finishCharacters()
    if frame == 3:
      result = newImage(RenderSize, RenderSize)
      glReadPixels(
        0,
        0,
        RenderSize.GLsizei,
        RenderSize.GLsizei,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        result.data[0].addr
      )
      result.flipVertical()
    window.swapBuffers()
    pollEvents()

proc renderSheet(
  directory: string,
  window: Window,
  scene: CharacterScene,
  recipe: Recipe,
  actors: seq[Actor],
  angle, pitch: float32,
  name: string
) =
  ## Arranges fixed-scale runtime captures beside the old unit mappings.
  let
    sheet = newImage(
      Margin * 2 + LabelWidth + CardSize * recipe.players.len,
      HeaderHeight + CardSize * recipe.roles.len + FooterHeight
    )
    font = readFont(DataPath / "fonts/Rubik-Regular.ttf")
    bold = readFont(DataPath / "fonts/Rubik-Bold.ttf")
  sheet.fill(rgba(245, 247, 250, 255))
  sheet.label(
    bold, "LvD / REAL CHARGEN ROSTER", Margin, 22, sheet.width - 64, 48
  )
  sheet.label(
    font,
    "Existing CC0 parts, game toon renderer. Clothing stays fixed per role.",
    Margin, 90, sheet.width - 64, 27
  )
  sheet.label(bold, "OLD UNITS > SHARED ROLE", Margin, 158, LabelWidth, 23)
  for column, look in recipe.players:
    let x = Margin + LabelWidth + column * CardSize
    sheet.label(bold, look.name, x + 18, 145, CardSize - 24, 32)
    sheet.label(font, look.ears & " ears", x + 18, 190, CardSize - 24, 23)
  for row, role in recipe.roles:
    let y = HeaderHeight + row * CardSize
    sheet.label(bold, role.name, Margin, y + 102, LabelWidth - 24, 38)
    sheet.label(
      font, role.previous, Margin, y + 160, LabelWidth - 24, 25
    )
    sheet.label(font, role.notes, Margin, y + 215, LabelWidth - 28, 23)
    if role.missing.len > 0:
      sheet.label(
        bold,
        role.missing,
        Margin,
        y + 330,
        LabelWidth - 28,
        23,
        color(0.65, 0.27, 0.09)
      )
    for column, look in recipe.players:
      let
        actor = actors[row * recipe.players.len + column]
        capture = renderActor(window, scene, actor, angle, pitch)
        path = directory / role.name.slug() & "-" & look.name.slug() &
          "-" & name & ".png"
      capture.writeFile(path)
      sheet.draw(
        capture.resize(CardSize, CardSize),
        translate(vec2(
          (Margin + LabelWidth + column * CardSize).float32,
          y.float32
        ))
      )
  sheet.label(
    bold,
    "Gaps are marked on each role. All character art is existing CC0 CharGen.",
    Margin,
    sheet.height - 110,
    sheet.width - 64,
    26
  )
  sheet.label(
    font,
    "Review only. No game roster, shared asset, or animation was replaced.",
    Margin,
    sheet.height - 66,
    sheet.width - 64,
    23
  )
  sheet.writeFile(directory / (name & ".png"))
  echo directory / (name & ".png")

proc renderOverview(directory: string, recipe: Recipe) =
  ## Composes all roles and player looks into one compact review image.
  const
    PanelWidth = 984
    PanelHeight = 580
    CaptureSize = 312
    Top = 180
  let
    rows = (recipe.roles.len + 1) div 2
    sheet = newImage(Margin * 3 + PanelWidth * 2, Top + rows * PanelHeight + 90)
    font = readFont(DataPath / "fonts/Rubik-Regular.ttf")
    bold = readFont(DataPath / "fonts/Rubik-Bold.ttf")
  sheet.fill(rgba(245, 247, 250, 255))
  sheet.label(
    bold,
    "LvD / ALL " & $recipe.roles.len & " ROLES",
    Margin,
    24,
    sheet.width - 64,
    48
  )
  sheet.label(
    font,
    "Real CC0 CharGen parts in the game renderer. Shared clothing per role.",
    Margin,
    88,
    sheet.width - 64,
    28
  )
  sheet.label(
    font,
    "Each group: A Sand / round ears, B Green / elf ears, C Purple / gnome ears.",
    Margin,
    132,
    sheet.width - 64,
    25
  )
  for index, role in recipe.roles:
    let
      x = Margin + (index mod 2) * (PanelWidth + Margin)
      y = Top + (index div 2) * PanelHeight
    sheet.label(
      bold,
      $(index + 1) & ". " & role.name,
      x,
      y + 12,
      PanelWidth,
      34
    )
    sheet.label(
      font,
      "OLD: " & role.previous,
      x,
      y + 62,
      PanelWidth,
      24
    )
    for column, look in recipe.players:
      let capture = readImage(
        directory / role.name.slug() & "-" & look.name.slug() & "-roster.png"
      )
      sheet.draw(
        capture.resize(CaptureSize, CaptureSize),
        translate(vec2(
          (x + 16 + column * CaptureSize).float32,
          (y + 102).float32
        ))
      )
    sheet.label(
      font,
      role.notes.replace('\n', ' '),
      x,
      y + 428,
      PanelWidth - 24,
      25
    )
    if role.missing.len > 0:
      sheet.label(
        bold,
        role.missing,
        x,
        y + 506,
        PanelWidth - 24,
        26,
        color(0.65, 0.27, 0.09)
      )
  sheet.label(
    font,
    "Review candidates. Missing parts are left out. Gameplay is unchanged.",
    Margin,
    sheet.height - 60,
    sheet.width - 64,
    25
  )
  sheet.writeFile(directory / "overview.png")
  echo directory / "overview.png"

proc main() =
  ## Builds reproducible review presets and captures three game-rendered views.
  let
    recipe = readRecipe()
    directory = getEnv("LVD_REVIEW_OUTPUT", OutputPath)
    window = newWindow(
      "LvD CharGen review",
      ivec2(RenderSize, RenderSize),
      visible = false,
      vsync = false,
      msaa = msaa4x
    )
  var manifest = readManifest(ChargenLibrary)
  for skin in recipe.skins:
    for existing in manifest.skins:
      if existing.name == skin.name:
        raise newException(ChargenError, "Duplicate skin: " & skin.name)
    manifest.skins.add skin
  createDir(directory)
  writeFile(directory / "skin-palette.json", manifest.skins.toJson() & "\n")
  makeContextCurrent(window)
  loadExtensions()
  initSunShadows(lightRadius = 4, lightDistance = 10)
  let scene = newCharacterScene(window)
  scene.useToonShading()
  scene.setToonHour(12)
  var
    actors: seq[Actor]
    presets: seq[Preset]
  for role in recipe.roles:
    for look in recipe.players:
      let preset = manifest.makePreset(role, look)
      actors.add manifest.loadActor(preset, role.height)
      presets.add preset
      echo "Loaded ", preset.name
  writeFile(directory / "presets.json", presets.toJson() & "\n")
  for view in [
    (name: "roster", angle: 0.25'f, pitch: 0.12'f),
    (name: "side", angle: -1.0'f, pitch: 0.12'f),
    (name: "game-angle", angle: 0.50'f, pitch: 0.70'f)
  ]:
    renderSheet(
      directory,
      window,
      scene,
      recipe,
      actors,
      view.angle,
      view.pitch,
      view.name
    )
  renderOverview(directory, recipe)
  window.close()

main()
