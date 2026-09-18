import
  std/[os, sets, tables],
  chroma, gltf, jsony

type
  BlenderCharsError* = object of CatchableError

  PartItem* = object
    name*, color*: string
    style*: int
    nodes*, hides*: seq[string]

  Category* = object
    key*: string
    selected*: int
    items*: seq[PartItem]

  ClipInfo* = object
    name*, kind*, next*: string
    loop*: bool

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

  Manifest* = object
    model*: string
    defaultSkin*: int
    base*: seq[string]
    skinNodes*: seq[string]
    hairShades*: seq[HairShade]
    categories*: seq[Category]
    clips*: seq[ClipInfo]
    skins*: seq[Skin]
    presets*: seq[Preset]

proc readManifest*(directory: string): Manifest =
  ## Reads the generated part and animation definitions.
  try:
    result = readFile(directory / "manifest.json").fromJson(Manifest)
  except IOError, JsonError:
    raise newException(
      BlenderCharsError,
      "Cannot read parts: " & getCurrentExceptionMsg()
    )

proc defaultSelection*(manifest: Manifest): seq[int] =
  ## Selects the default face and leaves the ears detached.
  for category in manifest.categories:
    result.add category.selected

proc applySkin*(nodes: Table[string, Node], manifest: Manifest, skin: int) =
  ## Tints explicit skin meshes without depending on imported material names.
  if skin < 0 or skin >= manifest.skins.len:
    raise newException(BlenderCharsError, "Skin choice is outside the palette.")
  let tint = manifest.skins[skin].color
  for name in manifest.skinNodes:
    if name notin nodes:
      raise newException(BlenderCharsError, "Missing skin mesh: " & name)
    for primitive in nodes[name].mesh.primitives:
      primitive.material.baseColorFactor = color(
        tint[0], tint[1], tint[2], tint[3]
      )

proc partNodes*(root: Node): Table[string, Node] =
  ## Indexes mesh nodes while excluding identically named skeleton joints.
  for node in root.walkNodes:
    if node.mesh != nil:
      if node.name in result:
        raise newException(BlenderCharsError, "Duplicate mesh: " & node.name)
      result[node.name] = node

proc applySelection*(
  nodes: Table[string, Node],
  manifest: Manifest,
  selection: openArray[int]
) =
  ## Keeps the base and selected parts visible across animation updates.
  if selection.len != manifest.categories.len:
    raise newException(BlenderCharsError, "Part selection has the wrong size.")
  var
    shown = manifest.base.toHashSet()
    hidden: HashSet[string]
  for i, category in manifest.categories:
    let selected = selection[i]
    if selected < -1 or selected >= category.items.len:
      raise newException(
        BlenderCharsError, "Invalid " & category.key & " choice."
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
      raise newException(BlenderCharsError, "Missing mesh: " & name)
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
      raise newException(BlenderCharsError, "Unknown part: " & partName)
  raise newException(BlenderCharsError, "Unknown category: " & categoryName)

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
