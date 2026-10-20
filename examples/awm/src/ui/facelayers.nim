## A card face as the few layers it is drawn from, live, every frame: the
## art, the chrome (the frame with its crystals and icons) and one patch per
## block of text. The text patches are cut from the chrome they sit on and
## drawn onto it exactly as `renderCardFace` draws text, so a face drawn
## 1:1 is the reference composite: every patch is opaque where the chrome
## is, and only the chrome blends over the art.
##
## Live state folds in, green when it helps whoever holds the card and red
## when it hurts: the cost they pay now, a minion's live stats, and the
## rules a card in play gained (green) or lost (red, struck through).
##
## This module lays faces out and makes their parts; cardrenderer.nim packs
## the parts into the atlas and draws faces, on the table and in the HUD.

import std/[hashes, options, strutils, tables]
import pixie
import ../core/core, cardfaces

type
  FaceLayer* = object
    part*: string  ## The part this layer draws.

  FacePart* = object
    ## An image a face draws, and where its top left sits on the face, in
    ## whole pixels: it is drawn one texel per face pixel.
    image*: Image
    at*: Vec2

  FaceState* = object
    ## Everything a face shows. Stats below 0 are the printed ones.
    card*: Card
    power*, toughness*: int
    rules*: seq[RuleLine]
      ## A card in play's rules against its printed ones (`ruleLines`);
      ## empty for the printed rules.
    extraCost*: int
      ## What its holder pays on top of the printed cost: the off-class
      ## surcharge.

const
  NameInk = "#f7e6be"
  KindInk = "#e1c792"
  ClassInk = "#c1ab7e"
  PatchPad = 8
    ## Chrome kept round a patch's ink, so the ink's blur at a distance
    ## (its mipmaps, down to the third level) stays inside the patch
    ## instead of being cut off at its edge.
  ArtWindow = Rect(x: 25, y: 112, w: 550, h: 421)
    ## The frame's window onto the art, with its border's anti-aliased
    ## edge: a patch here would hide the art or blend that edge twice.
  Crystal = CostBox
    ## The cost crystal: only the cost's own text is cut over it.

var
  parts: Table[string, FacePart]
    ## Every part laid out so far. Kept for the life of the program: the
    ## faces a game shows are few, and their text repeats.
  newParts: seq[string]  ## Parts made since the last `takeNewParts`.
  chromes: array[CardKind, Image]
  canvases: array[CardKind, Image]
    ## A face-sized copy of each chrome that text is drawn onto and cut
    ## from, then cleaned: drawing at the face's own size and coordinates
    ## gives exactly the face's pixels, down to pixie's rounding.

proc chrome(kind: CardKind): Image =
  if chromes[kind].isNil:
    chromes[kind] = renderChrome(kind)
  chromes[kind]

proc addPart(name: string, make: proc(): FacePart) =
  if name notin parts:
    parts[name] = make()
    newParts.add name

proc registerPart*(name: string, part: FacePart) =
  ## A part made outside a face layout, such as a whole flattened face. Its
  ## maker packs it; it isn't listed by `takeNewParts`.
  parts[name] = part

proc hasPart*(name: string): bool =
  name in parts

proc facePart*(name: string): FacePart =
  ## A part some face has laid out.
  parts[name]

proc takeNewParts*(): seq[string] =
  ## Parts laid out since the last call, which the atlas still needs.
  result = newParts
  newParts.setLen(0)

proc artPart(card: Card): string =
  result = "face/art/" & card.name.toLowerAscii().replace(" ", "-")
  addPart(result, proc(): FacePart =
    FacePart(image: card.cardArtImage(), at: vec2(ArtRect.x, ArtRect.y)))

proc frameName(kind: CardKind): string =
  ## Spells and trinkets share a frame, and so their chrome and patches.
  if kind == Minion: "minion" else: "spell"

proc chromePart(kind: CardKind): string =
  result = "face/chrome/" & kind.frameName
  addPart(result, proc(): FacePart =
    FacePart(image: chrome(kind), at: vec2(0, 0)))

proc patchArea(ink: Rect, avoid: openArray[Rect]): Rect =
  ## The ink and its pad, inside the face and clear of the `avoid` areas:
  ## the side of the pad facing one is cut back to it.
  var
    left = max(0'f32, ink.x - PatchPad)
    top = max(0'f32, ink.y - PatchPad)
    right = min(CardFaceWidth.float32, ink.x + ink.w + PatchPad)
    bottom = min(CardFaceHeight.float32, ink.y + ink.h + PatchPad)
  for area in avoid:
    let
      areaRight = area.x + area.w
      areaBottom = area.y + area.h
    if left >= areaRight or right <= area.x or top >= areaBottom or
        bottom <= area.y:
      continue
    if ink.y >= areaBottom:
      top = max(top, areaBottom)
    elif ink.y + ink.h <= area.y:
      bottom = min(bottom, area.y)
    elif ink.x >= areaRight:
      left = max(left, areaRight)
    elif ink.x + ink.w <= area.x:
      right = min(right, area.x)
    else:
      raiseAssert "face text over an area it must keep clear of"
  Rect(x: left, y: top, w: right - left, h: bottom - top)

proc cutPatch(kind: CardKind, area: Rect,
    draw: proc(canvas: Image)): FacePart =
  ## Draws onto a face-sized copy of the chrome, cuts `area` out, then puts
  ## the chrome's pixels back.
  let clean = chrome(kind)
  if canvases[kind].isNil:
    canvases[kind] = clean.copy()
  let canvas = canvases[kind]
  draw(canvas)
  let
    left = int(area.x)
    top = int(area.y)
    width = int(area.w)
    height = int(area.h)
  result = FacePart(image: canvas.subImage(left, top, width, height),
    at: vec2(area.x, area.y))
  for y in top ..< top + height:
    let row = y * canvas.width
    for x in left ..< left + width:
      canvas.data[row + x] = clean.data[row + x]

proc textLayer(layers: var seq[FaceLayer], kind: CardKind,
    runs: openArray[TextRun], box: Rect, style: TextStyle) =
  ## A block of text in its box, as a patch of the chrome under it. Text in
  ## the crystal is cut over it; any other text keeps clear of it.
  if runs.len == 0:
    return
  let inCrystal = overlaps(box, Crystal)
  var name = "face/text/" & kind.frameName & "/" & $box.x & "," & $box.y &
    "," & $box.w & "," & $box.h & "/" & $style.size & "/" &
    $style.minimumSize & "/" & $style.semibold & "/" & $style.alignment &
    "/" & $style.wrap
  for run in runs:
    name.add "/" & run.ink & (if run.struck: "/struck/" else: "/") &
      $run.text.len & ":" & run.text
  let fitted = @runs
  addPart(name, proc(): FacePart =
    let
      text = fitFaceText(fitted, box, style)
      area =
        if inCrystal: patchArea(text.ink, [ArtWindow])
        else: patchArea(text.ink, [ArtWindow, Crystal])
    cutPatch(kind, area, proc(canvas: Image) =
      canvas.fillText(text.arrangement, translate(text.at))))
  layers.add FaceLayer(part: name)

proc textLayer(layers: var seq[FaceLayer], kind: CardKind, value: string,
    box: Rect, style: TextStyle) =
  if value.len > 0:
    layers.textLayer(kind, [TextRun(text: value, ink: style.ink)], box, style)

proc flourishLayer(layers: var seq[FaceLayer], kind: CardKind) =
  ## The ornament an empty rules box shows instead of text.
  let name = "face/flourish/" & kind.frameName
  addPart(name, proc(): FacePart =
    cutPatch(kind, patchArea(FlourishBox, [ArtWindow, Crystal]),
      proc(canvas: Image) = canvas.drawFlourish()))
  layers.add FaceLayer(part: name)

proc gemBox(crystal: Rect): Rect =
  Rect(x: crystal.x + CrystalGem.x, y: crystal.y + CrystalGem.y,
    w: CrystalGem.w, h: CrystalGem.h)

proc faceLayers*(state: FaceState): seq[FaceLayer] =
  ## The face's layers, back to front, laying out any part not seen yet.
  let
    card = state.card
    kind = card.kind
    cost = card.energyCost + state.extraCost
    printed = card.ruleText()
    rules =
      if state.rules.len > 0: card.ruleRuns(state.rules)
      elif printed.len > 0: @[TextRun(text: printed, ink: RulesInk)]
      else: @[]
  result.add FaceLayer(part: card.artPart)
  result.add FaceLayer(part: chromePart(kind))
  result.textLayer(kind, $cost, gemBox(CostBox),
    textStyle(75, costBuff(cost, card.energyCost).ink(CostInk), true))
  result.textLayer(kind, card.name, NameBox,
    textStyle(60, NameInk, true, LeftAlign, minimumSize = 30))
  result.textLayer(kind, ($kind).toUpperAscii(), TypeLine,
    textStyle(31, KindInk, true))
  if rules.len > 0:
    result.textLayer(kind, rules, RulesBox,
      textStyle(43, RulesInk, minimumSize = 28, wrap = true))
  else:
    result.flourishLayer(kind)
  if kind == Minion:
    let
      power = if state.power >= 0: state.power else: card.power
      toughness = if state.toughness >= 0: state.toughness else: card.toughness
    result.textLayer(kind, $power, PowerBox,
      textStyle(68, statBuff(power, card.power).ink(StatInk), true))
    result.textLayer(kind, $toughness, ToughnessBox,
      textStyle(68, statBuff(toughness, card.toughness).ink(StatInk), true))
  if card.class.isSome:
    result.textLayer(kind, card.class.get.className.toUpperAscii(), ClassBox,
      textStyle(26, ClassInk, true))

proc everyFaceState*(cards: openArray[Card]): seq[FaceState] =
  ## The faces the table can show for these cards today: printed, every
  ## branch a card offers, live stats from 0 to 40 in every colour and
  ## every surcharge. Laying them out at startup puts all their parts in the
  ## atlas before the first frame. Changed rules are laid out when first
  ## shown: there are too many ways for them to change.
  for card in cards:
    result.add FaceState(card: card, power: -1, toughness: -1)
    for option in card.everyOption():
      result.add FaceState(card: card.optionCard(option), power: -1,
        toughness: -1)
    for extra in 1 .. OffClassCost:
      result.add FaceState(card: card, power: -1, toughness: -1,
        extraCost: extra)
    if card.kind == Minion:
      for value in 0 .. 40:
        # Below, at and above the printed value cover all three inks.
        result.add FaceState(card: card, power: value, toughness: value)

proc hash*(state: FaceState): Hash =
  ## Faces are cached by what they show. A card is known by its printed
  ## data and its rules, by identity: rules are built once per card and
  ## shared by every copy, and a branch of a choice is a rules list of its
  ## own.
  var h: Hash = 0
  h = h !& hash(state.card.name)
  h = h !& hash(state.card.energyCost)
  h = h !& hash(state.card.kind)
  for rule in state.card.rules:
    h = h !& hash(cast[pointer](rule))
  h = h !& hash(state.power)
  h = h !& hash(state.toughness)
  for line in state.rules:
    h = h !& hash(cast[pointer](line.rule)) !& ord(line.change)
  h = h !& hash(state.extraCost)
  !$h

proc `==`*(a, b: FaceState): bool =
  if a.card.name != b.card.name or a.card.energyCost != b.card.energyCost or
      a.card.kind != b.card.kind or a.card.class != b.card.class or
      a.card.rules.len != b.card.rules.len:
    return false
  for i in 0 ..< a.card.rules.len:
    if cast[pointer](a.card.rules[i]) != cast[pointer](b.card.rules[i]):
      return false
  if a.card.kind == Minion and
      (a.card.power != b.card.power or a.card.toughness != b.card.toughness):
    return false
  if a.rules.len != b.rules.len:
    return false
  for i in 0 ..< a.rules.len:
    if cast[pointer](a.rules[i].rule) != cast[pointer](b.rules[i].rule) or
        a.rules[i].change != b.rules[i].change:
      return false
  a.power == b.power and a.toughness == b.toughness and
    a.extraCost == b.extraCost
