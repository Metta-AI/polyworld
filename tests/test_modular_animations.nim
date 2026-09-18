import
  std/[math, os, tables],
  gltf, vmath,
  polyworld/animblend

const DefaultAsset = currentSourcePath().parentDir.parentDir.parentDir /
  "polyworld_data/characters/modular_chars/character.glb"

proc testLoops(path: string) =
  ## Keeps authored 30 fps endpoints and continuous wrists across loop wraps.
  let
    model = readGltfFile(path)
    player = newClipPlayer(model.root)
  var joints: Table[string, Node]
  for node in model.root.walkNodes:
    if node.name in [
      "QuickRigCharacter2_Hips",
      "QuickRigCharacter2_LeftArm", "QuickRigCharacter2_LeftForeArm",
      "QuickRigCharacter2_LeftHand", "QuickRigCharacter2_RightArm",
      "QuickRigCharacter2_RightForeArm", "QuickRigCharacter2_RightHand"
    ]:
      joints[node.name] = node
  doAssert joints.len == 7
  for (name, frames) in [("Walk", 16), ("Run", 12)]:
    let
      index = player.clipIndex(name)
      clip = model.root.animations[index]
    doAssert abs(clip.duration - frames.float32 / 30) < 0.00001,
      name & " lost its authored final frame."
    for channel in clip.channels:
      if channel.target.name notin joints:
        continue
      case channel.path
      of AnimRotation:
        let cosine = min(1.0'f, abs(dot(
          normalize(channel.valuesQuat[0]),
          normalize(channel.valuesQuat[^1])
        )))
        doAssert cosine > cos(0.1'f * PI.float32 / 360),
          name & ": discontinuous rotation on " & channel.target.name
      of AnimTranslation:
        doAssert length(channel.valuesVec3[0] -
          channel.valuesVec3[^1]) < 0.00001,
          name & ": discontinuous translation on " & channel.target.name
      else:
        discard
    player.play(name, 0)
    player.seek(clip.duration - 0.00001)
    model.root.updateTransforms()
    var before: Table[string, Vec3]
    for name, joint in joints:
      before[name] = joint.mat * vec3(0)
    player.seek(clip.duration + 0.00001)
    model.root.updateTransforms()
    for name, joint in joints:
      doAssert length(joint.mat * vec3(0) - before[name]) < 0.001,
        "The loop wrap jumps at " & name
    echo name, ": full duration and continuous arm loop."

proc run() =
  ## Tests the rebuilt original asset or an explicitly supplied candidate.
  let path =
    if paramCount() > 0:
      paramStr(1)
    else:
      DefaultAsset
  testLoops(path)

run()
