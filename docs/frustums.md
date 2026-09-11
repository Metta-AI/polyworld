# Checking whether an object is off screen

`boundsVisible(minimum, maximum, viewProjection)` checks a box around an object.
A false result means the game can skip drawing it. A true result can include
objects just outside the view, so objects at the edge do not disappear too early.

Include the object's full animated size in the box. For bounds in model space,
pass `viewProjection * model`. Use the light's matrix when checking shadows.
Inputs must be finite; an inverted box is empty and a zero-size box is valid.

Run `nim r tests/test_frustums.nim`.
