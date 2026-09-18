import
  std/[algorithm, os, random, sets, strutils, tables],
  chroma, gltf, jsony

type
  ChargenError* = object of CatchableError

  PartAlignment* = enum
    Both = "both"
    GoodOnly = "good"
    EvilOnly = "evil"

  PartItem* = object
    name*, color*: string
    alignment*: PartAlignment
    style*: int
    nodes*, hides*: seq[string]
    id*, texture*, pupilMask*, tint*: string
    files*, skinNodes*: seq[string]
    hairShades*: seq[HairShade]

  Category* = object
    key*: string
    selected*: int
    items*: seq[PartItem]
    directory*, defaultItem*: string

  ClipInfo* = object
    name*, kind*, next*, file*: string
    loop*, hold*: bool

  Skin* = object
    name*: string
    color*: array[4, float32]

  PresetPart* = object
    category*, item*: string

  Preset* = object
    name*, pose*: string
    skin*: int
    parts*: seq[PresetPart]

  HairShade* = object
    node*: string
    primitive*: int
    shade*: float32

  ColorPreset* = object
    name*: string
    rgb*: array[3, float32]

  Manifest* = object
    model*: string
    version*: int
    rig*, skeleton*, skinPalette*, hairPalette*, pupilPalette*: string
    hairColors*, pupilColors*: seq[ColorPreset]
    defaultHairColor*, defaultPupilColor*: string
    defaultAnimation*: string
    defaultSkin*: int
    base*: seq[string]
    skinNodes*: seq[string]
    hairShades*: seq[HairShade]
    categories*: seq[Category]
    clips*: seq[ClipInfo]
    skins*: seq[Skin]
    presets*: seq[Preset]

proc assetPath*(directory, path: string): string =
  ## Resolves a library-relative file while rejecting external paths.
  if path.len == 0 or path.isAbsolute or ":" in path or
    ".." in path.replace('\\', '/').split('/'):
      raise newException(ChargenError, "Invalid asset path: " & path)
  directory / path

proc readManifest*(directory: string): Manifest =
  ## Discovers independent parts and palettes in the library folders.
  try:
    result = readFile(directory / "manifest.json").fromJson(Manifest)
    if result.version != 2:
      raise newException(ChargenError, "Unsupported character library version.")
    result.skins = readFile(directory.assetPath(result.skinPalette)).
      fromJson(seq[Skin])
    result.hairColors = readFile(directory.assetPath(result.hairPalette)).
      fromJson(seq[ColorPreset])
    result.pupilColors = readFile(directory.assetPath(result.pupilPalette)).
      fromJson(seq[ColorPreset])
    if result.skins.len == 0 or result.hairColors.len == 0 or
      result.pupilColors.len == 0:
        raise newException(ChargenError, "Character palettes cannot be empty.")
    if result.defaultHairColor.len == 0:
      result.defaultHairColor = result.hairColors[0].name
    if result.defaultPupilColor.len == 0:
      result.defaultPupilColor = result.pupilColors[0].name
    var identities, names: HashSet[string]
    for category in result.categories.mitems:
      var paths: seq[string]
      for path in walkFiles(directory.assetPath(category.directory) / "*.json"):
        paths.add path
      paths.sort()
      category.items.setLen(0)
      category.selected = -1
      for path in paths:
        let item = readFile(path).fromJson(PartItem)
        if item.id.len == 0 or item.id in identities or item.files.len == 0:
          raise newException(ChargenError, "Invalid or duplicate part: " & path)
        identities.incl item.id
        for name in item.nodes:
          if name in names:
            raise newException(ChargenError, "Duplicate part node: " & name)
          names.incl name
        if item.name == category.defaultItem:
          category.selected = category.items.len
        category.items.add item
        result.skinNodes.add item.skinNodes
        result.hairShades.add item.hairShades
      if category.defaultItem.len > 0 and category.selected < 0:
        raise newException(
          ChargenError, "Missing default part: " & category.defaultItem
        )
  except IOError, JsonError:
    raise newException(
      ChargenError,
      "Cannot read parts: " & getCurrentExceptionMsg()
    )

proc colorIndex*(presets: openArray[ColorPreset], name: string): int =
  ## Finds a named palette entry without hardcoding its position or count.
  for i, item in presets:
    if cmpIgnoreCase(item.name, name) == 0:
      return i
  raise newException(ChargenError, "Unknown color preset: " & name)

proc defaultSelection*(manifest: Manifest): seq[int] =
  ## Selects the default face and leaves the ears detached.
  for category in manifest.categories:
    result.add category.selected

proc randomSelection*(
  manifest: Manifest,
  rng: var Rand,
  alignment = Both
): seq[int] =
  ## Rolls compatible parts and allows empty optional or unmatched slots.
  for category in manifest.categories:
    var choices: seq[int]
    if category.key notin ["Body", "Face", "Eyes", "Mouth", "Beard"]:
      choices.add -1
    for i, item in category.items:
      if alignment == Both or item.alignment in {Both, alignment}:
        choices.add i
    # Roll beard presence separately from the number of available styles.
    result.add:
      if choices.len == 0 or (category.key == "Beard" and rng.rand(1) == 0):
        -1
      else:
        choices[rng.rand(choices.high)]

proc applySkin*(nodes: Table[string, Node], manifest: Manifest, tint: Color) =
  ## Applies a custom color only to the library's declared skin meshes.
  for name in manifest.skinNodes:
    if name notin nodes:
      raise newException(ChargenError, "Missing skin mesh: " & name)
    for primitive in nodes[name].mesh.primitives:
      primitive.material.baseColorFactor = tint

proc applySkin*(nodes: Table[string, Node], manifest: Manifest, skin: int) =
  ## Applies a skin preset while preserving face and hair material colors.
  if skin < 0 or skin >= manifest.skins.len:
    raise newException(ChargenError, "Skin choice is outside the palette.")
  let tint = manifest.skins[skin].color
  nodes.applySkin(manifest, color(tint[0], tint[1], tint[2], tint[3]))

proc partNodes*(root: Node): Table[string, Node] =
  ## Indexes mesh nodes while excluding identically named skeleton joints.
  for node in root.walkNodes:
    if node.mesh != nil:
      if node.name in result:
        raise newException(ChargenError, "Duplicate mesh: " & node.name)
      result[node.name] = node

proc applySelection*(
  nodes: Table[string, Node],
  manifest: Manifest,
  selection: openArray[int]
) =
  ## Keeps the base and selected parts visible across animation updates.
  if selection.len != manifest.categories.len:
    raise newException(ChargenError, "Part selection has the wrong size.")
  var
    shown = manifest.base.toHashSet()
    hidden: HashSet[string]
  for i, category in manifest.categories:
    let selected = selection[i]
    if selected < -1 or selected >= category.items.len:
      raise newException(
        ChargenError, "Invalid " & category.key & " choice."
      )
    if selected >= 0:
      for name in category.items[selected].nodes:
        shown.incl name
      for name in category.items[selected].hides:
        hidden.incl name
  for name in hidden:
    shown.excl name
  for name in shown:
    if name notin nodes:
      raise newException(ChargenError, "Missing mesh: " & name)
  for name, node in nodes:
    node.visible = name in shown
    node.baseVisible = node.visible

proc selectPart*(
  manifest: Manifest,
  selection: var seq[int],
  categoryName, partName: string
) =
  ## Selects a named part or None, rejecting misspelled categories and choices.
  for i, category in manifest.categories:
    if category.key == categoryName:
      if partName == "None":
        selection[i] = -1
        return
      for j, item in category.items:
        if item.name == partName:
          selection[i] = j
          return
      raise newException(ChargenError, "Unknown part: " & partName)
  raise newException(ChargenError, "Unknown category: " & categoryName)

proc applyPreset*(
  manifest: Manifest,
  selection: var seq[int],
  preset: Preset
) =
  ## Resets all slots before applying an outfit's named choices.
  selection = manifest.defaultSelection()
  for part in preset.parts:
    manifest.selectPart(selection, part.category, part.item)

proc cycleColor*(category: Category, selected: var int) =
  ## Keeps the part style while stepping to another available color.
  if selected < 0:
    return
  let current = category.items[selected]
  for step in 1 ..< category.items.len:
    let
      index = (selected + step) mod category.items.len
      item = category.items[index]
    if item.style == current.style and item.color != current.color:
      selected = index
      return
