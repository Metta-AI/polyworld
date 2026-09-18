"""Sculpted twin braids, blunt bob, waved bob, and layered shag hairstyles."""

import math


def profileAt(z, profile):
  """Interpolate the rounded scalp profile at one height."""
  if z <= profile[0][0]:
    return profile[0][1:]
  for i in range(1, len(profile)):
    if z <= profile[i][0]:
      a, b = profile[i - 1], profile[i]
      t = (z - a[0]) / (b[0] - a[0])
      return tuple(a[j] * (1 - t) + b[j] * t for j in range(1, 4))
  return profile[-1][1:]


def partedCap(hair):
  """Build two closed scalp shells separated by a narrow zigzag part."""
  profile = [
    (2.28, .52, .54, .025),
    (2.54, .55, .57, .025),
    (2.78, .52, .53, .025),
    (2.96, .41, .405, .025),
    (3.07, .27, .265, .025),
    (3.145, .095, .095, .025),
    (3.16, .021, .020, .025),
  ]
  levels = 16
  segments = 24
  zigzag = [0, .038, -.029, .037, -.027, .026, 0]
  for sign in [-1, 1]:
    vertices = []
    for layer in [0, 1]:
      for i in range(levels + 1):
        v = i / levels
        for j in range(segments + 1):
          theta = math.pi * j / segments
          front = math.exp(-((theta / 1.02) ** 4))
          hem = 2.34 + .355 * front
          z = hem + (3.16 - hem) * v
          rx, ry, cy = profileAt(z, profile)
          s, c = math.sin(theta), math.cos(theta)
          sweep = .020 * (1 + math.cos(v * math.tau * 3 + theta * 2))
          sweep *= math.sin(math.pi * v) ** .65 * abs(s) ** .4
          rx += sweep
          ry += sweep
          x = sign * rx * abs(s) ** .88
          y = cy - math.copysign(ry * abs(c) ** .88, c)
          if j == 0:
            t = min(v * 6, 5.999)
            k = int(t)
            part = zigzag[k] * (1 - (t - k)) + zigzag[k + 1] * (t - k)
            x = part + sign * .013
          if j == segments:
            x = sign * .004
          if layer:
            x *= .92
            y = cy + (y - cy) * .88
            z -= .045
          vertices.append((x, y, z))
    count = (levels + 1) * (segments + 1)
    faces = []
    for layer in [0, 1]:
      for i in range(levels):
        for j in range(segments):
          a = layer * count + i * (segments + 1) + j
          face = (a, a + 1, a + segments + 2, a + segments + 1)
          faces.append(face if layer == 0 else tuple(reversed(face)))
    boundary = list(range(segments + 1))
    boundary += [i * (segments + 1) + segments for i in range(1, levels + 1)]
    boundary += [levels * (segments + 1) + j for j in range(segments - 1, -1, -1)]
    boundary += [i * (segments + 1) for i in range(levels - 1, 0, -1)]
    for a, b in zip(boundary, boundary[1:] + boundary[:1]):
      faces.append((a, a + count, b + count, b))
    if sign < 0:
      faces = [tuple(reversed(face)) for face in faces]
    hair.mesh(vertices, faces)


def twinBraids(hair):
  """Sweep paired scalp lobes into two low, substantial plaited tails."""
  partedCap(hair)
  for sign in [-1, 1]:
    hair.braid(
      [(sign * .45, .14, 2.39),
       (sign * .51, .08, 2.16),
       (sign * .53, .025, 1.92),
       (sign * .52, -.005, 1.69)],
      radius=.135,
      links=6,
      normal=(0, -1, 0),
      taper=.57,
    )
    hair.ring(
      (sign * .52, -.005, 1.72),
      radius=.054,
      thickness=.013,
      normal=(0, 0, 1),
    )
    hair.lock(
      [(sign * .52, -.005, 1.74),
       (sign * .53, -.005, 1.64),
       (sign * .50, -.012, 1.59)],
      [.052, .047, .009],
      [.04, .035, .008],
      normal=(0, -1, 0),
    )


def bluntBob(hair):
  """Form a continuous chin-length bob with a square full fringe."""
  def hem(theta):
    """Keep the face open under the fringe and lower the side curtain."""
    angle = abs((theta + math.pi) % (2 * math.pi) - math.pi)
    t = min(1, max(0, (angle - .64) / .28))
    return 2.69 * (1 - t) + (2.105 + .008 * math.cos(theta * 12)) * t

  hair.cap(
    top=3.16,
    puff=.021,
    hem=hem,
    profile=[
      (2.08, .574, .535, .06),
      (2.15, .625, .565, .06),
      (2.40, .645, .585, .045),
      (2.66, .570, .556, .030),
      (2.90, .440, .447, .025),
      (3.06, .271, .278, .020),
      (3.16, .018, .018, .020),
    ],
  )
  for i in range(7):
    x = (i - 3) * .125
    hair.lock(
      [(x * .20, -.10, 3.125 - .027 * abs(i - 3)),
       (x * .70, -.405, 2.94 - .030 * abs(i - 3)),
       (x, -.549 + .053 * (abs(x) / .4), 2.74),
       (x * 1.015, -.557 + .038 * (abs(x) / .4), 2.590)],
      [.014, .097, .098, .082],
      [.012, .049, .049, .037],
      normal=(0, -1, .10),
      steps=4,
    )
  for i in range(11):
    theta = 1.03 + i * (2 * math.pi - 2.06) / 10
    s, c = math.sin(theta), math.cos(theta)
    s = math.copysign(abs(s) ** .88, s)
    c = math.copysign(abs(c) ** .88, c)
    z = 2.13 - .014 * math.cos(theta * 4)
    hair.lock(
      [(s * .09, .025 - c * .09, 3.105),
       (s * .467, .035 - c * .473, 2.89),
       (s * .649, .045 - c * .602, 2.42),
       (s * .637, .060 - c * .589, 2.23),
       (s * .628, .060 - c * .562, z)],
      [.009, .104, .124, .123, .093],
      [.008, .042, .043, .038, .027],
      normal=(s, -c, 0),
      steps=3,
    )
  for sign in [-1, 1]:
    hair.lock(
      [(sign * .14, -.16, 3.10),
       (sign * .46, -.40, 2.82),
       (sign * .545, -.44, 2.40),
       (sign * .52, -.435, 2.10)],
      [.010, .110, .116, .090],
      [.008, .055, .058, .044],
      normal=(0, -1, 0),
      steps=4,
    )


def wavyBob(hair):
  """Layer broad rolling panels into an asymmetric, outward-flipped bob."""
  hair.cap(
    front=2.78,
    side=2.29,
    back=2.10,
    top=3.19,
    puff=.045,
    profile=[
      (2.04, .44, .46, .055),
      (2.30, .48, .51, .045),
      (2.56, .51, .545, .025),
      (2.79, .50, .52, .025),
      (3.02, .36, .35, .025),
      (3.14, .17, .16, .02),
      (3.19, .021, .021, .02),
    ],
  )
  angles = [1.20, 1.89, 2.58, 3.27, 3.96, 4.65, 5.14]
  for i, theta in enumerate(angles):
    s, c = math.sin(theta), math.cos(theta)
    turn = .18 * math.sin(theta * 1.3)
    u, v = math.sin(theta + turn), math.cos(theta + turn)
    a, b = math.sin(theta - .16), math.cos(theta - .16)
    lower = 2.04 + .055 * math.cos(theta * 2)
    hair.lock(
      [(s * .12 - .025, .045 - c * .13, 3.12),
       (s * .43, .030 - c * .44, 3.01),
       (u * .59, .04 - v * .62, 2.77),
       (s * .58, .07 - c * .62, 2.49),
       (a * .62, .07 - b * .66, 2.23),
       (a * .77, .07 - b * .76, lower)],
      [.012, .18, .212, .203, .155, .010],
      [.009, .080, .093, .091, .070, .008],
      normal=(s, -c, .06),
      steps=4,
    )
  hair.lock(
    [(.02, .035, 3.135),
     (-.17, -.29, 3.115),
     (-.40, -.46, 2.92),
     (-.50, -.54, 2.69),
     (-.62, -.52, 2.44),
     (-.58, -.48, 2.23),
     (-.77, -.36, 2.08)],
    [.012, .17, .172, .14, .15, .103, .009],
    [.009, .09, .089, .072, .077, .064, .008],
    normal=(0, -1, .08),
    steps=4,
  )
  hair.lock(
    [(.065, -.255, 3.08),
     (.30, -.41, 3.00),
     (.48, -.48, 2.79),
     (.62, -.47, 2.53),
     (.58, -.45, 2.29),
     (.79, -.30, 2.09)],
    [.011, .152, .143, .133, .10, .009],
    [.009, .084, .078, .070, .059, .008],
    normal=(0, -1, .08),
    steps=4,
  )
  hair.lock(
    [(-.025, -.245, 3.075),
     (-.17, -.48, 2.965),
     (-.32, -.52, 2.845)],
    [.010, .083, .010],
    [.009, .050, .009],
    normal=(0, -1, 0),
  )


def shag(hair):
  """Build a pointed crown, parted fringe, and staggered wolf-cut layers."""
  hair.cap(
    front=2.79,
    side=2.30,
    back=2.005,
    top=3.16,
    puff=.025,
    profile=[
      (2.00, .40, .42, .06),
      (2.20, .49, .515, .04),
      (2.54, .525, .545, .02),
      (2.78, .48, .49, .025),
      (2.98, .33, .325, .025),
      (3.10, .15, .145, .02),
      (3.16, .018, .018, .02),
    ],
  )
  for sign in [-1, 1]:
    hair.lock(
      [(sign * .035, -.10, 3.125),
       (sign * .15, -.38, 3.00),
       (sign * .22, -.54, 2.80),
       (sign * .19, -.565, 2.585)],
      [.012, .155, .155, .010],
      [.009, .078, .074, .009],
      normal=(0, -1, .08),
      steps=3,
    )
    hair.lock(
      [(sign * .10, -.14, 3.11),
       (sign * .33, -.33, 2.97),
       (sign * .42, -.49, 2.77),
       (sign * .40, -.52, 2.60)],
      [.012, .14, .125, .008],
      [.009, .075, .062, .008],
      normal=(0, -1, .1),
      steps=3,
    )
    hair.lock(
      [(sign * .34, -.19, 2.87),
       (sign * .54, -.29, 2.68),
       (sign * .53, -.33, 2.46),
       (sign * .57, -.35, 2.34)],
      [.010, .105, .076, .008],
      [.008, .059, .043, .008],
      normal=(sign * .45, -.85, 0),
      steps=3,
    )
    for i in range(3):
      z = 2.91 - i * .245
      hair.lock(
        [(sign * .34, .05, z + .14),
         (sign * .53, -.06, z),
         (sign * .55, -.04, z - .18),
         (sign * (.69 - .015 * i), -.05, z - .22)],
        [.014, .13, .096, .008],
        [.009, .073, .052, .008],
        normal=(sign, -.25, 0),
        steps=3,
      )
    hair.lock(
      [(sign * .13, .00, 3.12),
       (sign * .35, -.04, 3.11),
       (sign * .60, -.08, 2.93)],
      [.012, .12, .009],
      [.009, .066, .009],
      normal=(sign * .3, -1, .3),
      steps=3,
    )
  for layer in range(3):
    for i in range(7):
      theta = 1.28 + i * .60 + .27 * (layer % 2)
      s, c = math.sin(theta), math.cos(theta)
      root = [3.105, 2.865, 2.53][layer]
      rootRadius = [.14, .43, .49][layer]
      shoulder = [2.93, 2.675, 2.32][layer]
      end = [2.665, 2.355, 2.045][layer]
      end += .048 * math.cos(theta * 2.7 + layer)
      radius = [.455, .565, .57][layer]
      tipTheta = theta + .22 * math.sin(theta * 1.4 + layer)
      a, b = math.sin(theta - .16), math.cos(theta - .16)
      hair.lock(
        [(a * rootRadius, .04 - b * rootRadius, root),
         (s * radius, .04 - c * (radius + .045), shoulder),
         (math.sin(tipTheta) * (radius + .025),
          .04 - math.cos(tipTheta) * (radius + .075), end + .105),
         (math.sin(tipTheta) * (radius + .105),
          .04 - math.cos(tipTheta) * (radius + .145), end)],
        [.012, .159, .122, .008],
        [.009, .075, .059, .008],
        normal=(s, -c, .08),
        steps=3,
      )
  hair.lock(
    [(-.14, .06, 3.115), (-.03, .08, 3.20), (.075, .10, 3.245)],
    [.012, .070, .012],
    [.009, .042, .008],
    normal=(0, -1, 0),
  )


def build(style, hair):
  """Build one of hairstyles nine through twelve on the shared head."""
  if style == 9:
    twinBraids(hair)
  elif style == 10:
    bluntBob(hair)
  elif style == 11:
    wavyBob(hair)
  elif style == 12:
    shag(hair)
  else:
    raise ValueError("Unsupported hairstyle: " + str(style))
