import
  chroma, pixie,
  assets, content

const
  SymbolSize = 256
  SymbolInset = 2
  SymbolKeys: array[UnitKind, string] = [
    "lvd_pickaxe", "lvd_sword", "lvd_bow", "lvd_staff",
    "lvd_helmet", "lvd_bomb", "lvd_healing", "lvd_flame"
  ]

proc unitSymbolKey*(kind: UnitKind): string =
  ## Returns the shared grayscale badge for one role, independent of team.
  SymbolKeys[kind]

proc loadUnitSymbols*(): array[UnitKind, Image] =
  ## Slices the generated sheet into eight neutral cloth badges for tinting.
  let sheet = readImage(UnitSymbolsPath)
  if sheet.width != sheet.height or sheet.width < 384:
    raise newException(PixieError, "LvD symbols need a square 3 by 3 sheet.")
  for kind in UnitKind:
    let
      column = kind.ord mod 3
      row = kind.ord div 3
      left = column * sheet.width div 3 + SymbolInset
      top = row * sheet.height div 3 + SymbolInset
      right = (column + 1) * sheet.width div 3 - SymbolInset
      bottom = (row + 1) * sheet.height div 3 - SymbolInset
      badge = sheet.subImage(left, top, right - left, bottom - top)
    result[kind] = badge.resize(SymbolSize, SymbolSize)
    for pixel in result[kind].data.mitems:
      let gray = ((pixel.r.int + pixel.g.int + pixel.b.int) div 3).uint8
      pixel = rgbx(gray, gray, gray, pixel.a)
