## Polyworld neural packages: a ZIP of exactly manifest.json, policy.bas and
## model.bin, checked against a game's contract. Parsing is strict: any
## unknown key, missing file, hash mismatch, size overflow or contract
## mismatch rejects the package. The Python staging validator
## (coworld/runtime/neural_package.py) mirrors these rules. How a game plugs
## in: docs/neural-policies.md.

import
  std/[json, math, strutils],
  crunchy,
  boundedinflate, neural_actor

export neural_actor

const
  PackageFiles* = ["manifest.json", "policy.bas", "model.bin"]
  MaxPackageBytes* = 16 * 1024 * 1024
  MaxPolicyBytes* = 256 * 1024
  MaxManifestBytes* = 64 * 1024
  MaxModelBytes* = 8 + 24 + 128 + 4 * 32 + 4 * MaxActorParameters
    ## The largest valid model.bin (32 heads, MaxActorParameters weights).
  MaxZipEntries* = 16
  ZipMagic* = "PK\x03\x04"
  ManifestKeys* = ["schema", "observation_contract", "action_contract",
    "decision_period", "files", "model", "decoder"]
    ## Top-level keys every contract accepts (a game may add more).
  RequiredManifestKeys* = ["schema", "observation_contract", "action_contract",
    "decision_period", "files", "model"]
  ModelKeys* = ["format", "inputs", "hidden", "heads"]
  DecoderKeys* = ["mode", "temperature"]
    ## Decoder keys every contract accepts (a game may add more).

type
  DecoderMode* = enum ArgmaxDecoder, SampleDecoder
  Decoder* = object
    ## manifest.decoder.mode (+ temperature, sample mode only).
    case mode*: DecoderMode
    of SampleDecoder:
      temperature*: float32
    of ArgmaxDecoder:
      discard

  PackageContract* = object of RootObj
    ## The package half of a game's neural contract.
    schema*: string
      ## manifest.schema, e.g. "gota-neural-basic/1".
    observationHash*, actionHash*: string
      ## Lowercase SHA-256 hex of the game's observation and action contract
      ## texts; pinned by the manifest and by the model header.
    observationSize*: int
      ## model.inputs: float32 observation length.
    headSizes*: seq[int]
      ## model.heads: categorical head sizes, in logit order.
    maxDecisionPeriod*: int
      ## decision_period must be an integer 1..maxDecisionPeriod.
    opBudget*: int
      ## Maximum inference cost per decision (neural_actor.operationCount).
    manifestKeys*: seq[string]
      ## Game top-level manifest keys beyond ManifestKeys (e.g. "goal").
    decoderKeys*: seq[string]
      ## Game decoder keys beyond DecoderKeys (e.g. "defer_script").
    parseOptions*: proc(manifest: JsonNode): RootRef {.nimcall.}
      ## Optional: validates the game's manifestKeys and decoderKeys and
      ## returns the game's options object (NeuralPackage.options). Called
      ## once the generic checks pass; raises ValueError to reject.

  NeuralPackage* = object
    ## A validated package. Read-only (getters below).
    period: int32
    policyText: string
    loaded: Actor
    decoderSpec: Decoder
    gameOptions: RootRef
    manifestText: string

proc decisionPeriod*(package: NeuralPackage): int32 = package.period

proc policy*(package: NeuralPackage): string =
  ## policy.bas, the seat's BASIC program.
  package.policyText

proc actor*(package: NeuralPackage): Actor =
  ## The loaded model.bin (the raw bytes are not kept).
  package.loaded

proc decoder*(package: NeuralPackage): Decoder = package.decoderSpec

proc options*(package: NeuralPackage): RootRef =
  ## What the contract's parseOptions returned (nil without one).
  package.gameOptions

proc manifest*(package: NeuralPackage): string = package.manifestText

proc sampling*(decoder: Decoder): bool = decoder.mode == SampleDecoder

proc temperatureOf*(decoder: Decoder): float32 =
  ## The sampling temperature (1 in argmax mode).
  if decoder.mode == SampleDecoder: decoder.temperature else: 1

proc isPackage*(bytes: string): bool = bytes.startsWith(ZipMagic)

proc sha256Hex*(data: string): string =
  ## Lowercase hex SHA-256 (file hashes and contract hashes).
  for value in sha256(cast[pointer](data.cstring), data.len):
    result.add value.toHex(2).toLowerAscii()

proc u16(s: string, p: int): int =
  if p < 0 or p + 2 > s.len: raise newException(ValueError, "truncated zip")
  ord(s[p]) or (ord(s[p+1]) shl 8)

proc u32(s: string, p: int): int =
  if p < 0 or p + 4 > s.len: raise newException(ValueError, "truncated zip")
  ord(s[p]) or (ord(s[p+1]) shl 8) or (ord(s[p+2]) shl 16) or (ord(s[p+3]) shl 24)

proc entryLimit*(name: string): int =
  ## The largest uncompressed size a package entry may declare (-1 = the
  ## name is not a package file).
  case name
  of "manifest.json": MaxManifestBytes
  of "policy.bas": MaxPolicyBytes
  of "model.bin": MaxModelBytes
  else: -1

proc readZip*(bytes: string): seq[(string, string)] =
  ## Reads every entry of a small, unencrypted, single-disk package ZIP
  ## (stored or deflate) through its central directory. Only package file
  ## names are accepted, and each entry's declared size is checked against
  ## its cap (entryLimit) before anything is decompressed; decompression is
  ## bounded by the declared size.
  if bytes.len > MaxPackageBytes:
    raise newException(ValueError, "package exceeds 16 MiB")
  var eocd = -1
  for p in countdown(bytes.len - 22, max(0, bytes.len - 22 - 65535)):
    if bytes[p] == 'P' and bytes[p+1] == 'K' and bytes[p+2] == '\x05' and bytes[p+3] == '\x06':
      eocd = p
      break
  if eocd < 0: raise newException(ValueError, "zip end record not found")
  let
    entries = u16(bytes, eocd + 10)
    cdOffset = u32(bytes, eocd + 16)
  if entries > MaxZipEntries: raise newException(ValueError, "too many zip entries")
  var p = cdOffset
  for _ in 0 ..< entries:
    if u32(bytes, p) != 0x02014b50: raise newException(ValueError, "bad zip directory")
    let
      flags = u16(bytes, p + 8)
      methodId = u16(bytes, p + 10)
      compressed = u32(bytes, p + 20)
      size = u32(bytes, p + 24)
      nameLen = u16(bytes, p + 28)
      extraLen = u16(bytes, p + 30)
      commentLen = u16(bytes, p + 32)
      local = u32(bytes, p + 42)
    if p + 46 + nameLen > bytes.len: raise newException(ValueError, "truncated zip")
    let name = bytes[p + 46 ..< p + 46 + nameLen]
    let limit = entryLimit(name)
    if limit < 0:
      raise newException(ValueError, "unexpected package entry " & name)
    if size > limit:
      raise newException(ValueError, name & " exceeds its " & $limit & " byte limit")
    if (flags and 1) != 0: raise newException(ValueError, "encrypted zip entry")
    if u32(bytes, local) != 0x04034b50: raise newException(ValueError, "bad zip entry")
    let
      dataStart = local + 30 + u16(bytes, local + 26) + u16(bytes, local + 28)
    if dataStart + compressed > bytes.len: raise newException(ValueError, "truncated zip data")
    let raw = bytes[dataStart ..< dataStart + compressed]
    var data: string
    case methodId
    of 0: data = raw
    of 8:
      try:
        data = inflateBounded(raw, size)
      except ZippyError as error:
        raise newException(ValueError, "bad deflate data for " & name & ": " & error.msg)
    else: raise newException(ValueError, "unsupported zip compression " & $methodId)
    if data.len != size: raise newException(ValueError, "zip size mismatch for " & name)
    result.add((name, data))
    p += 46 + nameLen + extraLen + commentLen

proc requireManifestKeys*(node: JsonNode, allowed: openArray[string], where: string) =
  ## Rejects a non-object or any key outside `allowed` (strict manifests).
  if node.kind != JObject:
    raise newException(ValueError, where & " must be an object")
  for key in node.keys:
    if key notin allowed:
      raise newException(ValueError, "unknown manifest key " & where & "." & key)

proc rejectNonFinite*(node: JsonNode, where = "manifest") =
  ## Rejects any non-finite number anywhere in a manifest (1e999 parses
  ## as infinity).
  case node.kind
  of JFloat:
    if classify(node.getFloat) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, where & " holds a non-finite number")
  of JArray:
    for item in node:
      rejectNonFinite(item, where)
  of JObject:
    for key, item in node:
      rejectNonFinite(item, where & "." & key)
  else:
    discard

proc requireInt*(node: JsonNode, key, where: string): int =
  ## A required integer key: a JSON integer (1407.0 and true are rejected).
  if not node.hasKey(key) or node[key].kind != JInt:
    raise newException(ValueError, where & "." & key & " must be an integer")
  node[key].getInt

proc requireString*(node: JsonNode, key, where: string): string =
  ## A required string key.
  if not node.hasKey(key) or node[key].kind != JString:
    raise newException(ValueError, where & "." & key & " must be a string")
  node[key].getStr

proc requireNumber*(node: JsonNode, where: string): float =
  ## A JSON number (integer or float, never a boolean).
  if node.kind notin {JInt, JFloat}:
    raise newException(ValueError, where & " must be a number")
  node.getFloat

proc requireBool*(node: JsonNode, key, where: string): bool =
  ## An optional boolean key (false when absent).
  if node.hasKey(key):
    if node[key].kind != JBool:
      raise newException(ValueError, where & "." & key & " must be true or false")
    result = node[key].getBool

proc headList(sizes: openArray[int]): string =
  result = "["
  for i, size in sizes:
    if i > 0: result.add ","
    result.add $size
  result.add "]"

proc loadActor*(data: string, contract: PackageContract): Actor =
  ## Loads a model for `contract`: the op budget, both header contract
  ## hashes, the input size and the head sizes must all match.
  result = loadActor(data, contract.opBudget)
  if result.observationContract != contract.observationHash or
      result.actionContract != contract.actionHash:
    raise newException(ValueError, "model.bin contract hashes do not match the manifest")
  if result.inputSize != contract.observationSize:
    raise newException(ValueError, "model.inputs must be " & $contract.observationSize)
  if result.headSizes != contract.headSizes:
    raise newException(ValueError, "model.heads must be " &
      headList(contract.headSizes))

proc parsePackage*(bytes: string, contract: PackageContract): NeuralPackage =
  ## Validates a package completely against `contract`; raises ValueError
  ## with the reason (never a defect, whatever the bytes).
  let entries = readZip(bytes)
  if entries.len != 3:
    raise newException(ValueError, "package must contain exactly manifest.json, policy.bas and model.bin")
  var files: array[3, string]
  var seen: array[3, bool]
  for (name, data) in entries:
    let index = PackageFiles.find(name)
    if index < 0 or seen[index]:
      raise newException(ValueError, "unexpected package entry " & name)
    seen[index] = true
    files[index] = data
  let manifest =
    try:
      parseJson(files[0])
    except JsonParsingError as error:
      raise newException(ValueError, "manifest.json is not JSON: " & error.msg)
  manifest.requireManifestKeys(@ManifestKeys & contract.manifestKeys, "manifest")
  manifest.rejectNonFinite()
  for key in RequiredManifestKeys:
    if not manifest.hasKey(key):
      raise newException(ValueError, "manifest is missing " & key)
  if manifest.requireString("schema", "manifest") != contract.schema:
    raise newException(ValueError, "manifest schema must be " & contract.schema)
  if manifest.requireString("observation_contract", "manifest") != contract.observationHash:
    raise newException(ValueError, "observation contract mismatch")
  if manifest.requireString("action_contract", "manifest") != contract.actionHash:
    raise newException(ValueError, "action contract mismatch")
  let period = manifest.requireInt("decision_period", "manifest")
  if period notin 1..contract.maxDecisionPeriod:
    raise newException(ValueError, "decision_period must be an integer 1.." &
      $contract.maxDecisionPeriod)
  result.period = int32(period)
  let fileHashes = manifest["files"]
  fileHashes.requireManifestKeys(["policy.bas", "model.bin"], "files")
  if not fileHashes.hasKey("policy.bas") or not fileHashes.hasKey("model.bin"):
    raise newException(ValueError, "files must list policy.bas and model.bin")
  if fileHashes.requireString("policy.bas", "files") != sha256Hex(files[1]):
    raise newException(ValueError, "policy.bas sha256 mismatch")
  if fileHashes.requireString("model.bin", "files") != sha256Hex(files[2]):
    raise newException(ValueError, "model.bin sha256 mismatch")
  if files[1].len > MaxPolicyBytes:
    raise newException(ValueError, "policy.bas exceeds 256 KiB")
  let model = manifest["model"]
  model.requireManifestKeys(ModelKeys, "model")
  for key in ModelKeys:
    if not model.hasKey(key):
      raise newException(ValueError, "model is missing " & key)
  if model.requireString("format", "model") != ActorMagic:
    raise newException(ValueError, "model.format must be " & ActorMagic)
  let actor = loadActor(files[2], contract)
  if model.requireInt("inputs", "model") != actor.inputSize:
    raise newException(ValueError, "model.inputs must be " & $contract.observationSize)
  if model.requireInt("hidden", "model") != actor.hiddenSize:
    raise newException(ValueError, "model.hidden does not match model.bin")
  var heads: seq[int]
  if model["heads"].kind != JArray:
    raise newException(ValueError, "model.heads must be a list of integers")
  for h in model["heads"]:
    if h.kind != JInt:
      raise newException(ValueError, "model.heads must be a list of integers")
    heads.add h.getInt
  if heads != contract.headSizes:
    raise newException(ValueError, "model.heads must be " &
      headList(contract.headSizes))
  result.loaded = actor
  result.decoderSpec = Decoder(mode: ArgmaxDecoder)
  if manifest.hasKey("decoder"):
    let decoder = manifest["decoder"]
    decoder.requireManifestKeys(@DecoderKeys & contract.decoderKeys, "decoder")
    let mode =
      if decoder.hasKey("mode"): decoder.requireString("mode", "decoder")
      else: "argmax"
    case mode
    of "argmax":
      if decoder.hasKey("temperature"):
        raise newException(ValueError, "decoder.temperature needs mode sample")
    of "sample":
      var temperature = 1'f32
      if decoder.hasKey("temperature"):
        let t = decoder["temperature"].requireNumber("decoder.temperature")
        if t < 0.01 or t > 10:
          raise newException(ValueError, "decoder.temperature must be 0.01..10")
        temperature = float32(t)
      result.decoderSpec = Decoder(mode: SampleDecoder, temperature: temperature)
    else:
      raise newException(ValueError, "decoder.mode must be argmax or sample")
  if contract.parseOptions != nil:
    result.gameOptions = contract.parseOptions(manifest)
  result.policyText = files[1]
  result.manifestText = files[0]
