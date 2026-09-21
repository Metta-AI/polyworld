import
  std/tables,
  gltf,
  polyworld/[characters, chargen]

type DeathEyes* = object
  living*, dead*: seq[Node]

proc setDead*(eyes: DeathEyes, dead: bool) =
  ## Selects eyes for this instance before posing a shared character model.
  for node in eyes.living:
    node.baseVisible = not dead
    node.visible = not dead
  for node in eyes.dead:
    node.baseVisible = dead
    node.visible = dead

proc initDeathEyes*(
  model: CharacterModel,
  directory: string,
  inventory: Manifest,
  replacement: PartItem
): DeathEyes =
  ## Attaches one reusable death expression to a character with eyes.
  let living = partNodes(model.file.root)
  for category in inventory.categories:
    if category.key == "Eyes":
      for item in category.items:
        for name in item.nodes:
          result.living.add living[name]
  if result.living.len == 0:
    return
  for path in replacement.files:
    model.file.root.attachPart(directory, path)
  let nodes = partNodes(model.file.root)
  for name in replacement.nodes:
    result.dead.add nodes[name]
    model.file.skins.add nodes[name].skin
    model.unlitParts.add name
  result.setDead(false)
