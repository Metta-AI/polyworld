import math


def sweptPanels(hair, profile, hem, top, panels, puff, relief):
  """Lay broad closed panels directly against the scalp surface."""
  def radius(z):
    """Interpolate the same radial profile used by the cap."""
    for a, b in zip(profile, profile[1:]):
      if z <= b[0]:
        t = max(0.0, (z - a[0]) / (b[0] - a[0]))
        return tuple(a[i] + (b[i] - a[i]) * t for i in range(1, 4))
    return profile[-1][1:]

  for start, end, width in panels:
    vertices = []
    for layer in range(2):
      for row in range(10):
        t = row / 9
        progress = .035 + .965 * t
        center = start + (end - start) * progress
        for column in range(5):
          u = column / 4
          theta = center + (u * 2 - 1) * width
          z = top + (hem(theta) - top) * progress
          x, y, centerY = radius(z)
          ridge = relief * math.sin(math.pi * u) ** .7
          ridge *= max(0.0, math.sin(math.pi * t)) ** .65
          offset = puff + .002 + ridge if layer == 0 else puff - .012
          sx, sy = math.sin(theta), math.cos(theta)
          vertices.append(((x + offset) * math.copysign(abs(sx) ** .88, sx),
                           centerY - (y + offset) * math.copysign(abs(sy) ** .88, sy),
                           z))
    faces = []
    for row in range(9):
      for column in range(4):
        a = row * 5 + column
        faces.append((a, a + 1, a + 6, a + 5))
        faces.append((a + 50, a + 55, a + 56, a + 51))
    boundary = list(range(5))
    boundary += [row * 5 + 4 for row in range(1, 10)]
    boundary += list(range(48, 44, -1))
    boundary += [row * 5 for row in range(8, 0, -1)]
    for i, a in enumerate(boundary):
      b = boundary[(i + 1) % len(boundary)]
      faces.append((a, a + 50, b + 50, b))
    hair.mesh(vertices, faces)


def twists(hair):
  """Build short forward twists over a close, continuous scalp."""
  profile = [(2.25, .485, .49, .02), (2.55, .51, .525, .02),
             (2.79, .485, .48, .02), (2.96, .425, .39, .02),
             (3.065, .29, .26, .02), (3.11, .06, .06, .02)]
  hair.cap(front=2.79, side=2.44, back=2.27, top=3.11,
           puff=.025, profile=profile)
  heights = (2.835, 2.775, 2.82, 2.755, 2.815, 2.79, 2.84)
  shifts = (-.025, -.045, -.015, -.04, .01, -.015, .005)
  for i, x in enumerate((-.44, -.30, -.15, .015, .18, .34, .46)):
    edge = abs(x) / .46
    hair.lock(
      [(x + .035, .065, 3.035 - edge * .08),
       (x + .025, -.17, 3.105 - edge * .085),
       (x + shifts[i], -.395, 2.96 - edge * .05),
       (x + shifts[i] - .025, -.525, heights[i])],
      [.055, .104 - edge * .017, .102 - edge * .017, .027],
      [.06, .09, .083, .025],
      normal=(0, -1, .4),
      sides=7,
      steps=3,
      material=1 if i == 2 else 0)
  for i, x in enumerate((-.35, -.17, .02, .21, .37)):
    edge = abs(x) / .4
    hair.lock(
      [(x, .35 - edge * .07, 2.90 - edge * .08),
       (x + .025, .23, 3.07 - edge * .085),
       (x, .025, 3.145 - edge * .08),
       (x - .04, -.085, 3.06 - edge * .07)],
      [.048, .097, .092, .027],
      [.062, .094, .081, .026],
      normal=(0, 0, 1),
      sides=7,
      material=0)


def bob(hair):
  """Build a side-parted bob with one long sweeping front panel."""
  def hem(theta):
    """Keep the long side and back low while exposing the short temple."""
    front = max(0.0, math.cos(theta))
    right = max(0.0, math.sin(theta))
    if 0.0 <= theta <= math.pi / 2:
      return 2.53 + .24 * math.cos(theta) + .095 * math.sin(theta * 2)
    return 2.12 + .65 * front ** 3 + .41 * right ** 4

  profile = [
    (2.00, .30, .29, .065),
    (2.13, .44, .39, .06),
    (2.30, .53, .455, .045),
    (2.54, .565, .48, .035),
    (2.80, .55, .475, .025),
    (3.025, .415, .355, .02),
    (3.14, .16, .15, .005),
    (3.175, 0.0, 0.0, 0.0)]
  hair.cap(
    hem=hem,
    profile=profile,
    top=3.175,
    puff=.025,
    segments=56,
    rings=12)
  hair.lock(
    [(.17, -.235, 3.095),
     (-.075, -.445, 3.015),
     (-.365, -.525, 2.79),
     (-.475, -.52, 2.48),
     (-.475, -.455, 2.125)],
    [.075, .178, .17, .125, .012],
    [.055, .09, .094, .07, .012],
    normal=(0, -1, 0),
    sides=8,
    steps=4)
  hair.lock(
    [(.19, -.135, 3.135),
     (-.115, -.30, 3.145),
     (-.425, -.38, 2.94),
     (-.57, -.31, 2.58),
     (-.52, -.225, 2.175)],
    [.06, .155, .153, .12, .016],
    [.044, .067, .075, .064, .016],
    normal=(-.3, -1, 0),
    sides=8,
    steps=4)
  hair.lock(
    [(.21, -.16, 3.095),
     (.355, -.23, 2.99),
     (.48, -.16, 2.78),
     (.495, -.035, 2.54)],
    [.055, .095, .084, .02],
    [.039, .053, .051, .02],
    normal=(1, -.5, 0),
    sides=8)
  sweptPanels(hair, profile, hem, 3.175,
              [(2.31, 2.59, .43), (3.06, 3.39, .43),
               (3.81, 4.14, .43)], .025, .06)


def dutch(hair):
  """Build a raised centered Dutch braid with swept sides and a short tail."""
  hair.cap(front=2.79, side=2.42, back=2.29, top=3.09, puff=.035)
  for sign in (-1, 1):
    hair.lock(
      [(sign * .31, -.465, 2.745),
       (sign * .245, -.36, 2.965),
       (sign * .115, -.13, 3.08)],
      [.061, .13, .065],
      [.058, .079, .045],
      normal=(0, -1, .6),
      sides=8)
    hair.lock(
      [(sign * .49, -.22, 2.50),
       (sign * .51, -.175, 2.745),
       (sign * .42, .02, 2.97),
       (sign * .13, .18, 3.11)],
      [.037, .11, .14, .068],
      [.03, .068, .075, .045],
      normal=(sign, -.25, .3),
      sides=8)
    hair.lock(
      [(sign * .50, .095, 2.405),
       (sign * .51, .20, 2.67),
       (sign * .37, .345, 2.88),
       (sign * .10, .415, 2.975)],
      [.029, .108, .126, .061],
      [.025, .058, .073, .045],
      normal=(sign, 1, 0),
      sides=8)
    hair.lock(
      [(sign * .41, .30, 2.32),
       (sign * .34, .435, 2.50),
       (sign * .10, .535, 2.64)],
      [.037, .115, .062],
      [.03, .063, .045],
      normal=(0, 1, 0),
      sides=8)
  hair.lock(
    [(0, -.46, 2.93),
     (0, -.19, 3.02),
     (0, .13, 3.035),
     (0, .44, 2.995),
     (0, .575, 2.75),
     (0, .59, 2.45),
     (0, .55, 2.22)],
    [.09, .115, .115, .11, .095, .085, .045],
    [.09, .09, .09, .105, .10, .075, .055],
    normal=(0, -1, 0),
    sides=8)
  hair.braid(
    [(0, -.50, 2.93),
     (0, -.19, 3.065),
     (0, .13, 3.075),
     (0, .46, 3.015),
     (0, .62, 2.75),
     (0, .635, 2.45),
     (0, .565, 2.22)],
    radius=.145,
    links=8,
    normal=(0, -1, 0),
    taper=.70)
  hair.ring((0, .60, 2.185), .082, thickness=.021, normal=(0, 0, 1))
  hair.lock(
    [(0, .60, 2.205), (0, .615, 2.09), (.035, .61, 1.99)],
    [.065, .09, .011],
    [.052, .056, .012],
    normal=(0, 1, 0),
    sides=7)


def bun(hair):
  """Build a softly side-parted sweep gathered into a low braided bun."""
  profile = [(2.21, .455, .485, -.008), (2.385, .497, .510, .014),
             (2.605, .502, .520, .015), (2.84, .465, .470, .023),
             (3.00, .345, .340, .025), (3.075, .180, .170, .020),
             (3.09, .070, .065, .020)]
  def hem(theta):
    """Open the forehead beneath the side part and keep the nape covered."""
    cosine = math.cos(theta)
    return 2.43 + ((2.77 if cosine >= 0 else 2.265) - 2.43) * cosine ** 2

  hair.cap(hem=hem, profile=profile, top=3.09, puff=.035)
  hair.lock(
    [(.155, -.29, 3.045),
     (-.10, -.40, 3.065),
     (-.355, -.475, 2.90),
     (-.485, -.36, 2.665),
     (-.49, -.19, 2.415)],
    [.07, .165, .18, .125, .031],
    [.041, .067, .075, .063, .03],
    normal=(0, -1, .2),
    sides=8,
    steps=4)
  hair.lock(
    [(.17, -.255, 3.045),
     (.365, -.35, 2.93),
     (.51, -.23, 2.69),
     (.50, .12, 2.42),
     (.30, .43, 2.30)],
    [.06, .135, .14, .11, .045],
    [.04, .069, .073, .066, .034],
    normal=(1, -.5, .1),
    sides=8,
    steps=4)
  sweptPanels(hair, profile, hem, 3.09,
              [(2.35, 2.53, .45), (3.14, 2.96, .45),
               (3.93, 3.39, .45)], .035, .036)
  hair.lock(
    [(-.495, .06, 2.58),
     (-.43, .33, 2.42),
     (-.13, .49, 2.32),
     (.17, .50, 2.30)],
    [.055, .108, .103, .053],
    [.032, .056, .052, .034],
    normal=(0, 1, 0),
    sides=8)
  hair.ellipsoid((.16, .565, 2.245), (.245, .16, .235), subdivisions=2)
  points = []
  for i in range(13):
    angle = -math.pi / 2 + 2 * math.pi * i / 12
    points.append((.16 + .163 * math.cos(angle),
                   .68,
                   2.245 + .157 * math.sin(angle)))
  hair.braid(points, radius=.094, links=7, normal=(0, 1, 0), taper=1.0)
  hair.lock(
    [(.075, .702, 2.31), (.17, .735, 2.295), (.245, .705, 2.21)],
    [.052, .075, .037],
    [.04, .045, .03],
    normal=(0, 1, 0),
    sides=7)


def build(style, hair):
  """Construct the requested hairstyle with the shared geometry builder."""
  if style == 5:
    twists(hair)
  elif style == 6:
    bob(hair)
  elif style == 7:
    dutch(hair)
  elif style == 8:
    bun(hair)
  else:
    raise ValueError(f"Unsupported hairstyle {style}")
