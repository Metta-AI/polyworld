import
  std/[os, strutils],
  bassy, benchy,
  polyworld/arrays

const Directory = currentSourcePath().parentDir

let
  original = readFile(Directory / "original.bas")
  converted = readFile(
    Directory / "../../examples/gods_of_the_arena/players/neural.bas"
  )
  first = original.find("h(0) = ")
  last = original.find("\nend if\nend if\nif decision = 18", first)
  scalarSource = "dim f(27)\ndim h(16)\n" &
    original[first ..< last + "\nend if".len]
  nativeSource = converted[0 ..< converted.find("dim draftScores(9)")] & """
dim f(27)
dim h(16)
dim logits(17)
linear(f, encoder, encoderBias, h, 25, 16)
relu(h, 16)
linear(h, decoder, decoderBias, logits, 16, 18)
decision = argmax(logits, 18)
if logits(decision) <= -2147483647 then decision = 0
"""
var schema = initHost()
schema.addArrayFunctions()
var
  scalar = initRuntime(compile(scalarSource))
  native = initRuntime(compile(nativeSource, schema), schema)
for trial in 0 ..< 256:
  for i in 0 ..< 25:
    let value = int32((trial * 97 + i * 37) mod 257 - 128)
    scalar.setArray("f", int32(i), value)
    native.setArray("f", int32(i), value)
  scalar.restart()
  native.restart()
  discard scalar.run()
  discard native.run()
  doAssert scalar.getGlobal("decision") == native.getGlobal("decision")
  for i in 0 ..< 16:
    doAssert scalar.getArray("h", int32(i)) == native.getArray("h", int32(i))
echo "Combat inference parity: 256 feature vectors"
echo "Scalar instructions/work: ", scalar.instructionsUsed, "/", scalar.workUsed
echo "Native instructions/work: ", native.instructionsUsed, "/", native.workUsed
echo "Scalar/native VM bytes: ", scalar.memoryBytes, "/", native.memoryBytes

timeIt "1000 interpreted combat inferences", 20:
  for i in 0 ..< 1000:
    scalar.restart()
    discard scalar.run()
timeIt "1000 native combat inferences", 20:
  for i in 0 ..< 1000:
    native.restart()
    discard native.run()
