"""Sculpt the first four short hairstyle concepts."""

import math


def signedPower(value, exponent):
  """Keep the sign while shaping a rounded rectangular cross section."""
  return math.copysign(abs(value) ** exponent, value)


def crop(hair):
  """Layer thick forward-pointing locks over a close short back."""
  hair.cap(
    front=2.765,
    side=2.43,
    back=2.30,
    top=3.105,
    puff=.022,
    segments=40,
    rings=10,
    profile=[
      (2.25, .49, .505, .014),
      (2.54, .502, .520, .015),
      (2.775, .465, .470, .023),
      (2.935, .345, .340, .025),
      (3.035, .205, .195, .020),
      (3.105, .030, .028, .020),
    ]
  )
  # Broad pointed bangs sit above the eyebrows and overlap at their roots.
  for x, tipX, tipZ, width in [
    (-.39, -.435, 2.75, .115),
    (-.235, -.305, 2.705, .135),
    (-.065, -.165, 2.765, .145),
    (.105, -.015, 2.725, .15),
    (.28, .175, 2.785, .145),
    (.41, .335, 2.725, .12),
  ]:
    hair.lock(
      [
        (x + .055, -.075, 3.04 - abs(x) * .26),
        (x + .050, -.31, 3.025 - abs(x) * .36),
        (x, -.49, 2.88 - abs(x) * .14),
        (tipX, -.555 + abs(x) * .06, tipZ),
      ],
      [.065, width, width * .80, .012],
      [.038, .067, .055, .015],
      sides=7,
      steps=3
    )
  # A second staggered layer makes a compact, tousled crown.
  for x, endX, endY, endZ, width in [
    (-.34, -.45, -.14, 2.945, .125),
    (-.16, -.29, -.26, 3.00, .15),
    (.035, -.10, -.29, 3.045, .16),
    (.23, .10, -.22, 3.035, .145),
    (.385, .29, -.14, 2.96, .12),
  ]:
    hair.lock(
      [
        (x - .04, .24, 2.995 - abs(x) * .25),
        (x + .045, .065, 3.13 - abs(x) * .43),
        (x + .055, -.08, 3.145 - abs(x) * .48),
        (endX, endY, endZ),
      ],
      [.065, width, width * .88, .012],
      [.038, .060, .048, .012],
      normal=(0, 0, 1),
      sides=7,
      steps=3
    )
  # Short shingles continue around the temples and rear crown.
  for theta, z, length in [
    (-1.02, 2.975, .26),
    (1.02, 2.94, .28),
    (-1.49, 2.925, .24),
    (1.49, 2.965, .27),
    (-2.04, 2.99, .27),
    (2.04, 2.95, .28),
    (-2.62, 3.005, .30),
    (2.62, 2.985, .25),
    (math.pi, 3.015, .285),
  ]:
    points = [
      hair.scalp(theta - .12, z, .065),
      hair.scalp(theta + .04, z - .10, .068),
      hair.scalp(theta + .20, z - length, .040),
    ]
    hair.lock(
      points,
      [.065, .115, .014],
      [.035, .058, .013],
      normal=(math.sin(theta), -math.cos(theta), .18),
      sides=7,
      steps=3
    )


def bowl(hair):
  """Create an even mushroom dome with one sharp triangular fringe notch."""
  hair.cap(
    front=2.83,
    side=2.44,
    back=2.30,
    top=3.075,
    puff=.027,
    segments=40,
    rings=9
  )

  def hem(theta):
    """Raise one front interval to make the distinct V-shaped notch."""
    angle = (theta + math.pi) % (2 * math.pi) - math.pi
    notch = max(0, 1 - abs(angle + .28) / .12)
    return 2.655 - .025 * (1 - math.cos(theta)) + .175 * notch

  profile = [
    (2.54, .545, .555, .014),
    (2.66, .555, .565, .016),
    (2.78, .553, .565, .020),
    (2.91, .501, .515, .022),
    (3.04, .415, .425, .022),
    (3.145, .275, .280, .021),
    (3.20, .080, .082, .020),
  ]
  hair.cap(
    top=3.20,
    puff=.015,
    segments=64,
    rings=14,
    hem=hem,
    profile=profile
  )
  # These shallow broad panels give the cut its quiet vertical rhythm.
  for theta in [-1.28, -.83, .10, .58, 1.06, 1.58,
                2.12, 2.66, 3.20, 3.74, 4.28]:
    sine = signedPower(math.sin(theta), .88)
    cosine = signedPower(math.cos(theta), .88)
    hair.lock(
      [
        (.19 * sine, .021 - .20 * cosine, 3.155),
        (.427 * sine, .022 - .441 * cosine, 3.035),
        (.552 * sine, .020 - .565 * cosine, 2.82),
        (.565 * sine, .017 - .58 * cosine, hem(theta) + .012),
      ],
      [.025, .060, .072, .065],
      [.008, .010, .011, .009],
      normal=(math.sin(theta), -math.cos(theta), .05),
      sides=6,
      steps=3
    )


def flatTop(hair):
  """Build a tall square cut with broad planar walls and a beveled roof."""
  count = 16
  vertices = []
  faces = []
  for i in range(count):
    theta = i * math.tau / count
    angle = abs((theta + math.pi) % math.tau - math.pi)
    if angle <= math.pi / 4:
      z = 2.695 + .055 * math.sin(angle * 4)
    elif angle <= math.pi / 2:
      blend = (angle - math.pi / 4) / (math.pi / 4)
      z = 2.695 - .26 * blend
    else:
      blend = (angle - math.pi / 2) / (math.pi / 2)
      z = 2.435 - .115 * blend
    vertices.append(hair.scalp(theta, z, .035))
  for z, radiusX, radiusY in [
    (2.905, .543, .512),
    (3.14, .563, .525),
    (3.205, .511, .477),
  ]:
    for i in range(count):
      theta = i * math.tau / count
      vertices.append((
        radiusX * signedPower(math.sin(theta), .37),
        .020 - radiusY * signedPower(math.cos(theta), .37),
        z,
      ))
  for j in range(3):
    for i in range(count):
      k = (i + 1) % count
      faces.append((j * count + i, j * count + k,
                    (j + 1) * count + k, (j + 1) * count + i))
  faces.append(tuple(reversed(range(count))))
  faces.append(tuple(3 * count + i for i in range(count)))
  hair.mesh(vertices, faces)


def afro(hair):
  """Pack varied polygonal curls into a rounded full afro silhouette."""
  hair.cap(
    front=2.77,
    side=2.43,
    back=2.235,
    top=3.155,
    puff=.070,
    segments=40,
    rings=11
  )
  # The broad front clumps leave a scalloped, clear forehead opening.
  for x, y, z, radius in [
    (-.405, -.325, 2.795, .205),
    (-.215, -.490, 2.815, .215),
    (.025, -.525, 2.795, .205),
    (.245, -.455, 2.84, .220),
    (.435, -.305, 2.765, .215),
    (-.530, -.11, 2.64, .205),
    (.535, -.09, 2.61, .22),
  ]:
    hair.ellipsoid(
      (x, y, z),
      (radius, radius * .92, radius * .98),
      subdivisions=2,
      rotation=(x * .5, y * .8, z * .8)
    )
  # Alternating tiers keep the silhouette irregular without loose curls.
  for i in range(10):
    theta = .36 + i * math.tau / 10
    radius = .202 + .020 * math.sin(i * 2.1)
    hair.ellipsoid(
      (.47 * math.sin(theta), .025 - .455 * math.cos(theta),
       2.95 + .025 * math.cos(i * 1.8)),
      (radius * 1.06, radius, radius * 1.035),
      subdivisions=2,
      rotation=(i * .19, i * .27, i * .38)
    )
  for i in range(7):
    theta = -.12 + i * math.tau / 7
    radius = .215 + .012 * math.cos(i * 2.2)
    hair.ellipsoid(
      (.265 * math.sin(theta), .030 - .258 * math.cos(theta),
       3.12 + .030 * math.sin(i * 2)),
      (radius * 1.02, radius, radius * .95),
      subdivisions=2,
      rotation=(i * .30, i * .18, i * .47)
    )
  hair.ellipsoid(
    (-.04, .02, 3.155),
    (.24, .235, .205),
    subdivisions=2,
    rotation=(.2, .1, .6)
  )
  for theta, z, radius in [
    (1.46, 2.57, .218),
    (1.91, 2.67, .239),
    (2.40, 2.61, .251),
    (2.91, 2.69, .247),
    (3.41, 2.58, .251),
    (3.94, 2.65, .238),
    (4.43, 2.55, .217),
  ]:
    hair.ellipsoid(
      (.525 * math.sin(theta), .025 - .550 * math.cos(theta), z),
      (radius, radius * 1.035, radius * 1.025),
      subdivisions=2,
      rotation=(theta * .34, theta * .49, theta * .71)
    )
  for theta, z, radius in [
    (1.97, 2.37, .197),
    (2.52, 2.35, .216),
    (3.07, 2.395, .219),
    (3.62, 2.335, .207),
    (4.17, 2.38, .20),
  ]:
    hair.ellipsoid(
      (.435 * math.sin(theta), .025 - .495 * math.cos(theta), z),
      (radius, radius, radius * .98),
      subdivisions=2,
      rotation=(theta * .52, theta * .23, theta * .61)
    )


def build(style, hair):
  """Append the requested short hairstyle to the shared geometry builder."""
  if style == 1:
    crop(hair)
  elif style == 2:
    bowl(hair)
  elif style == 3:
    flatTop(hair)
  elif style == 4:
    afro(hair)
  else:
    raise ValueError(f"Unsupported hairstyle {style}")
