import
  std/[strutils, random, os, tempfiles],
  zippy,
  polyworld/[policies, inflates],
  neuralfixtures

proc rejected(bytes: string, limit = 65536): bool =
  ## Requires controlled package errors rather than parser defects.
  try:
    discard loadPolicy(bytes, limit)
  except PolicyError:
    return true

proc changeWord(bytes: string, offset: int, value: uint32): string =
  ## Mutates a bounded synthetic field for malformed-package tests.
  result = bytes
  for i in 0 ..< 4:
    result[offset + i] = char((value shr (8 * i)) and 255)

echo "Testing raw BASIC and stored/deflated extensionless packages"
doAssert loadPolicy("end\n", 100).files.len == 0
for deflated in [false, true]:
  let
    bytes = zipFixture([("nested/policy.bas", "end\n"),
      ("weights.bin", repeat("data", 1000))], deflated)
    policy = loadPolicy(bytes, 65536)
    directory = createTempDir("policy-package-", "")
    path = directory / "staged"
  defer:
    removeFile(path)
    removeDir(directory)
  writeFile(path, bytes)
  doAssert readPolicy(path, 65536).source == "end\n"
  doAssert policy.resource("weights.bin") == repeat("data", 1000)
  doAssert policy.files.len == 1
  doAssert rejected(bytes, 2)
  for length in 4 ..< bytes.len:
    doAssert rejected(bytes[0 ..< length])

for files in [
  @[("weights.bin", "x")],
  @[("a.bas", "end"), ("nested/b.BAS", "end")],
  @[("a.bas", "end"), ("a.bas", "end")],
  @[("a.bas", "end"), ("../escape", "x")],
  @[("a.bas", "end"), ("/absolute", "x")],
  @[("a.bas", "end"), ("a\\b", "x")],
  @[("a.bas", "end"), ("C:relative", "x")],
  @[("a.bas", "end"), ("a/./b", "x")],
  @[("a.bas", "end"), ("a//b", "x")],
  @[("a.bas", "end"), ("a\0b", "x")]
]:
  doAssert rejected(zipFixture(files))
let
  good = zipFixture([("a.bas", "end")])
  central = good.find("PK\x01\x02")
# Encryption, links, unsupported methods, checksum, and expansion bounds fail.
doAssert rejected(good.changeWord(6, 1))
doAssert rejected(good.changeWord(central + 38, 0xa0000000'u32))
doAssert rejected(good.changeWord(central + 10, 99))
doAssert rejected(good.changeWord(central + 16, 123))
doAssert rejected(good.changeWord(central + 24, uint32(MaxPackageBytes + 1)))
doAssert rejected("PK\x03\x04" & repeat('x', MaxPackageBytes))
var many: seq[(string, string)]
for i in 0 ..< 257:
  many.add ($i & ".bas", "end")
doAssert rejected(zipFixture(many))

echo "Testing bounded DEFLATE under truncation and random corrupt data"
let packed = compress(repeat('x', 100_000), dataFormat = dfDeflate)
doAssert inflateBounded(packed, 100_000) == repeat('x', 100_000)
try:
  discard inflateBounded(packed, 10)
  doAssert false
except ZippyError:
  discard
var rng = initRand(4321)
for trial in 0 ..< 5000:
  var bytes = newString(rng.rand(0 .. 100))
  for value in bytes.mitems:
    value = char(rng.rand(255))
  try:
    discard inflateBounded(bytes, 1000)
  except ZippyError:
    discard

echo "Testing ZIP data descriptors and path memory accounting"
for deflated in [false, true]:
  let bytes = zipFixture([("a.bas", "end")], deflated, true)
  doAssert loadPolicy(bytes, 100).source == "end"
  let descriptor = bytes.find("PK\x07\x08")
  doAssert descriptor >= 0
  doAssert rejected(bytes.changeWord(descriptor + 4, 0))
let longPath = repeat('a', 1000)
let named = loadPolicy(zipFixture([("a.bas", "end"), (longPath, "x")]), 100)
doAssert named.memoryBytes >= 1004
