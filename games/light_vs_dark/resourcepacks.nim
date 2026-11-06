import content

type
  ResourcePack* = enum
    NoPack, WoodPack, GoldPack

proc carriedPack*(
  kind: UnitKind,
  hp, gold, wood: int32
): ResourcePack =
  ## Keeps cargo visible through interrupted orders until deposit or death.
  if kind != PeonUnit or hp <= 0:
    NoPack
  elif wood > 0:
    WoodPack
  elif gold > 0:
    GoldPack
  else:
    NoPack
