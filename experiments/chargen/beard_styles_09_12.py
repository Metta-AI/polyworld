"""Closed tapered, spade, Van Dyke, and single-tassel facial hair."""

import math

from beards import jaw, surface


def moustache(hair, width=.39):
  """Wrap two broad tapered moustache halves around the upper lip."""
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .018, 2.196, .022),
       surface(sign * .110, 2.180, .047),
       surface(sign * width * .70, 2.132, .055),
       surface(sign * width, 2.110, .040)],
      [.026, .070, .072, .012],
      [.022, .046, .047, .010],
      normal=(0, -1, 0),
      sides=8,
      steps=4,
    )


def taperedWedge(hair):
  """Build a full pointed beard with broad overlapping diagonal layers."""
  jaw(
    hair,
    top=lambda theta: 2.043 + .315 * abs(math.sin(theta)) ** 3,
    bottom=lambda theta: 1.61 + .50 * abs(math.sin(theta)) ** 1.65,
    width=lambda theta: .19 + .27 * abs(math.sin(theta)),
    depth=.49,
    centerY=.005,
    thickness=.065,
  )
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .473, 2.300, -.012),
       surface(sign * .426, 2.162, .022),
       (sign * .355, -.354, 2.062),
       (sign * .285, -.396, 1.930)],
      [.012, .082, .090, .010],
      [.010, .043, .043, .009],
      normal=(sign * .40, -1, 0),
      sides=8,
      steps=4,
    )
    hair.lock(
      [surface(sign * .245, 2.059, -.010),
       (sign * .245, -.464, 1.980),
       (sign * .185, -.510, 1.820),
       (sign * .115, -.492, 1.687)],
      [.012, .113, .094, .010],
      [.009, .053, .047, .008],
      normal=(0, -1, 0),
      sides=8,
      steps=4,
    )
  hair.lock(
    [surface(0, 2.046, -.008),
     (0, -.505, 1.990),
     (0, -.539, 1.853),
     (0, -.515, 1.720)],
    [.013, .154, .127, .012],
    [.010, .069, .063, .009],
    normal=(0, -1, 0),
    sides=8,
    steps=4,
  )
  moustache(hair)


def spade(hair):
  """Keep a square cheek outline and a broad blunt chin shelf."""
  def bottom(theta):
    """Flatten the front hem and round the two outer jaw corners."""
    corner = max(0, (abs(math.sin(theta)) - .78) / .22)
    return 1.82 + .235 * corner ** 1.4

  jaw(
    hair,
    top=lambda theta: 2.046 + .335 * abs(math.sin(theta)) ** 3,
    bottom=bottom,
    width=.448,
    depth=.480,
    centerY=.008,
    thickness=.075,
  )
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .476, 2.337, -.008),
       (sign * .469, -.206, 2.176),
       (sign * .432, -.288, 2.010),
       (sign * .361, -.344, 1.899)],
      [.013, .065, .073, .013],
      [.009, .038, .041, .010],
      normal=(sign * .45, -1, 0),
      sides=8,
      steps=4,
    )
  for i in [-1, 0, 1]:
    x = i * .177
    hair.lock(
      [surface(x, 2.051, -.007),
       (x, -.491 + abs(i) * .018, 1.991),
       (x * .98, -.503 + abs(i) * .021, 1.887),
       (x * .94, -.481 + abs(i) * .021, 1.822)],
      [.012, .118, .110, .080],
      [.009, .044, .043, .031],
      normal=(0, -1, 0),
      sides=8,
      steps=3,
    )
  moustache(hair, .385)


def vanDyke(hair):
  """Separate an upturned moustache from a small pointed chin diamond."""
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .016, 2.183, .020),
       surface(sign * .118, 2.169, .034),
       surface(sign * .242, 2.133, .037),
       surface(sign * .316, 2.143, .036),
       surface(sign * .342, 2.206, .022)],
      [.019, .043, .048, .032, .008],
      [.014, .027, .029, .022, .008],
      normal=(0, -1, 0),
      sides=8,
      steps=4,
    )
  hair.lock(
    [surface(0, 2.048, -.004),
     (0, -.466, 1.997),
     (0, -.469, 1.900),
     (0, -.439, 1.782),
     (0, -.407, 1.709)],
    [.018, .108, .094, .045, .008],
    [.014, .068, .059, .035, .008],
    normal=(0, -1, 0),
    sides=8,
    steps=4,
  )


def singleTassel(hair):
  """Gather a continuous full jaw beard into one tied pointed tassel."""
  jaw(
    hair,
    top=lambda theta: 2.038 + .400 * abs(math.sin(theta)) ** 4,
    bottom=lambda theta: 1.881 + .165 * abs(math.sin(theta)) ** 2,
    width=.425,
    depth=.440,
    centerY=.004,
    extent=1.62,
    thickness=.066,
  )
  for sign in [-1, 1]:
    hair.lock(
      [surface(sign * .485, 2.402, -.010),
       surface(sign * .468, 2.236, .020),
       (sign * .374, -.330, 2.073),
       (sign * .247, -.407, 1.943),
       (sign * .095, -.438, 1.858)],
      [.012, .048, .084, .075, .012],
      [.009, .028, .046, .044, .009],
      normal=(sign * .25, -1, 0),
      sides=8,
      steps=4,
    )
    hair.lock(
      [surface(sign * .207, 2.043, -.007),
       (sign * .170, -.466, 1.993),
       (sign * .119, -.477, 1.899),
       (sign * .047, -.446, 1.814)],
      [.012, .096, .075, .025],
      [.009, .049, .044, .021],
      normal=(0, -1, 0),
      sides=8,
      steps=4,
    )
  hair.lock(
    [surface(0, 2.046, -.004),
     (0, -.493, 1.991),
     (0, -.493, 1.886),
     (0, -.450, 1.787)],
    [.012, .135, .113, .082],
    [.009, .058, .057, .052],
    normal=(0, -1, 0),
    sides=8,
    steps=4,
  )
  hair.lock(
    [(0, -.45, 1.805),
     (0, -.45, 1.733),
     (0, -.447, 1.638),
     (0, -.440, 1.565),
     (0, -.433, 1.497)],
    [.070, .082, .132, .081, .009],
    [.049, .055, .082, .054, .008],
    normal=(0, -1, 0),
    sides=8,
    steps=4,
  )
  hair.ring(
    (0, -.450, 1.790),
    radius=.084,
    thickness=.029,
    normal=(0, 0, 1),
    material=3,
  )
  moustache(hair, .357)


def build(style, hair):
  """Build one of facial hairstyles nine through twelve."""
  if style == 9:
    taperedWedge(hair)
  elif style == 10:
    spade(hair)
  elif style == 11:
    vanDyke(hair)
  elif style == 12:
    singleTassel(hair)
  else:
    raise ValueError("Unsupported facial hairstyle: " + str(style))
