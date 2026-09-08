# Conservative frustum queries

`boundsVisible(minimum, maximum, viewProjection)` tests rendered world bounds.
For model-local bounds, pass `viewProjection * model`. Include all shader and
animation motion in the bounds; use the sun's own matrix for shadow passes.

The query rejects a box only when every corner lies beyond one OpenGL/WebGL
clip plane (`-w..w`). It avoids perspective division, retaining near-plane
crossings and boxes enclosing the view volume. Inverted boxes are empty;
zero-volume boxes are valid. Inputs must be finite.

A relative clip tolerance retains boundary geometry and may keep some disjoint
boxes near the far plane or frustum corners. This is conservative culling, not
exact intersection or authoritative visibility.

Run `nim r tests/test_frustums.nim`. Changes to a live draw-submission path also
need a rendered comparison against an uncropped reference.
