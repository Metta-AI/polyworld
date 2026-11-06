## Native CharGen model integration: ordinary and wood-axe peons stay distinct.
import
  std/[sets, tables],
  gltf, vmath,
  polyworld/[characters, chargen],
  ../[appearances, assets, content, factions]

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([Emerald, WetAsphalt])
var cache: UnitModelCache
for player in 0 .. 1:
  let
    entry = roster.players[player][PeonUnit.ord]
    ordinary = cache.loadUnitModel(manifest, entry, PeonUnit)
    wood = cache.loadUnitModel(manifest, entry, PeonUnit, woodAxe = true)
    nodes = partNodes(wood.file.root)
  doAssert ordinary != wood
  doAssert wood == cache.loadUnitModel(manifest, entry, PeonUnit, woodAxe = true)
  doAssert ordinary == cache.loadUnitModel(manifest, entry, PeonUnit)
  doAssert "GotaWeapon_berserker_right_hand" in nodes
  let axe = nodes["GotaWeapon_berserker_right_hand"]
  doAssert axe.visible and axe.skin != nil
  var socket = -1
  for i, joint in axe.skin.joints:
    if joint.name == "RightHand": socket = i
  doAssert socket >= 0
  for primitive in axe.mesh.primitives:
    for vertex, weights in primitive.jointWeights:
      for i in 0 ..< 4:
        if weights[i] > 0.0001:
          doAssert primitive.jointIds[vertex][i].int == socket
  let ordinaryNodes = partNodes(ordinary.file.root)
  for name, node in ordinaryNodes:
    doAssert name in nodes
    doAssert nodes[name].visible == node.visible
    for i, primitive in node.mesh.primitives:
      doAssert nodes[name].mesh.primitives[i].points == primitive.points
  doAssert wood.mergedMeshes.len == 1
  doAssert wood.clipDuration(wood.clipIndex("Sword_Attack")) > 0
  var ownNodes: HashSet[pointer]
  for node in wood.file.root.walkNodes:
    ownNodes.incl cast[pointer](node)
  for joint in wood.mergedMeshes[0].skin.joints:
    doAssert cast[pointer](joint) in ownNodes
  for name in manifest.presetManifest(entry.preset).skinNodes:
    let tint = nodes[name].mesh.primitives[0].material.baseColorFactor
    doAssert tint.r == entry.skinRgb[0] and tint.g == entry.skinRgb[1] and
      tint.b == entry.skinRgb[2]
  echo "wood axe peon ", player, " model and cache passed"

let original = roster.players[0][PeonUnit.ord]
var recolored = original
recolored.skinRgb = [0.21'f, 0.42'f, 0.73'f]
var freshEntry = recolored
freshEntry.preset = woodAxePreset(original.preset)
let
  cached = cache.loadUnitModel(manifest, recolored, PeonUnit, woodAxe = true)
  fresh = loadUnitModel(manifest, freshEntry, PeonUnit)
  cachedNodes = partNodes(cached.file.root)
  freshNodes = partNodes(fresh.file.root)
doAssert cached.mergedMeshes.len == 1 and fresh.mergedMeshes.len == 1
for i, primitive in cached.mergedMeshes[0].mesh.primitives:
  doAssert primitive.colors == fresh.mergedMeshes[0].mesh.primitives[i].colors
for name, node in cachedNodes:
  doAssert node.visible == freshNodes[name].visible
  for i, primitive in node.mesh.primitives:
    doAssert primitive.material.baseColorFactor ==
      freshNodes[name].mesh.primitives[i].material.baseColorFactor
for clipName in CharacterClips:
  let clip = cached.clipIndex(clipName)
  doAssert cached.clipDuration(clip) > 0
  for model in [cached, fresh]:
    model.file.root.activeClips = @[clip]
    model.file.root.animTime = model.clipDuration(clip) * 0.3'f
    model.file.root.updateAnimation(0)
    model.file.root.updateTransforms(model.baseTransform)
  for name, node in cachedNodes:
    doAssert node.mat == freshNodes[name].mat
    doAssert cached.file.root.skinMatrices(node) ==
      fresh.file.root.skinMatrices(freshNodes[name])
echo "wood axe cached colors and animations match fresh model"
