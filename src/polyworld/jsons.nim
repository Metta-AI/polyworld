import
  std/json,
  jsony

type JsonsError* = object of CatchableError

proc readJson*(body: string, maximum: int): JsonNode =
  ## Bounds recursive JSON parsing before allocating a document tree.
  if body.len > maximum:
    raise newException(JsonsError, "JSON exceeds the byte limit")
  var
    depth = 0
    quoted, escaped: bool
  for character in body:
    if quoted:
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == '"':
        quoted = false
    else:
      case character
      of '"':
        quoted = true
      of '{', '[':
        inc depth
        if depth > 64:
          raise newException(JsonsError, "JSON nesting exceeds 64 levels")
      of '}', ']':
        dec depth
      else:
        discard
  try:
    result = body.fromJson(JsonNode)
  except jsony.JsonError, ValueError:
    raise newException(JsonsError, "Invalid JSON: " & getCurrentExceptionMsg())
