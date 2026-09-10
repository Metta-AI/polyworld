import
  std/[algorithm, json, os, sequtils, sets, strutils],
  jsony,
  tooling

proc strings(source: string): seq[string] =
  ## Extracts quoted filenames from the game's small Nim asset tables.
  var position = 0
  while position < source.len:
    let first = source.find('"', position)
    if first < 0:
      break
    let last = source.find('"', first + 1)
    require(last >= 0, "Unterminated asset filename")
    let value = source[first + 1 ..< last]
    if value.len > 0 and '\n' notin value:
      result.add value
    position = last + 1

proc assignedStrings(source, marker: string): seq[string] =
  ## Extracts string values immediately following a source expression.
  var position = 0
  while position < source.len:
    let found = source.find(marker, position)
    if found < 0:
      break
    position = found + marker.len
    while position < source.len and source[position] in Whitespace:
      inc position
    if marker == "DataRoot":
      if position >= source.len or source[position] != '&':
        continue
      inc position
      while position < source.len and source[position] in Whitespace:
        inc position
    if position < source.len and source[position] == '"':
      let last = source.find('"', position + 1)
      require(last >= 0, "Unterminated filename after " & marker)
      result.add source[position + 1 ..< last]
      position = last + 1

proc readUint32(data: string, offset: int): uint32 =
  ## Reads a checked little-endian GLB header field.
  require(offset >= 0 and offset <= data.len - 4, "Truncated GLB header")
  for i in 0 ..< 4:
    result = result or (uint32(data[offset + i].ord) shl (i * 8))

proc references(asset: string): seq[string] =
  ## Reads external image and buffer paths from a GLB's JSON chunk.
  if asset.splitFile.ext != ".glb":
    return
  let
    data = readFile(asset)
    length = data.readUint32(12).int
    kind = data.readUint32(16)
  require(kind == 0x4e4f534a'u32 and length <= data.len - 20,
    "Invalid GLB JSON chunk: " & asset)
  let document = data[20 ..< 20 + length].fromJson(JsonNode)
  for key in ["images", "buffers"]:
    if not document.hasKey(key):
      continue
    for item in document[key]:
      if item.hasKey("uri"):
        let uri = item["uri"].getStr()
        if uri.len > 0 and not uri.startsWith("data:"):
          result.add asset.parentDir / uri

proc selectAssets(data: string) =
  ## Writes each game's sorted asset list including referenced GLB textures.
  let
    terrain = readFile(Root / "src/polyworld/quadterrain.nim")
    surfaces = strings(between(
      readFile(Root / "src/polyworld/terrainsurfaces.nim"),
      "SurfaceNames* = [", "]"
    ))
  for game in Games:
    let
      source = Root / "examples" / game.directory
      graphics = readFile(source / "graphics.nim")
      content = readFile(source / "content.nim")
    var selected = initHashSet[string]()
    proc add(name: string) =
      ## Includes an asset or all nonhidden files in a required directory.
      let path = data / name
      require(fileExists(path) or dirExists(path), "Missing asset: " & path)
      if dirExists(path):
        for child in walkDirRec(path, yieldFilter = {pcFile, pcLinkToFile}):
          if not child.extractFilename().startsWith("."):
            selected.incl relativePath(child, data).replace('\\', '/')
      else:
        selected.incl name
    for name in [
      "icons", "themes/main", "ui", "fonts/Rubik-Regular.ttf",
      "fonts/Rubik-Bold.ttf", "fonts/OverpassMono-Regular.ttf",
      "themes/" & game.name & "/" & game.name & "_logo.png",
      "terrain/low_poly_grass.glb"
    ]:
      add(name)
    for name in strings(between(terrain, "TreeTextures = [", "]")):
      add("terrain/handpainted_trees/" & name & ".png")
    var trees = @["tree_fir_01", "tree_fir_02"]
    if game.name == "cta":
      trees.add ["tree_fir_03", "tree_leafy_simple", "tree_leafy_double"]
    for name in trees:
      add("terrain/handpainted_trees/" & name & ".glb")
    for name in ["water_1_normal", "water_2_normal"]:
      add("terrain/water_normals/" & name & ".jpg")
    if game.name == "cta":
      add("terrain/low_poly_rocks.glb")
      for name in strings(between(terrain, "TerrainMaterials = [", "]")):
        for channel in ["color", "height"]:
          add("terrain/cartoon_textures/" & name & "_" & channel & ".png")
    else:
      add("terrain/toon_enchanted_meadow/rocks.glb")
      for name in surfaces:
        for folder in ["tiles", "stamps"]:
          for channel in ["rgb", "height"]:
            add("terrain/" & folder & "/" & name & "." & channel & ".png")
      if game.name == "gota":
        for name in ["mossy-building-stone-1", "dry-stacked-stone-1"]:
          for channel in ["rgb", "height"]:
            add("terrain/tiles/" & name & "." & channel & ".png")
    for name in assignedStrings(graphics & content, "DataRoot"):
      if name.startsWith("/") and name.splitFile.ext.len > 0:
        add(name[1 .. ^1])
    if game.name == "gota":
      for name in assignedStrings(content, "icon:"):
        if fileExists(data / "abilities" / (name & ".png")):
          add("abilities/" & name & ".png")
        elif fileExists(data / "items" / (name & ".png")):
          add("items/" & name & ".png")
    if game.name == "cta":
      let start = content.find("AbilityIconFiles*")
      require(start >= 0, "Missing CTA ability icon table")
      for name in strings(between(content[start .. ^1], "] = [", "]")):
        add("abilities/" & name & ".png")
    if game.name == "lvd":
      for name in toSeq(selected):
        if name.startsWith("characters/") and name.endsWith(".glb"):
          add(name.changeFileExt(".profile.png"))
      let props = strings(between(
        graphics, "BuildingProps = [", "BuildingPropHeights"
      ))
      for name in props & @["mineral1"]:
        for pack in ["low_poly_village", "tower_defense_kit"]:
          let path = "terrain/" & pack & "." & name & ".profile.png"
          if fileExists(data / path):
            add(path)
    for name in toSeq(selected):
      for path in references(data / name):
        let relative = relativePath(expandFilename(path), expandFilename(data))
        require(not relative.startsWith(".." & DirSep) and relative != "..",
          "GLB reference escapes asset directory: " & path)
        add(relative.replace('\\', '/'))
    let names = sorted(toSeq(selected))
    writeFile(
      source / "webdata.txt",
      "# Required replay assets at the revision in coworld/assets.json.\n" &
        names.join("\n") & "\n"
    )
    var bytes = 0'i64
    for name in names:
      bytes += getFileSize(data / name)
    echo game.name, " ", names.len, " ",
      formatFloat(bytes.float / (1024 * 1024), ffDecimal, 1), " MiB"

proc main() =
  ## Selects assets from the configured or sibling asset repository.
  require(paramCount() == 0, "Usage: nim r coworld/tools/select_assets.nim")
  selectAssets(getEnv("POLYWORLD_DATA", Root.parentDir / "polyworld_data"))

runTool(main)
