import std/math

const Student95 = [
  12.706204736432, 4.3026527296961, 3.1824463052843, 2.7764451051978,
  2.5705818356363, 2.446911851145, 2.3646242515928, 2.3060041352042,
  2.2621571628541, 2.2281388519649, 2.2009851600829, 2.1788128296634,
  2.160368656461, 2.1447866879169, 2.1314495455593, 2.119905299221,
  2.1098155778332, 2.100922040241, 2.0930240544083, 2.0859634472658,
  2.0796138447277, 2.073873067904, 2.068657610419, 2.063898561628,
  2.0595385527533, 2.0555294386429, 2.0518305164803, 2.0484071417952,
  2.0452296421327, 2.0422724563012
]

proc critical95*(degrees: int): float64 =
  ## Returns the two-sided Student t critical value for 95% confidence.
  doAssert degrees > 0
  if degrees <= Student95.len:
    return Student95[degrees - 1]
  const Z = 1.959963984540054
  let
    df = degrees.float64
    z3 = Z * Z * Z
    z5 = z3 * Z * Z
    z7 = z5 * Z * Z
  Z + (z3 + Z) / (4 * df) +
    (5 * z5 + 16 * z3 + 3 * Z) / (96 * df * df) +
    (3 * z7 + 19 * z5 + 17 * z3 - 15 * Z) / (384 * df * df * df)

proc margin95*(totals: openArray[float64], counts: openArray[int]): float64 =
  ## Estimates mean uncertainty with each game as one independent cluster.
  doAssert totals.len >= 2 and totals.len == counts.len
  var
    total = 0.0
    count = 0
  for i in 0 ..< totals.len:
    doAssert counts[i] > 0
    total += totals[i]
    count += counts[i]
  let mean = total / count.float64
  var squares = 0.0
  for i in 0 ..< totals.len:
    let residual = totals[i] - mean * counts[i].float64
    squares += residual * residual
  let groups = totals.len.float64
  critical95(totals.len - 1) *
    sqrt(groups / (groups - 1) * squares) / count.float64
