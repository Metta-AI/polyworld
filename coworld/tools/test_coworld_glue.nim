## Unit tests for the `src/polyworld/coworld.nim` game-hosted glue that do
## not need a built Coworld binary (see `test_runtime.nim` for the full
## integration harness, including the `failPlayer` failure-marker checks).

import
  std/[os, strutils, tempfiles]
import
  ../../src/polyworld/coworld,
  ../../src/polyworld/neural_package

const
  BasicSourceCap = 256 * 1024
  PackageCap = 16 * 1024 * 1024

block readPlayerSourceDetectsZipByPrefix:
  ## A file over the ordinary BASIC-source cap, but under the package cap,
  ## must be read in full when it starts with the ZIP local-file-header
  ## magic, and stay capped at the BASIC-source limit otherwise.
  let directory = createTempDir("coworld-glue-", "")
  defer: removeDir(directory)

  let
    zipPath = directory / "package.zip"
    zipBody = "PK\x03\x04" & repeat("z", BasicSourceCap + 1024)
  writeFile(zipPath, zipBody)
  let zipRead = readPlayerSource(zipPath)
  doAssert zipRead.len == zipBody.len,
    "a ZIP-prefixed file over the BASIC cap must not be truncated to it"
  doAssert zipRead == zipBody, "a ZIP-prefixed file must be read verbatim"

  let
    basicPath = directory / "player.bas"
    basicBody = repeat("z", BasicSourceCap + 1024)
  writeFile(basicPath, basicBody)
  let basicRead = readPlayerSource(basicPath)
  doAssert basicRead.len == BasicSourceCap + 1,
    "a non-ZIP source must stay capped at the BASIC source limit"
  doAssert basicRead == basicBody[0 ..< BasicSourceCap + 1]

  echo "readPlayerSource: ZIP-prefix detection passed"

block readPlayerSourceCapsOversizePackageForAClearError:
  ## A package over the 16 MiB cap must come back one byte past the cap
  ## (never truncated to exactly 16 MiB), so the package loader can reject
  ## it with a clear "exceeds 16 MiB" error instead of trying to parse a
  ## file that now looks like a truncated ZIP.
  let directory = createTempDir("coworld-glue-", "")
  defer: removeDir(directory)

  let path = directory / "huge.zip"
  block writeOversizePackage:
    let file = open(path, fmWrite)
    defer: file.close()
    file.write("PK\x03\x04")
    file.setFilePos(PackageCap + 4)
    file.write("\0")

  doAssert getFileSize(path) == PackageCap + 5

  let read = readPlayerSource(path)
  doAssert read.len == PackageCap + 1,
    "an oversize package must be read exactly one byte past the 16 MiB cap"

  let error = try:
      discard readZip(read)
      ""
    except ValueError as e:
      e.msg
  doAssert error == "package exceeds 16 MiB",
    "an oversize package must fail with a clear size error, not a zip parse error: " & error

  echo "readPlayerSource: oversize package cap passed"

echo "test_coworld_glue: all checks passed"
