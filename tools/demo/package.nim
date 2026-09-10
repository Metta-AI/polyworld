import
  std/[algorithm, json, os, parseopt, strutils],
  crunchy, jsony, zippy,
  ../../coworld/tools/tooling

proc digest(data: string): string =
  ## Encodes the deployment manifest's SHA-256 checksum.
  for value in sha256(data):
    result.add value.toHex(2).toLowerAscii()

proc package(destination, release: string) =
  ## Copies standalone game files and writes deterministic deployment metadata.
  require(release.len > 0 and
    release.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-'}),
    "Release must contain only letters, numbers, _ or -")
  require(not fileExists(destination) and not dirExists(destination) and
    not symlinkExists(destination), "Destination already exists: " & destination)
  createDir(destination)
  var page = readFile(Root / "tools/demo/index.html")
  for game in Games:
    let
      source = Root / "examples" / game.directory
      bundle = source / "emscripten"
      target = destination / "releases" / release / game.name
    var javascript = readFile(bundle / (game.name & ".js"))
    require("configurePolyworldWebInputs" in javascript,
      game.name & " needs a live -d:emscripten build")
    let label = between(javascript, "var PACKAGE_NAME = '", "';")
    require(label.extractFilename() == game.name & ".data",
      game.name & " has an unknown asset package label")
    javascript = javascript.replace(label, game.name & ".data")
    createDir(target)
    for extension in ["html", "wasm", "data"]:
      let filename = game.name & "." & extension
      copyFile(bundle / filename, target / filename)
    writeFile(target / (game.name & ".js"), javascript)
    copyFile(source / "players/base.bas", target / "base.bas")
    let
      oldUrl = "../../examples/" & game.directory & "/emscripten/" &
        game.name & ".html?bot=../players/base.bas:" & $game.seats
      newUrl = "../releases/" & release & "/" & game.name & "/" &
        game.name & ".html?bot=base.bas:" & $game.seats
    require(page.count(oldUrl) == 1,
      "The demo must contain exactly one " & game.name & " iframe")
    page = page.replace(oldUrl, newUrl)
  while true:
    let first = page.find("    <!--")
    if first < 0:
      break
    let last = page.find("-->\n", first)
    require(last >= 0, "Unterminated demo HTML comment")
    page.delete(first .. last + 3)
  createDir(destination / "demo")
  writeFile(destination / "demo/index.html", page)
  var paths: seq[string]
  for path in walkDirRec(destination):
    paths.add path
  paths.sort()
  let files = newJObject()
  for path in paths:
    let
      data = readFile(path)
      relative = relativePath(path, destination).replace('\\', '/')
    files[relative] = %*{"bytes": data.len, "sha256": digest(data)}
    if path.splitFile.ext in [".html", ".js", ".wasm", ".data", ".bas"]:
      writeFile(path & ".gz", compress(data, level = 9, dataFormat = dfGzip))
  let manifest = %*{
    "release": release,
    "source_revision": command(["git", "rev-parse", "HEAD"]),
    "dependencies_sha256": digest(readFile(Root / "coworld/dependencies.lock")),
    "files": files
  }
  writeFile(
    destination / "releases" / release / "manifest.json",
    manifest.toJson() & "\n"
  )
  echo "Packaged ", files.len, " files for /polyworld/demo/ in ", destination

proc main() =
  ## Parses the destination and required release identifier.
  var
    parser = initOptParser(commandLineParams(), longNoVal = @["help"])
    destination, release: string
    needsRelease = false
  for kind, key, value in parser.getopt():
    case kind
    of cmdArgument:
      if needsRelease:
        release = key
        needsRelease = false
      else:
        require(destination.len == 0, "Unexpected argument: " & key)
        destination = key
    of cmdLongOption:
      require(key == "release", "Unknown option: --" & key)
      release = value
      needsRelease = value.len == 0
    of cmdShortOption:
      raise newException(PolyworldToolsError, "Unknown option: -" & key)
    of cmdEnd:
      discard
  require(destination.len > 0 and release.len > 0 and not needsRelease,
    "Usage: nim r tools/demo/package.nim DESTINATION --release RELEASE")
  package(destination, release)

runTool(main)
