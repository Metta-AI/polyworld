import
  std/[sets, strutils],
  zippy/crc,
  inflates

const
  MaxPackageBytes* = 16 * 1024 * 1024
  MaxPackageEntries* = 256

type
  PolicyError* = object of CatchableError
  PolicyFile* = object
    name*, bytes*: string
  Policy* = ref object
    source*: string
    files*: seq[PolicyFile]
    memoryBytes*: int64

proc fail(message: string) {.noreturn, raises: [PolicyError].} =
  ## Reports invalid packages without exposing parser defects.
  raise newException(PolicyError, message)

proc u16(bytes: string, offset: int): int =
  ## Reads one bounded little-endian ZIP field.
  if offset < 0 or offset > bytes.len - 2:
    fail("Truncated ZIP field")
  ord(bytes[offset]) or (ord(bytes[offset + 1]) shl 8)

proc u32(bytes: string, offset: int): int64 =
  ## Widens ZIP sizes before any arithmetic or allocation.
  int64(u16(bytes, offset)) or (int64(u16(bytes, offset + 2)) shl 16)

proc resourcePath*(path: string, directory = false): string =
  ## Accepts only canonical relative ZIP paths without platform aliases.
  result = path
  if directory and result.endsWith("/"):
    result.setLen(result.len - 1)
  if result.len == 0 or result[0] == '/' or
    result.contains('\\') or result.contains(':') or result.contains('\0'):
      fail("Invalid package resource path: " & path)
  for part in result.split('/'):
    if part in ["", ".", ".."]:
      fail("Invalid package resource path: " & path)

proc isPackage*(bytes: string): bool =
  ## Recognizes ZIP signatures even when staged filenames lack extensions.
  bytes.len >= 4 and bytes[0 .. 1] == "PK" and
    bytes[2 .. 3] in ["\x03\x04", "\x05\x06", "\x07\x08"]

proc loadPolicy*(bytes: string, maxSourceBytes: int): Policy =
  ## Loads raw BASIC or exactly one BASIC program and read-only ZIP resources.
  result = Policy()
  if not bytes.isPackage:
    if bytes.len > maxSourceBytes:
      fail("BASIC source exceeds the configured byte limit")
    result.source = bytes
    return
  if bytes.len > MaxPackageBytes:
    fail("ZIP package exceeds 16 MiB")
  var ending = -1
  if bytes.len >= 22:
    for i in countdown(bytes.len - 22, max(0, bytes.len - 65557)):
      if u32(bytes, i) == 0x06054b50 and
        i + 22 + u16(bytes, i + 20) == bytes.len:
          ending = i
          break
  if ending < 0:
    fail("ZIP end record not found")
  let
    count = u16(bytes, ending + 10)
    directorySize = u32(bytes, ending + 12)
    directoryOffset = u32(bytes, ending + 16)
  if u16(bytes, ending + 4) != 0 or u16(bytes, ending + 6) != 0 or
    u16(bytes, ending + 8) != count:
      fail("Multi-disk ZIP packages are unsupported")
  if count > MaxPackageEntries or count == 0:
    fail("ZIP must contain 1 through 256 entries")
  if directoryOffset + directorySize != ending:
    fail("Invalid ZIP directory bounds")
  var
    position = int(directoryOffset)
    expanded = 0'i64
    names: HashSet[string]
    intervals: seq[(int64, int64)]
    programs = 0
    pathBytes = 0'i64
  for _ in 0 ..< count:
    if position > ending - 46 or u32(bytes, position) != 0x02014b50:
      fail("Invalid ZIP directory entry")
    let
      flags = u16(bytes, position + 8)
      methodId = u16(bytes, position + 10)
      checksum = uint32(u32(bytes, position + 16))
      compressed = u32(bytes, position + 20)
      size = u32(bytes, position + 24)
      nameLength = u16(bytes, position + 28)
      extraLength = u16(bytes, position + 30)
      commentLength = u16(bytes, position + 32)
      mode = int(u32(bytes, position + 38) shr 16) and 0xf000
      local = u32(bytes, position + 42)
      next = position + 46 + nameLength + extraLength + commentLength
    if next > ending or u16(bytes, position + 34) != 0:
      fail("Invalid ZIP entry bounds or disk")
    if (flags and not 0x080e) != 0 or methodId notin [0, 8]:
      fail("Encrypted or unsupported ZIP entry")
    if mode notin [0, 0x8000, 0x4000]:
      fail("ZIP links and special files are unsupported")
    let
      name = bytes[position + 46 ..< position + 46 + nameLength]
      directory = name.endsWith("/")
      path = resourcePath(name, directory)
    if path in names:
      fail("Duplicate package resource: " & path)
    names.incl(path)
    if mode == 0x4000 and not directory:
      fail("ZIP directory is missing its trailing slash")
    expanded += size
    if expanded > MaxPackageBytes or compressed > MaxPackageBytes:
      fail("Expanded ZIP package exceeds 16 MiB")
    if directory and size != 0:
      fail("ZIP directories cannot contain data")
    let basic = not directory and path.toLowerAscii.endsWith(".bas")
    if basic and size > int64(maxSourceBytes):
      fail("BASIC source exceeds the configured byte limit")
    if local < 0 or local > directoryOffset - 30:
      fail("Invalid ZIP local header offset")
    let offset = int(local)
    if u32(bytes, offset) != 0x04034b50 or
      u16(bytes, offset + 6) != flags or
      u16(bytes, offset + 8) != methodId:
        fail("ZIP local and directory headers disagree")
    let
      localNameLength = u16(bytes, offset + 26)
      start = local + 30 + localNameLength + u16(bytes, offset + 28)
      finish = start + compressed
    if finish > directoryOffset or start > directoryOffset or
      localNameLength != nameLength:
        fail("Truncated ZIP entry")
    if bytes[offset + 30 ..< offset + 30 + localNameLength] != name:
      fail("ZIP entry names disagree")
    if (flags and 8) == 0 and
      (u32(bytes, offset + 14) != int64(checksum) or
      u32(bytes, offset + 18) != compressed or
      u32(bytes, offset + 22) != size):
        fail("ZIP entry sizes or checksums disagree")
    var entryEnd = finish
    if (flags and 8) != 0:
      var descriptor = int(finish)
      if descriptor > int(directoryOffset) - 12:
        fail("Truncated ZIP data descriptor")
      if u32(bytes, descriptor) == 0x08074b50:
        descriptor += 4
      if descriptor > int(directoryOffset) - 12 or
        u32(bytes, descriptor) != int64(checksum) or
        u32(bytes, descriptor + 4) != compressed or
        u32(bytes, descriptor + 8) != size:
          fail("ZIP data descriptor disagrees with directory")
      entryEnd = int64(descriptor + 12)
    for interval in intervals:
      if local < interval[1] and interval[0] < entryEnd:
        fail("Overlapping ZIP entries")
    intervals.add (local, entryEnd)
    let raw = bytes[int(start) ..< int(finish)]
    var contents: string
    case methodId
    of 0:
      contents = raw
    of 8:
      try:
        contents = inflateBounded(raw, int(size))
      except ZippyError as error:
        fail("Invalid deflate entry " & path & ": " & error.msg)
    else:
      fail("Unsupported ZIP compression")
    if contents.len != int(size) or crc32(contents) != checksum:
      fail("ZIP size or checksum mismatch: " & path)
    if basic:
      inc programs
      result.source = contents
    elif not directory:
      pathBytes += int64(path.len)
      result.files.add PolicyFile(name: path, bytes: contents)
    position = next
  if position != ending or programs != 1:
    fail("ZIP package must contain exactly one .bas file")
  result.memoryBytes = expanded + pathBytes + int64(count) * 128

proc readPolicyBytes*(path: string): string =
  ## Bounds reads for both raw sources and extensionless staged packages.
  try:
    let input = open(path, fmRead)
    defer:
      input.close()
    result = newString(MaxPackageBytes + 1)
    result.setLen(input.readBuffer(result[0].addr, result.len))
  except IOError, OSError:
    fail("Cannot read policy: " & getCurrentExceptionMsg())

proc readPolicy*(path: string, maxSourceBytes: int): Policy =
  ## Loads a policy file through the same bounded local and hosted path.
  loadPolicy(readPolicyBytes(path), maxSourceBytes)

proc resource*(policy: Policy, path: string): string =
  ## Resolves an exact resource name solely inside the policy package.
  let name = resourcePath(path)
  if policy != nil:
    for file in policy.files:
      if file.name == name:
        return file.bytes
  fail("Missing package resource: " & name)
