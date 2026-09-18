## World-space text billboards sharing the resource-bar mesh and depth pass.

import
  std/unicode,
  chroma, silky/atlas, vmath,
  configs, worldbars

type
  WorldGlyph* = object
    offset*, size*, uv*, uvSize*: Vec2

  WorldText* = object
    size*: Vec2
    glyphs*: seq[WorldGlyph]

proc textWidth(font: FontAtlas, runes: openArray[Rune]): float32 =
  ## Measures the same glyph advances and kerning used by the billboard.
  for i, rune in runes:
    var entry: ptr LetterEntry
    if font.lookupLetter(rune, 0, entry):
      if i > 0:
        result += font.lookupKerning(runes[i - 1], rune)
      result += entry.advance

proc layoutText*(
    font: FontAtlas,
    atlasSize: int,
    text: string,
    height = 0.225'f,
    maximumWidth = 4.0'f
): WorldText =
  ## Builds a centered, ellipsized line in world units with atlas UVs.
  assert font != nil and font.lineHeight > 0 and atlasSize > 0
  if height <= 0 or maximumWidth <= 0 or text.len == 0:
    return
  let
    scale = height / font.lineHeight
    widthLimit = maximumWidth / scale
    dots = [Rune(46), Rune(46), Rune(46)]
  var
    runes: seq[Rune]
    width = 0.0'f
    overflow = false
  for rune in text.runes:
    var entry: ptr LetterEntry
    if not font.lookupLetter(rune, 0, entry):
      continue
    var advance = entry.advance
    if runes.len > 0:
      advance += font.lookupKerning(runes[^1], rune)
    if width + advance > widthLimit:
      overflow = true
      break
    runes.add rune
    width += advance
  if overflow:
    let dotWidth = font.textWidth(dots)
    if dotWidth > widthLimit:
      return
    while runes.len > 0 and font.textWidth(runes) + dotWidth > widthLimit:
      runes.setLen(runes.len - 1)
    runes.add dots
    width = font.textWidth(runes)
  result.size = vec2(width * scale, height)
  var pen = -width * 0.5'f
  for i, rune in runes:
    var entry: ptr LetterEntry
    if not font.lookupLetter(rune, 0, entry):
      continue
    if i > 0:
      pen += font.lookupKerning(runes[i - 1], rune)
    if entry.boundsWidth > 0 and entry.boundsHeight > 0:
      result.glyphs.add WorldGlyph(
        offset: vec2(
          pen + entry.boundsX,
          font.lineHeight - font.ascent - entry.boundsY - entry.boundsHeight
        ) * scale,
        size: vec2(entry.boundsWidth, entry.boundsHeight) * scale,
        uv: vec2(entry.x.float32, entry.y.float32) / atlasSize.float32,
        uvSize: vec2(entry.boundsWidth, entry.boundsHeight) / atlasSize.float32
      )
    pen += entry.advance

proc layoutNames*(
    font: FontAtlas,
    atlasSize: int,
    players: openArray[PlayerConfig]
): seq[WorldText] =
  ## Prepares immutable player labels once when the graphical match opens.
  for slot, player in players:
    result.add layoutText(font, atlasSize, player.displayName(slot))

proc addText*(
    renderer: var WorldBarRenderer,
    text: WorldText,
    anchor: Vec3,
    color = rgbx(242, 243, 247, 255)
) =
  ## Adds a text billboard and its backplate to the scene's bar batch.
  if text.glyphs.len == 0:
    return
  const Padding = 0.06'f
  renderer.addBillboardQuad(
    anchor,
    vec2(-text.size.x * 0.5'f - Padding, -Padding),
    text.size + vec2(Padding * 2),
    rgbx(5, 7, 10, 210)
  )
  for glyph in text.glyphs:
    renderer.addBillboardQuad(
      anchor,
      glyph.offset,
      glyph.size,
      color,
      glyph.uv,
      glyph.uvSize
    )
