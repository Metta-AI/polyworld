# Picking visible game art

`polyworld/picking` queries the current glTF pose without a graphics context.
It is useful for actor selection, model inspection, and locating an effect on
the surface of a displayed mesh. Gameplay still validates the resulting
selection through the game's authoritative command path.

```nim
import std/options
import gltf, vmath
import polyworld/picking

# After the normal animation and world-transform update:
let ndc = vec2(pointer.x / viewport.x * 2 - 1,
  1 - pointer.y / viewport.y * 2)
let ray = pickRayFromScreen(projection * view, ndc)
let hit = ray.pickMesh(model.file.root)
if hit.isSome:
  let selected = hit.get
  echo selected.node.name, " ", selected.point
```

Query the same posed root and world transforms used for drawing. When character
draws share one mutable model, query each instance immediately after posing it.
`pickMesh` does not change animation, transforms, materials, or the simulation.
For several independent roots, compare the returned world-space distances; the
nearest returned hit is the selected presentation object.

The query supports indexed and non-indexed triangle meshes, current morphed
points, skin matrices, material back-face settings (or an explicit double-sided query), and interpolated UVs. An
invisible node excludes its subtree. Equal-distance triangles retain traversal
order. UVs are mesh coordinates before material texture transforms.

Rays made from a view-projection matrix start at the near plane, for both
perspective and orthographic views. Their distance is measured from that plane,
not the camera eye. For eye-relative distance limits, use `pickRay` with the
eye position and desired direction. Both constructors normalize direction.

This is a nearest-triangle CPU query: it does not sample texture alpha, interpret
point/line/strip/fan primitives, perform occlusion queries, or allocate a spatial
acceleration structure. It trusts validated glTF indices and skin arrays. World
positions, distances and meshes must be finite, and the projection must be
invertible with finite clip planes. Games with large scenery sets should filter
candidate roots using their existing scene visibility or spatial owner first.

Run the headless behavioral fixture with `nim r tests/test_picking.nim`.

`pickCharacter` uses this query after its normal pose update, retaining its
legacy double-sided selection and `-1` miss result.
