"""Sculpt the first four facial-hair concepts on the shared face."""

from beards import surface


def splitTuft(hair):
  """Attach two broad pointed leaves immediately below the bare chin."""
  for sign in [-1, 1]:
    hair.lock(
      [
        surface(sign * .041, 2.062, .014),
        surface(sign * .061, 2.018, .030),
        (sign * .066, -.450, 1.953),
        (sign * .060, -.421, 1.851),
      ],
      [.016, .057, .049, .007],
      [.020, .042, .044, .008],
      normal=(0, -1, 0),
      sides=7,
      steps=3
    )


def chevron(hair):
  """Part two thick tapered moustache wings below the nose."""
  for sign in [-1, 1]:
    hair.lock(
      [
        surface(sign * .015, 2.176, .027),
        surface(sign * .075, 2.169, .027),
        surface(sign * .157, 2.130, .023),
        surface(sign * .233, 2.084, .012),
      ],
      [.016, .040, .039, .008],
      [.024, .046, .039, .009],
      normal=(0, -1, 0),
      sides=8,
      steps=4
    )


def handlebar(hair):
  """Sweep substantial moustache lobes into short upward curled tips."""
  for sign in [-1, 1]:
    hair.lock(
      [
        surface(sign * .016, 2.169, .031),
        surface(sign * .111, 2.144, .044),
        surface(sign * .228, 2.106, .042),
        surface(sign * .341, 2.124, .034),
        surface(sign * .425, 2.176, .028),
        surface(sign * .443, 2.231, .023),
        surface(sign * .425, 2.268, .012),
      ],
      [.023, .060, .074, .064, .037, .020, .007],
      [.026, .062, .062, .051, .035, .022, .008],
      normal=(0, -1, 0),
      sides=8,
      steps=4
    )


def anchor(hair):
  """Frame the mouth with a connected angular ring and short chin point."""
  for sign in [-1, 1]:
    hair.lock(
      [
        surface(sign * .014, 2.180, .023),
        surface(sign * .078, 2.171, .025),
        surface(sign * .156, 2.142, .021),
        surface(sign * .191, 2.119, .015),
      ],
      [.017, .040, .038, .028],
      [.021, .040, .034, .026],
      normal=(0, -1, 0),
      sides=7,
      steps=3
    )
    hair.lock(
      [
        surface(sign * .188, 2.135, .016),
        surface(sign * .196, 2.071, .018),
        surface(sign * .177, 2.006, .027),
        (sign * .100, -.430, 1.958),
      ],
      [.029, .033, .037, .041],
      [.025, .027, .032, .037],
      normal=(0, -1, 0),
      sides=6,
      steps=3
    )
  hair.lock(
    [
      surface(0, 2.034, .022),
      (0, -.455, 1.992),
      (0, -.452, 1.944),
      (0, -.414, 1.838),
    ],
    [.021, .080, .113, .008],
    [.023, .049, .052, .011],
    normal=(0, -1, 0),
    sides=6,
    steps=3
  )


def build(style, hair):
  """Append one requested facial-hair concept as closed sculpted pieces."""
  if style == 1:
    splitTuft(hair)
  elif style == 2:
    chevron(hair)
  elif style == 3:
    handlebar(hair)
  elif style == 4:
    anchor(hair)
  else:
    raise ValueError(f"Unsupported facial-hair style {style}")
