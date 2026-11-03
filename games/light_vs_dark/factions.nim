import
  std/random,
  chroma

type
  Faction* = enum
    PeterRiver, Amethyst, Alizarin, Emerald,
    Carrot, WetAsphalt, Turquoise, SunFlower

const
  FactionFiles*: array[Faction, string] = [
    "peter_river", "amethyst", "alizarin", "emerald",
    "carrot", "wet_asphalt", "turquoise", "sun_flower"
  ]
  FactionColors*: array[Faction, ColorRGBX] = [
    PeterRiver: rgbx(0x34, 0x98, 0xDB, 255),
    Amethyst: rgbx(0x9B, 0x59, 0xB6, 255),
    Alizarin: rgbx(0xE7, 0x4C, 0x3C, 255),
    Emerald: rgbx(0x2E, 0xCC, 0x71, 255),
    Carrot: rgbx(0xE6, 0x7E, 0x22, 255),
    WetAsphalt: rgbx(0x34, 0x49, 0x5E, 255),
    Turquoise: rgbx(0x1A, 0xBC, 0x9C, 255),
    SunFlower: rgbx(0xF1, 0xC4, 0x0F, 255)
  ]

proc factionOrder*(seed: int64): array[Faction, Faction] =
  ## Shuffles all eight distinct looks without using the simulation RNG.
  var rng = initRand(seed)
  for faction in Faction:
    result[faction] = faction
  for index in countdown(Faction.high.ord, 1):
    let other = rng.rand(index)
    swap(result[Faction(index)], result[Faction(other)])

proc skinRgb*(faction: Faction): array[3, float32] =
  ## Converts the exact UI color to the matching CharGen skin tint.
  let tint = FactionColors[faction]
  [tint.r.float32 / 255, tint.g.float32 / 255, tint.b.float32 / 255]
