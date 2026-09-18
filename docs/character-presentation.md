# Character presentation

`ClipPlayer` owns a character's playback state. Set `paused`, `timeScale`, or
call `seek`; then pass the player to `drawCharacter`, `pickCharacter`, and
`handTransform`. These calls restore its pose, so players can safely share one
loaded character model.

Gear is a separately loaded node tree attached by the skeleton node name used
by the asset (`hand_r`, `Hand_R`, and so on):

```nim
let swordFile = readGltfFile("sword.glb")
let sword = heroModel.attachGear(swordFile.root, "hand_r")
scene.drawCharacter(heroModel, player, position, facing, [sword])
```

Load gear once and reuse the resulting tree. Author its grip at the local
origin. It follows blended animation and participates in color and shadow
passes; hiding the socket or one of its ancestors also hides the gear.
