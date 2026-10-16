import
  gltf, vmath,
  polyworld/[characters, chargen],
  ../examples/gods_of_the_arena/[assets, content, faces]

const Clips = @HeroClips & @["Dance_Loop"]

proc vertex(
  owner: Node, primitive: Primitive, matrices: openArray[Mat4], i: int
): Vec3 =
  ## Evaluates the existing CPU skinning formula for an animation sample.
  var point = primitive.points[i]
  if owner.skin != nil:
    point = vec3(0)
    for component in 0 ..< 4:
      point += matrices[primitive.jointIds[i][component].int] *
        primitive.points[i] * primitive.jointWeights[i][component]
  owner.mat * point

proc verify(preset: Preset, library: Manifest) =
  ## Compares every merged vertex with its original animated source parts.
  let
    inventory = library.presetManifest(preset)
    file = readPresetCharacter(ChargenLibrary, library, preset, Clips)
    model = loadCharacterModel(file, 1)
  for category in inventory.categories:
    if category.key in ["Eyes", "Mouth", "Brow"]:
      for item in category.items:
        model.unlitParts.add item.nodes
  var eyes = initDeathEyes(model, ChargenLibrary, inventory,
    library.deathEyesPart())
  eyes.merge()
  for dead in [false, true]:
    eyes.setDead(dead)
    let merged = model.mergedMeshes[model.mergedMesh]
    doAssert merged.mesh.primitives.len <= 2
    for name in Clips:
      let clip = model.clipIndex(name)
      for time in [0'f, model.clipDuration(clip) / 2]:
        file.root.activeClips = @[clip]
        file.root.animTime = time
        file.root.updateAnimation(0)
        file.root.updateTransforms(translate(vec3(3, 1, -2)) * rotateY(0.7'f))
        merged.mat = file.root.mat
        let mergedMatrices = file.root.skinMatrices(merged)
        var offsets: array[2, int]
        for owner in file.root.walkNodes:
          if not owner.visible or owner.mesh == nil:
            continue
          let matrices = file.root.skinMatrices(owner)
          for source in owner.mesh.primitives:
            let group = (source.material.alphaMode == BlendAlphaMode).ord
            let combined = merged.mesh.primitives[group]
            for i in 0 ..< source.points.len:
              doAssert length(vertex(owner, source, matrices, i) -
                vertex(merged, combined, mergedMatrices, offsets[group])) <
                  0.0001,
                  preset.name & " " & owner.name & " " & name
              doAssert source.jointWeights[i] ==
                combined.jointWeights[offsets[group]]
              var sourceNormal, mergedNormal: Vec3
              for component in 0 ..< 4:
                sourceNormal += (
                  matrices[source.jointIds[i][component].int] *
                    vec4(source.normals[i], 0)
                ).xyz * source.jointWeights[i][component]
                mergedNormal += (
                  mergedMatrices[combined.jointIds[
                    offsets[group]][component].int] *
                      vec4(combined.normals[offsets[group]], 0)
                ).xyz * combined.jointWeights[offsets[group]][component]
              doAssert length(
                normalize(owner.mat.normalMatrix * sourceNormal) -
                  normalize(merged.mat.normalMatrix * mergedNormal)
              ) < 0.0001, preset.name & " " & owner.name & " normal"
              inc offsets[group]
  echo preset.name, ": vertices, joints, animations and both faces match; ",
    model.mergedMeshes[0].mesh.primitives.len, " draws."

let library = readManifest(ChargenLibrary)
for name in HeroPresets:
  verify(library.namedPreset(name), library)
for name in GodPresets:
  verify(library.namedPreset(name), library)
for team in 0 ..< CreepPresets.len:
  for kind in CreepKind:
    verify(library.creepPreset(team, kind), library)
for recipe in neutralRecipes():
  verify(recipe.preset, library)
