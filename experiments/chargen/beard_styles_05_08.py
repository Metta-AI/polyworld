import math

from beards import jaw, surface


def moustache(hair, reach=.265):
  """Sculpt a broad parted moustache that leaves the center mouth visible."""
  for sign in (-1, 1):
    hair.lock(
      [surface(sign * .028, 2.175, .040),
       surface(sign * .10, 2.18, .064),
       surface(sign * .205, 2.13, .061),
       surface(sign * reach, 2.10, .041)],
      [.023, .052, .045, .012],
      [.030, .050, .043, .015],
      normal=(0, -1, 0),
      sides=7,
      steps=3)


def square(hair):
  """Wrap a clean angular beard around the jaw without a moustache."""
  def upper(theta):
    """Leave the upper lip and chin expression visible above the beard."""
    notch = .014 * max(0.0, 1 - abs(theta) / .16)
    return 2.035 + .325 * abs(math.sin(theta)) ** 3 + notch

  def lower(theta):
    """Give the square jaw a shallow faceted point at its center."""
    return 1.855 + .15 * abs(math.sin(theta)) ** 1.3

  jaw(
    hair,
    top=upper,
    bottom=lower,
    width=.475,
    depth=.475,
    centerY=.006,
    extent=1.48,
    thickness=.065)


def chops(hair):
  """Build two solid swept cheek panels around a completely open chin."""
  for sign in (-1, 1):
    outline = [
      surface(.465, 2.43, .016),
      (.487, -.09, 2.32),
      (.535, -.075, 2.10),
      (.505, -.13, 1.995),
      (.335, -.435, 1.86),
      (.275, -.455, 2.065),
      surface(.295, 2.165, .036),
      surface(.415, 2.205, .032),
      surface(.45, 2.285, .005)]
    outline = [(x * sign, y, z) for x, y, z in outline]
    vertices = outline + [(sign * .415, -.35, 2.095)]
    vertices += [(x, y + .058, z) for x, y, z in outline]
    vertices.append((sign * .415, -.292, 2.095))
    faces = []
    for i in range(9):
      j = (i + 1) % 9
      faces.append((i, j, 9))
      faces.append((i + 10, 19, j + 10))
      faces.append((i, i + 10, j + 10, j))
    hair.mesh(vertices, faces, smooth=False)


def rounded(hair):
  """Build a close full beard with broad rounded cheek and chin clumps."""
  jaw(
    hair,
    top=lambda theta: 2.055 + .30 * abs(math.sin(theta)) ** 3,
    bottom=lambda theta: 1.885 + .445 * abs(math.sin(theta)) ** 4,
    width=.465,
    depth=.495,
    centerY=.005,
    extent=1.48,
    thickness=.072)
  for sign in (-1, 1):
    hair.lock(
      [surface(sign * .405, 2.24, .026),
       (sign * .415, -.345, 2.14),
       (sign * .34, -.455, 2.025),
       (sign * .245, -.455, 1.945)],
      [.066, .122, .139, .071],
      [.048, .075, .076, .05],
      normal=(sign * .35, -1, 0),
      sides=8,
      steps=3)
    hair.lock(
      [surface(sign * .48, 2.30, .014),
       (sign * .47, -.205, 2.185),
       (sign * .395, -.355, 2.055),
       (sign * .31, -.435, 1.96)],
      [.029, .093, .111, .058],
      [.033, .063, .074, .043],
      normal=(sign * .8, -1, 0),
      sides=8,
      steps=3)
    hair.lock(
      [surface(sign * .14, 2.055, .040),
       (sign * .16, -.515, 1.99),
       (sign * .15, -.465, 1.91)],
      [.089, .126, .075],
      [.052, .079, .054],
      normal=(0, -1, 0),
      sides=8,
      steps=4)
  hair.lock(
    [surface(0, 2.052, .041),
     (0, -.535, 1.98),
     (0, -.485, 1.875)],
    [.093, .133, .077],
    [.055, .085, .057],
    normal=(0, -1, 0),
    sides=8,
    steps=4)
  moustache(hair)


def forked(hair):
  """Split a broad full beard into two substantial pointed chin lobes."""
  def lower(theta):
    """Shape a continuous cheek flare and taper its rear attachment."""
    angle = abs(theta)
    points = [(0.0, 1.925), (.5, 1.935), (.85, 1.96),
              (1.08, 1.95), (1.22, 2.10), (1.4, 2.28), (1.48, 2.32)]
    for first, second in zip(points, points[1:]):
      if angle <= second[0]:
        t = (angle - first[0]) / (second[0] - first[0])
        return first[1] + (second[1] - first[1]) * t
    return points[-1][1]

  def width(theta):
    """Widen the cheek corners into the beard's integrated pointed flare."""
    return .46 + .16 * max(0.0, 1 - abs(abs(theta) - 1.05) / .38)

  jaw(
    hair,
    top=lambda theta: 2.056 + .29 * abs(math.sin(theta)) ** 3,
    bottom=lower,
    width=width,
    depth=lambda theta: .535 - .10 * abs(math.sin(theta)) ** 2,
    centerY=.005,
    extent=1.48,
    thickness=.08)
  for sign in (-1, 1):
    hair.lock(
      [surface(sign * .09, 2.045, .053),
       (sign * .12, -.55, 1.97),
       (sign * .185, -.53, 1.84),
       (sign * .175, -.45, 1.695)],
      [.13, .168, .12, .01],
      [.058, .095, .087, .015],
      normal=(0, -1, 0),
      sides=7,
      steps=3)
  moustache(hair, reach=.275)


def build(style, hair):
  """Construct one facial hairstyle with the shared geometry builder."""
  if style == 5:
    square(hair)
  elif style == 6:
    chops(hair)
  elif style == 7:
    rounded(hair)
  elif style == 8:
    forked(hair)
  else:
    raise ValueError(f"Unsupported facial hairstyle {style}")
