# Culling presentation bounds

`polyworld/frustums.boundsVisible(minimum, maximum, viewProjection)` provides
the conservative bounds query needed by terrain chunks, prop instance groups,
particles, and overlays. It is extracted from Cogcraft's terrain/decoration
visibility query so games need not import its terrain renderer to use it.

For a model-local box, pass `viewProjection * model`. For an already transformed
world-space box, pass `viewProjection`. Bounds must enclose every rendered
vertex, including wind, skinning, skirts, and particle expansion. Animation or
geometry changes must update the caller's bounds.

The query uses the OpenGL/WebGL clip range `-w..w` on all three axes. It does
not divide by W, so boxes crossing the near plane remain conservative. A box
enclosing the view volume is retained even when none of its corners is visible.
Empty inverted boxes are rejected; zero-volume boxes are supported.

This is six-plane conservative rejection, not exact box/frustum intersection.
It may retain some disjoint boxes near frustum corners. A small relative clip
tolerance avoids rejecting boundary geometry due to floating-point error.
It does not perform occlusion culling or change simulation visibility. Pass the
sun's own view-projection for shadow draws rather than reusing camera results.

Run `nim r tests/test_frustums.nim` for six-plane, near-plane, transformed-box,
orthographic and perspective containment fixtures. Integration into a live draw
submission path still needs a render proof against an uncropped reference.
