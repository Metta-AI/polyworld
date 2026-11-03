## Card faces drawn by silky: the art, the frame and its icons as atlas
## images, and every block of text in silky's own glyphs, fitted to its box
## the way `renderCardFace` (cardfaces.nim) fits its own. Each text size a
## face can use is baked into the atlas as a silky font, so glyphs are drawn
## one texel per pixel and stay sharp.
##
## A face shows the state of its card: a minion's live stats, the cost its
## holder pays, and the rules a card in play gained (green) or lost (red,
## struck through).

import std/[algorithm, hashes, options, os, strutils, tables, unicode]
import pixie, silky, vmath
import ../core/core, ../baseset, ../paths, cardfaces

type
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

  TextBlock* = object
    ## A block of face text and the box it is fitted to.
    runs*: seq[TextRun]
    box*: Rect
    style*: TextStyle

  LaidLine* = object
    text*, ink*: string
    struck*: bool
    at*: Vec2  ## Where its pen starts, on its baseline, in face pixels.
    width*: float32  ## The pen's travel over it.

  LaidText* = object
    ## A text block set in one baked font.
    font*: string
    lines*: seq[LaidLine]
    ink*: Rect  ## What its glyphs cover, in face pixels.

  FaceImage = object
    key: string
    at: Vec2

const
  NameInk = "#f7e6be"
  KindInk = "#e1c792"
  ClassInk = "#c1ab7e"
  SubpixelSteps = 4
    ## Horizontal glyph positions, in quarters of a pixel.
  LineSpacing = 1.08'f32  ## As `renderCardFace` sets it.

var
  bakedSizes: array[bool, seq[int]]  ## Per weight (semibold), largest first.
  emSizes: array[bool, float32]  ## Each font's units per em.
  strikeouts: array[bool, (float32, float32)]
    ## Each font's strikeout position and thickness, in font units.

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

proc everyFaceState*(cards: openArray[Card]): seq[FaceState] =
  ## The faces the table can show for these cards today: printed, every
  ## branch a card offers, live stats from 0 to 40 in every colour and
  ## every surcharge. The text sizes they fit to are baked at startup.
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

proc fontKey(semibold: bool, size: int): string =
  (if semibold: "face/semibold/" else: "face/regular/") & $size

proc artKey(card: Card): string =
  "face/art/" & card.name.toLowerAscii().replace(" ", "-")

proc frameKey(kind: CardKind): string =
  if kind == Minion: "face/frame/minion" else: "face/frame/spell"

proc gemBox(crystal: Rect): Rect =
  Rect(x: crystal.x + CrystalGem.x, y: crystal.y + CrystalGem.y,
    w: CrystalGem.w, h: CrystalGem.h)

proc faceImages(state: FaceState, hasRules: bool): seq[FaceImage] =
  ## The images a face is drawn from, back to front.
  let card = state.card
  result.add FaceImage(key: card.artKey, at: vec2(ArtRect.x, ArtRect.y))
  result.add FaceImage(key: card.kind.frameKey, at: vec2(0, 0))
  result.add FaceImage(key: "face/icon/energy", at: vec2(CostBox.x, CostBox.y))
  if card.kind == Minion:
    result.add FaceImage(key: "face/icon/power", at: PowerIconAt)
    result.add FaceImage(key: "face/icon/toughness", at: ToughnessIconAt)
  else:
    result.add FaceImage(key: "face/icon/arcane",
      at: vec2(ArcaneMarkBox.x, ArcaneMarkBox.y))
  if not hasRules:
    # Empty rules have no invented gameplay text.
    result.add FaceImage(key: "face/flourish",
      at: vec2(FlourishBox.x, FlourishBox.y))

proc faceText*(state: FaceState): seq[TextBlock] =
  ## The face's text, each block in its box and style: the cost, the name,
  ## the type line, the rules, a minion's stats and the class.
  let
    card = state.card
    kind = card.kind
    cost = card.energyCost + state.extraCost
    printed = card.ruleText()
  proc add(blocks: var seq[TextBlock], text: string, box: Rect,
      style: TextStyle) =
    if text.len > 0:
      blocks.add TextBlock(runs: @[TextRun(text: text, ink: style.ink)],
        box: box, style: style)
  result.add($cost, gemBox(CostBox),
    textStyle(75, costBuff(cost, card.energyCost).ink(CostInk), true))
  result.add(card.name, NameBox,
    textStyle(60, NameInk, true, LeftAlign, minimumSize = 30))
  result.add(($kind).toUpperAscii(), TypeLine, textStyle(31, KindInk, true))
  let rules =
    if state.rules.len > 0: card.ruleRuns(state.rules)
    elif printed.len > 0: @[TextRun(text: printed, ink: RulesInk)]
    else: @[]
  if rules.len > 0:
    result.add TextBlock(runs: rules, box: RulesBox,
      style: textStyle(43, RulesInk, minimumSize = 28, wrap = true))
  if kind == Minion:
    let
      power = if state.power >= 0: state.power else: card.power
      toughness = if state.toughness >= 0: state.toughness else: card.toughness
    result.add($power, PowerBox,
      textStyle(68, statBuff(power, card.power).ink(StatInk), true))
    result.add($toughness, ToughnessBox,
      textStyle(68, statBuff(toughness, card.toughness).ink(StatInk), true))
  if card.class.isSome:
    result.add(card.class.get.className.toUpperAscii(), ClassBox,
      textStyle(26, ClassInk, true))

proc readStrikeout(path: string): (float32, float32) =
  ## The OS/2 table's strikeout, which pixie draws strikethrough with.
  let data = readFile(path)
  proc u16(at: int): int = (data[at].ord shl 8) or data[at + 1].ord
  proc s16(at: int): int =
    result = u16(at)
    if result >= 0x8000: result -= 0x10000
  for i in 0 ..< u16(4):
    let entry = 12 + i * 16
    if data[entry ..< entry + 4] == "OS/2":
      let table = (u16(entry + 8) shl 16) or u16(entry + 10)
      return (s16(table + 28).float32, s16(table + 26).float32)

proc addFaceAssets*(builder: AtlasBuilder,
    cardAssets = artworkRoot() / "cards") =
  ## What silky draws faces from, and the card back. The fonts are baked at
  ## every size today's faces fit their text to, and at every size a rules
  ## box can shrink to, for rules that change in play.
  initCardAssets(cardAssets)
  proc add(name: string, image: Image) =
    if name notin builder.atlas.entries and not builder.addImage(name, image):
      raise newException(IOError, "Card face images do not fit the UI atlas")
  add("card/back", renderCardBack())
  for card in baseCards:
    add(card.artKey, card.cardArtImage())
  add(Minion.frameKey, frameImage(Minion))
  add(Spell.frameKey, frameImage(Spell))
  add("face/icon/energy", energyIcon())
  add("face/icon/power", powerIcon())
  add("face/icon/toughness", toughnessIcon())
  let arcane = newImage(ArcaneMarkBox.w.int, ArcaneMarkBox.h.int)
  arcane.drawArcaneMark(vec2(ArcaneMarkBox.x, ArcaneMarkBox.y))
  add("face/icon/arcane", arcane)
  let flourish = newImage(FlourishBox.w.int, FlourishBox.h.int)
  flourish.drawFlourish(vec2(FlourishBox.x, FlourishBox.y))
  add("face/flourish", flourish)

  var sizes: array[bool, set[uint8]]
  for state in everyFaceState(baseCards):
    for text in state.faceText():
      let fitted = fitFaceText(text.runs, text.box, text.style)
      sizes[text.style.semibold].incl fitted.arrangement.fonts[0].size.uint8
  for size in 28'u8 .. 43'u8:
    sizes[false].incl size
  for semibold in [false, true]:
    let path = cardAssets / (if semibold: "fonts/Grenze-SemiBold.ttf"
      else: "fonts/Grenze-Regular.ttf")
    emSizes[semibold] = readTypeface(path).scale
    strikeouts[semibold] = readStrikeout(path)
    bakedSizes[semibold].setLen(0)
    for size in sizes[semibold]:
      builder.addFont(path, fontKey(semibold, size.int), size.float32,
        subpixelSteps = SubpixelSteps)
      bakedSizes[semibold].add size.int
    bakedSizes[semibold].sort(Descending)

proc advance(font: FontAtlas, text: string): float32 =
  ## The pen's travel over `text`, as silky's drawText moves it.
  var
    i = 0
    entry: ptr LetterEntry
  while i < text.len:
    let rune = text.runeAt(i)
    i += rune.size
    if font.lookupLetter(rune, 0, entry):
      result += entry.advance
    if i < text.len:
      result += font.lookupKerning(rune, text.runeAt(i))

proc inkAround(font: FontAtlas, text: string): Rect =
  ## What the glyphs of `text` cover, from a pen at the origin on the
  ## baseline.
  var
    i = 0
    pen = 0'f32
    left, top = high(float32)
    right, bottom = low(float32)
    entry: ptr LetterEntry
  while i < text.len:
    let rune = text.runeAt(i)
    i += rune.size
    if font.lookupLetter(rune, 0, entry):
      if entry.boundsWidth > 0 and entry.boundsHeight > 0:
        left = min(left, pen + entry.boundsX)
        right = max(right, pen + entry.boundsX + entry.boundsWidth)
        top = min(top, entry.boundsY)
        bottom = max(bottom, entry.boundsY + entry.boundsHeight)
      pen += entry.advance
    if i < text.len:
      pen += font.lookupKerning(rune, text.runeAt(i))
  if left > right:
    return Rect()
  Rect(x: left, y: top, w: right - left, h: bottom - top)

proc lines(font: FontAtlas, text: TextBlock): seq[LaidLine] =
  ## A line per paragraph of every run, wrapped to the box if the block
  ## wraps; not yet placed.
  var paragraphs: seq[LaidLine]
  var current = LaidLine(ink: text.runs[0].ink, struck: text.runs[0].struck)
  for run in text.runs:
    let parts = run.text.split('\n')
    for i, part in parts:
      if i > 0:
        paragraphs.add current
        current = LaidLine(ink: run.ink, struck: run.struck)
      if current.text.len == 0:
        current.ink = run.ink
        current.struck = run.struck
      current.text.add part
  paragraphs.add current
  for paragraph in paragraphs:
    if not text.style.wrap:
      result.add paragraph
      continue
    var line = paragraph
    line.text = ""
    let words = paragraph.text.split(' ')
    for word in words:
      let candidate = if line.text.len == 0: word else: line.text & " " & word
      if line.text.len > 0 and font.advance(candidate) > text.box.w:
        result.add line
        line.text = word
      else:
        line.text = candidate
    result.add line
  for line in result.mitems:
    line.width = font.advance(line.text)

proc layout*(fonts: Table[string, FontAtlas], text: TextBlock): LaidText =
  ## Sets the block in the largest baked size that fits its box, down to
  ## its minimum, and centres its ink in the box vertically, as
  ## `renderCardFace` does.
  let semibold = text.style.semibold
  for size in bakedSizes[semibold]:
    if size.float32 > text.style.size:
      continue
    let
      font = fonts[fontKey(semibold, size)]
      step = size.float32 * LineSpacing
    var
      laid = font.lines(text)
      ink = Rect()
    for i, line in laid.mpairs:
      let
        left = if text.style.alignment == CenterAlign:
          (text.box.w - line.width) / 2 else: 0'f32
        around = font.inkAround(line.text)
      line.at = vec2(left, i.float32 * step)
      if around.w > 0:
        let placed = Rect(x: left + around.x, y: line.at.y + around.y,
          w: around.w, h: around.h)
        ink = if ink.w == 0: placed else: ink or placed
    result = LaidText(font: fontKey(semibold, size), lines: laid, ink: ink)
    if (ink.w <= text.box.w and ink.h <= text.box.h) or
        size.float32 <= text.style.minimumSize:
      break
  # Into the box: centred on the ink's height, from its left edge.
  let shift = vec2(text.box.x,
    text.box.y + (text.box.h - result.ink.h) / 2 - result.ink.y)
  for line in result.lines.mitems:
    line.at += shift
  result.ink.x += shift.x
  result.ink.y += shift.y

proc paintText(sk: Silky, text: TextBlock, origin: Vec2) =
  let laid = sk.atlas.fonts.layout(text)
  if laid.font.len == 0:
    return
  let
    font = sk.atlas.fonts[laid.font]
    semibold = text.style.semibold
    scale = font.size / emSizes[semibold]
    strikeTop = strikeouts[semibold][0] * scale
    strikeHeight = strikeouts[semibold][1] * scale
  for line in laid.lines:
    let
      pen = origin + line.at
      color = parseHtmlColor(line.ink).rgbx()
    discard sk.drawText(laid.font, line.text, vec2(pen.x, pen.y - font.ascent),
      color, clip = false)
    if line.struck:
      sk.drawRect(vec2(pen.x, pen.y - strikeTop),
        vec2(line.width, strikeHeight), color)

proc paintFace*(sk: Silky, state: FaceState, origin: Vec2) =
  ## Queues the whole face at `origin`, one face pixel per UI unit: its
  ## images, then its text.
  let text = state.faceText()
  var hasRules = false
  for piece in text:
    if piece.box == RulesBox:
      hasRules = true
  for image in state.faceImages(hasRules):
    sk.drawImage(image.key, origin + image.at)
  for piece in text:
    sk.paintText(piece, origin)
