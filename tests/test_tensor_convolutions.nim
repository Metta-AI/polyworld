import
  std/math,
  bassy,
  polyworld/tensors

var host = initHost()
host.addTensorFunctions()
var runtime = initRuntime(compile("""
dim shape(2)
dim kernelShape(3)
dim vector(0)
dim data(8)
shape(0) = 1
shape(1) = 3
shape(2) = 3
input = tensorCreate("float32", shape)
for i = 0 to 8
  data(i) = i + 1
next i
tensorImport(input, data)
kernelShape(0) = 1
kernelShape(1) = 1
kernelShape(2) = 2
kernelShape(3) = 2
weights = tensorCreate("float32", kernelShape)
one = tensorScalar("float32", "1")
zero = tensorScalar("float32", "0")
epsilon = tensorScalar("float32", "0.00001")
tensorFill(weights, one)
shape(1) = 2
shape(2) = 2
output = tensorCreate("float32", shape)
tensorConv2d(input, weights, zero, 1, 0, output)
sums = tensorExport(output)
tensorGroupNorm(output, one, zero, 1, epsilon, output)
normalized = tensorExport(output)
""", host), host)
discard runtime.run()
let sums = runtime.arrayView(runtime.getGlobalValue("sums"))
for i, value in [12, 16, 24, 28]:
  doAssert abs(sums[i].asFixed.toFloat64 - float(value)) < 0.0001
let normalized = runtime.arrayView(runtime.getGlobalValue("normalized"))
for i, value in [12, 16, 24, 28]:
  doAssert abs(normalized[i].asFixed.toFloat64 -
    (float(value) - 20.0) / sqrt(40.00001)) < 0.0001
for statement in [
  "tensorConv2d(input, weights, zero, 0, 0, output)",
  "tensorGroupNorm(output, one, zero, 0, epsilon, output)",
  "tensorGroupNorm(output, one, zero, 1, zero, output)"
]:
  var invalid = initRuntime(compile("""
dim shape(2)
shape(0) = 1
shape(1) = 2
shape(2) = 2
input = tensorCreate("float32", shape)
output = tensorCreate("float32", shape)
weights = tensorScalar("float32", "1")
one = tensorScalar("float32", "1")
zero = tensorScalar("float32", "0")
epsilon = tensorScalar("float32", "0.00001")
""" & statement, host), host)
  var rejected = false
  try:
    discard invalid.run()
  except TensorError:
    rejected = true
  doAssert rejected
echo "Convolution, normalization and invalid argument checks passed."
