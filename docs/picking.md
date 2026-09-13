# Clicking characters and objects

`pickMesh` finds the nearest triangle hit in a model's current pose. It returns
the object, position, distance, triangle, and texture coordinates at that point.

```nim
import std/options
import gltf, vmath
import polyworld/[picking, rtscameras]

# Update the model's animation and world transforms before checking the click.
let (origin, direction) = mouseRay(pointer, viewport, projection * view)
let ray = pickRay(origin, direction)
let hit = ray.pickMesh(model.file.root)
if hit.isSome:
  echo hit.get.node.name, " ", hit.get.point
```

Check each character immediately after posing it when characters share model
data. Hidden parts are ignored. Back faces follow the material setting unless
you request a double-sided check. Texture coordinates exclude material transforms;
transparent pixels are not tested.

`mouseRay` starts at the camera's near plane, so hit distances are measured from
there. Use `pickRay` with the camera position for distances from the camera itself.
Directions are normalized and inputs must be finite.
For several objects, compare their hit distances to choose the nearest.

`pickCharacter` uses this check and keeps its double-sided selection and `-1`
result for misses. Run `nim r tests/test_picking.nim` to test it.
