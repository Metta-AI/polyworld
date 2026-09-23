import
  std/[sets, tables],
  chroma,
  polyworld/[characters, chargen],
  assets, content

proc unitClip*(kind: UnitKind, slot: AnimationSlot): string =
  ## Selects an existing CC0 clip, including explicit ranged placeholders.
  case slot
  of RunAnimation:
    "Jog_Fwd_Loop"
  of DeathAnimation:
    "Death01"
  of VictoryAnimation:
    "Dance_Loop"
  of IdleAnimation:
    case kind
    of SoldierUnit, KnightUnit:
      "Sword_Idle"
    of MageUnit:
      "Spell_Simple_Idle_Loop"
    of CatapultUnit:
      "Pistol_Idle_Loop"
    else:
      "Idle_Loop"
  of AttackAnimation, AttackAlternateAnimation:
    case kind
    of PeonUnit:
      "Interact"
    of SoldierUnit, KnightUnit:
      "Sword_Attack"
    of ArcherUnit, CatapultUnit:
      "Pistol_Shoot"
    of MageUnit, ClericUnit, SummonUnit:
      "Spell_Simple_Shoot"

proc loadUnitModel*(
  manifest: Manifest,
  entry: UnitPreset,
  kind: UnitKind
): CharacterModel =
  ## Loads the approved outfit and sizes its body independently of gear.
  let
    inventory = manifest.presetManifest(entry.preset)
    height = UnitHeights[kind]
    rgb = entry.skinRgb
  result = loadCharacterModel(
    readPresetCharacter(ChargenLibrary, manifest, entry.preset, CharacterClips),
    height
  )
  let nodes = partNodes(result.file.root)
  nodes.applySkin(inventory, color(rgb[0], rgb[1], rgb[2], 1))
  var
    visibility: Table[string, bool]
    bodyNodes: HashSet[string]
  for category in inventory.categories:
    for item in category.items:
      if category.key in ["Eyes", "Mouth", "Brow"]:
        result.unlitParts.add item.nodes
      if category.key in ["Body", "Face"]:
        for name in item.nodes:
          bodyNodes.incl name
  for name, node in nodes:
    visibility[name] = node.visible
    node.visible = name in bodyNodes
    node.baseVisible = node.visible
  result.fitCharacterHeight(height, result.clipIndex("Idle_Loop"))
  for name, node in nodes:
    node.visible = visibility[name]
    node.baseVisible = node.visible
