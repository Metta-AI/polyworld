import
  pixie, windy,
  polyworld/common,
  content

type ArenaCursors* = object
  move*, attack*, portal*, potion*: Cursor
  abilities*: array[Ability, Cursor]

proc pointer(color: string, attack = false): Cursor =
  ## Rasterizes a crisp game pointer once for the native or browser cursor.
  let symbol =
    if attack:
      "<path d='M29 16 L44 31 M44 16 L29 31' stroke='white' stroke-width='3'/>"
    else:
      ""
  result = Cursor(kind: CustomCursor, hotspot: ivec2(4, 4), image: decodeImage(
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 48 48'>" &
    "<path d='M4 4 L6 35 L14 27 L20 41 L26 38 L19 24 L31 23 Z' " &
    "fill='" & color & "' stroke='#171923' stroke-width='4'/>" &
    "<path d='M6 7 L8 29 L14 23 L25 22 Z' fill='#fff4dc'/>" &
    symbol & "</svg>"
  ))

proc initArenaCursors*(): ArenaCursors =
  ## Reuses existing ability art and caches all cursor images before rendering.
  result.move = pointer("#77c6ff")
  result.attack = pointer("#ef5b66", true)
  result.portal = pointer("#be87ff")
  result.potion = pointer("#78dd91")
  for ability in Ability:
    let image = decodeImage(
      "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 48 48'>" &
      "<circle cx='12' cy='12' r='7' fill='#a86bf0' " &
      "stroke='#fff4dc' stroke-width='2'/>" &
      "<path d='M12 1 V7 M12 17 V23 M1 12 H7 M17 12 H23' " &
      "stroke='#fff4dc' stroke-width='2'/></svg>"
    )
    let icon = readImage(
      DataRoot & "/abilities/" & ability.abilitySpec.icon & ".png"
    ).resize(28, 28)
    image.draw(icon, translate(vec2(20, 20)))
    result.abilities[ability] = Cursor(
      kind: CustomCursor, image: image, hotspot: ivec2(12, 12)
    )
