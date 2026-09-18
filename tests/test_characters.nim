import gltf, vmath
import polyworld/[animblend, characters]

proc node(name = "", pos = vec3(0)): Node =
  Node(name: name, visible: true, baseVisible: true,
    pos: pos, basePos: pos, scale: vec3(1), baseScale: vec3(1),
    rot: quat(), baseRot: quat())

echo "Character sockets use the player's owned animated pose"
block:
  let
    root = node()
    hand = node("hand_r", vec3(1, 2, 3))
  root.nodes = @[hand]
  root.animations = @[AnimationClip(name: "move", duration: 1,
    channels: @[AnimationChannel(target: hand, path: AnimTranslation,
      interpolation: aiLinear, times: @[0'f32, 1],
      valuesVec3: @[vec3(1, 2, 3), vec3(4, 6, 8)])])]
  let
    model = CharacterModel(file: GltfFile(root: root), baseTransform: mat4())
    player = newClipPlayer(root)
  player.play(0, fade = 0)
  player.seek(1)

  let other = newClipPlayer(root)
  other.play(0, fade = 0)
  other.seek(0)
  let transform = model.handTransform(
    player, "hand_r", vec3(5, 0, 0), facing = 0)
  doAssert length(transform.pos - vec3(9, 6, 8)) < 1e-6

  let gearRoot = node("sword")
  doAssert model.attachGear(gearRoot, "hand_r").root == gearRoot

echo "Character tests passed"
