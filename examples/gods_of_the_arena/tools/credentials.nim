import
  std/[json, strutils],
  tournaments

proc parseCredentials*(text: string): JsonNode =
  ## Reads the two-space, single-line mappings written by the Softmax CLI.
  result = newJObject()
  var parents = @[result]
  for line in text.splitLines():
    let content = line.strip()
    if content.len == 0 or content.startsWith("#"):
      continue
    let indent = line.len - line.strip(leading = true, trailing = false).len
    require(indent mod 2 == 0 and '\t' notin line,
      "Invalid Softmax credentials indentation")
    let depth = indent div 2
    require(depth < parents.len,
      "Invalid Softmax credentials nesting")
    var separator = content.find(": ")
    if separator < 0 and content.endsWith(":"):
      separator = content.high
    require(separator > 0, "Expected a Softmax credentials mapping")
    var
      key = content[0 ..< separator].strip()
      value = content[separator + 1 ..< content.len].strip()
    let quotedValue = value.startsWith("'") or value.startsWith("\"")
    for scalar in [addr key, addr value]:
      if scalar[].startsWith("'"):
        require(scalar[].len >= 2 and scalar[].endsWith("'"),
          "Invalid quoted Softmax credential")
        scalar[] = scalar[][1 ..< scalar[].high].replace("''", "'")
      elif scalar[].startsWith("\""):
        try:
          scalar[] = json.parseJson(scalar[]).getStr()
        except ValueError:
          raise newException(TournamentError, "Invalid quoted Softmax credential")
      else:
        require(scalar[].len == 0 or scalar[][0] notin {'|', '>', '&', '*'},
          "Unsupported Softmax credentials value")
    parents.setLen(depth + 1)
    require(not parents[depth].hasKey(key),
      "Duplicate Softmax credentials key")
    if not quotedValue and (value.len == 0 or value == "{}"):
      let child = newJObject()
      parents[depth][key] = child
      parents.add(child)
    else:
      parents[depth][key] =
        if not quotedValue and value == "null": newJNull() else: %value
