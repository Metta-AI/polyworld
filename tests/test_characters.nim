import
  std/os,
  gltf, vmath,
  polyworld/characters

proc close(a, b: Vec3): bool =
  length(a - b) < 0.0001'f32

echo "Testing character hand gear follows bind and animation space"
block:
  let
    dataDir = currentSourcePath.parentDir / "data"
    character = CharacterModel(
      file: readGltfFile(dataDir / "animated_hand_socket.gltf"),
      baseTransform: mat4()
    )
    scene = CharacterScene()
    gear = scene.attachGear(
      character, dataDir / "socket_gear.gltf", RightHandSlot)
    leftGear = scene.attachGear(
      character, dataDir / "socket_gear.gltf", LeftHandSlot)

  doAssert gear.file.root.hasGeometry()
  doAssert leftGear.file == gear.file
  doAssert leftGear.socketTransform(vec3(5, 0, 0), 0, 0, 0).pos.close(
    vec3(14, 22, 33))
  doAssert gear.socketTransform(vec3(5, 0, 0), 0, 0, 0).pos.close(
    vec3(16, 22, 33))
  doAssert gear.socketTransform(vec3(5, 0, 0), 0, 0, 1).pos.close(
    vec3(19, 26, 38))

  gear.file.root.updateTransforms(
    gear.socketTransform(vec3(5, 0, 0), 0, 0, 1))
  doAssert gear.file.root.nodes[0].mat.pos.close(vec3(19.25, 26, 38))

  # Cached art must not bind the second character to the first one's pose.
  let second = CharacterModel(
    file: readGltfFile(dataDir / "animated_hand_socket.gltf"),
    baseTransform: mat4())
  let secondGear = scene.attachGear(second, dataDir / "socket_gear.gltf", RightHandSlot)
  doAssert secondGear.file == gear.file
  doAssert secondGear.socketTransform(vec3(-5, 0, 0), 0, 0, 0).pos.close(vec3(6, 22, 33))
  doAssert gear.socketTransform(vec3(5, 0, 0), 0, 0, 1).pos.close(vec3(19, 26, 38))
