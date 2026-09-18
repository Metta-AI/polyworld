import math

from beards import jaw, surface


def moustache(hair, spread=.31, drop=.085, fullness=.064):
  """Form two broad tapered moustache wings around the visible mouth."""
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .018, 2.175, .028),
       surface(sign * .12, 2.157, .060),
       surface(sign * .235, 2.125, .072),
       surface(sign * spread, 2.175 - drop, .045)],
      [.037, fullness, fullness * .76, .011],
      [.024, .045, .038, .01],
      normal=(0, -1, 0),
      sides=7,
    )


def band(hair, x, y, z, width=.10, depth=.085):
  """Wrap a plain dark band around a firmly connected beard tassel."""
  hair.lock(
    [(x, y, z + .048), (x, y, z + .030),
     (x, y, z - .030), (x, y, z - .048)],
    [width * .93, width, width, width * .93],
    [depth * .93, depth, depth, depth * .93],
    normal=(0, -1, 0), sides=8, steps=1, material=3,
  )


def twinTassels(hair):
  """Build a divided full beard that ends in two tied pointed tassels."""
  jaw(
    hair,
    top=lambda theta: 2.067 + .285 * abs(math.sin(theta)) ** 3,
    bottom=lambda theta: 2.053 - .275 * math.sin(2 * theta) ** 2,
    width=.445, depth=.495, centerY=-.005, thickness=.075,
  )
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .405, 2.245, .022),
       (sign * .37, -.405, 2.065),
       (sign * .285, -.505, 1.91),
       (sign * .275, -.525, 1.765)],
      [.028, .112, .138, .074],
      [.022, .062, .097, .067],
      normal=(sign * .24, -.97, 0),
    )
    hair.lock(
      [surface(sign * .135, 2.07, .026),
       (sign * .21, -.530, 1.965),
       (sign * .27, -.54, 1.82),
       (sign * .275, -.525, 1.735)],
      [.043, .112, .103, .068],
      [.032, .065, .073, .061],
      normal=(0, -1, 0),
    )
    hair.lock(
      [(sign * .275, -.525, 1.75),
       (sign * .282, -.545, 1.625),
       (sign * .280, -.548, 1.565),
       (sign * .265, -.532, 1.455)],
      [.068, .115, .112, .009],
      [.061, .095, .091, .009],
      normal=(0, -1, 0), sides=7, steps=2,
    )
    band(hair, sign * .275, -.525, 1.748, .098, .091)
  moustache(hair, spread=.315, drop=.105, fullness=.065)


def fan(hair, z, width, depth, drop, rise, mouth=False):
  """Overlap three broad pointed clumps into one irregular fan tier."""
  hair.lock(
    [(0, -depth + .045, z + (.025 if mouth else .085)),
     (0, -depth - .020, z - .020),
     (.012, -depth + .015, z - drop)],
    [width * .26, width * .56, .013],
    [.020 if mouth else .045, .070, .011],
    normal=(0, -1, 0), sides=6, steps=2,
  )
  for sign in [-1, 1]:
    hair.lock(
      [(sign * width * (.40 if mouth else .24),
        -depth + .04, z + (.025 if mouth else .10)),
       (sign * width * .60, -depth + .015, z + .02 + rise * .25),
       (sign * width * .96, -depth + .105, z - drop + rise)],
      [width * .08, width * .28, .012],
      [.032, .065, .010], normal=(0, -1, 0), sides=6, steps=2,
    )


def tieredFan(hair):
  """Build three broad overlapping pointed tiers under a full moustache."""
  jaw(
    hair,
    top=lambda theta: 2.025 + .205 * abs(math.sin(theta)) ** 3,
    bottom=lambda theta: 1.655 + .34 * abs(math.sin(theta)) ** 2,
    width=.355, depth=.47, centerY=-.025, thickness=.075, extent=1.13,
  )
  fan(hair, 1.775, .295, .495, .17, .19)
  fan(hair, 1.900, .435, .525, .17, .20)
  fan(hair, 1.985, .535, .540, .145, .18, mouth=True)
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .43, 2.215, .015),
       (sign * .445, -.305, 2.135),
       (sign * .530, -.345, 2.06)],
      [.061, .105, .011], [.036, .070, .010],
      normal=(sign * .5, -.86, 0), sides=6,
    )
    hair.lock(
      [surface(sign * .020, 2.175, .03),
       (sign * .13, -.575, 2.145),
       (sign * .23, -.590, 2.075),
       (sign * .335, -.565, 2.005)],
      [.038, .079, .067, .013], [.027, .049, .042, .011],
      normal=(0, -1, 0), sides=7,
    )


def tiedJaw(hair):
  """Build a clean jaw beard with an open upper lip and one short tassel."""
  jaw(
    hair,
    top=lambda theta: 2.05 + .302 * abs(math.sin(theta)) ** 3,
    bottom=lambda theta: 1.91 + .135 * abs(math.sin(theta)) ** 2,
    width=.44, depth=.49, centerY=-.012, thickness=.067,
  )
  hair.lock(
    [surface(0, 2.065, .028), (0, -.514, 2.00),
     (0, -.535, 1.925), (0, -.535, 1.845)],
    [.086, .125, .119, .078],
    [.04, .065, .079, .066],
    normal=(0, -1, 0), sides=7,
  )
  hair.lock(
    [(0, -.535, 1.84), (0, -.550, 1.74),
     (0, -.555, 1.665), (0, -.540, 1.58)],
    [.071, .112, .123, .012],
    [.065, .084, .086, .01],
    normal=(0, -1, 0), sides=7, steps=2,
  )
  band(hair, 0, -.535, 1.845, .105, .088)


def windswept(hair):
  """Sweep broad beard locks across the chin toward one pointed side."""
  jaw(
    hair,
    top=lambda theta: 2.055 + .205 * abs(math.sin(theta)) ** 3,
    bottom=lambda theta: (
      1.88 + .155 * abs(math.sin(theta)) ** 2 +
      .15 * (abs(theta) / 1.14) ** 8
    ),
    width=lambda theta: .415 + .070 * (abs(theta) / 1.14) ** 5,
    depth=.48, centerY=-.015, thickness=.070, extent=1.14,
  )
  hair.lock(
    [surface(-.43, 2.205, .016), (-.415, -.360, 2.11),
     (-.29, -.51, 1.94), (-.115, -.525, 1.77)],
    [.058, .115, .108, .012],
    [.034, .066, .060, .01], normal=(0, -1, 0), sides=7,
  )
  hair.lock(
    [surface(-.245, 2.08, .025), (-.20, -.548, 1.995),
     (.025, -.59, 1.79), (.29, -.54, 1.625)],
    [.048, .165, .162, .011],
    [.032, .08, .096, .01], normal=(0, -1, 0), sides=7,
  )
  hair.lock(
    [(-.005, -.495, 2.01), (.075, -.56, 1.92),
     (.255, -.59, 1.80), (.445, -.515, 1.715)],
    [.045, .139, .135, .011],
    [.030, .075, .081, .01], normal=(0, -1, 0), sides=7,
  )
  hair.lock(
    [surface(.03, 2.075, .028), (.175, -.557, 2.025),
     (.375, -.58, 1.90), (.625, -.475, 1.885)],
    [.046, .141, .130, .011],
    [.031, .073, .079, .01], normal=(0, -1, 0), sides=7,
  )
  hair.lock(
    [surface(.345, 2.205, .02), (.44, -.34, 2.13),
     (.585, -.29, 2.075)],
    [.031, .095, .011], [.023, .06, .01],
    normal=(.2, -.98, 0), sides=7,
  )
  hair.lock(
    [surface(.32, 2.08, .03), (.445, -.405, 2.03),
     (.635, -.325, 1.985)],
    [.04, .10, .011], [.028, .06, .01],
    normal=(.2, -.98, 0), sides=7,
  )
  moustache(hair, spread=.325, drop=.09, fullness=.067)


def build(style, hair):
  """Build the assigned closed facial-hair mesh on the shared head."""
  if style == 13:
    twinTassels(hair)
  elif style == 14:
    tieredFan(hair)
  elif style == 15:
    tiedJaw(hair)
  elif style == 16:
    windswept(hair)
