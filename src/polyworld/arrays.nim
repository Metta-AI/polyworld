## Deterministic native array arithmetic for every Polyworld BASIC host.

import bassy

type
  ArrayOperation = enum
    Add, Multiply, Copy, Fill, Dot

proc count(value: Value): int =
  ## Accepts a positive, exact element count without narrowing first.
  let size = value.asInt
  if size <= 0:
    raise newException(BasicError, "array count must be positive")
  int(size)

proc requireLength(values: ArrayView, size: int) =
  ## Checks a prefix before any kernel runs or output changes.
  if size > values.len:
    raise newException(BasicError, "array is smaller than the requested shape")

proc linear(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Evaluates bias-first, row-major affine rows in BASIC arithmetic order.
  let
    inputs = runtime.arrayView(arguments[0])
    weights = runtime.arrayView(arguments[1])
    biases = runtime.arrayView(arguments[2])
    outputs = runtime.arrayView(arguments[3], writable = true)
    width = count(arguments[4])
    height = count(arguments[5])
    cells = int64(width) * int64(height)
  inputs.requireLength(width)
  biases.requireLength(height)
  outputs.requireLength(height)
  if cells > int64(weights.len):
    raise newException(BasicError, "linear weights do not fit the shape")
  if outputs.overlaps(inputs) or outputs.overlaps(weights) or
    outputs.overlaps(biases):
      raise newException(BasicError, "linear output must use separate storage")
  runtime.chargeOperations(2 * cells + 2 * int64(height))
  for row in 0 ..< height:
    var total = biases[row]
    for column in 0 ..< width:
      total = total + inputs[column] * weights[row * width + column]
    outputs[row] = total
  toValue(0)

proc relu(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Replaces negative values in a mutable prefix with integer zero.
  let
    values = runtime.arrayView(arguments[0], writable = true)
    size = count(arguments[1])
  values.requireLength(size)
  runtime.chargeOperations(2 * int64(size))
  for i in 0 ..< size:
    if values[i] < toValue(0):
      values[i] = toValue(0)
  toValue(0)

proc maximum(masked: bool): ContextHostProc =
  ## Creates a first-index argmax with optional nonzero eligibility masks.
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Validates and meters a maximum search before reading its elements.
    let
      values = runtime.arrayView(arguments[0])
      size = count(arguments[if masked: 2 else: 1])
      mask =
        if masked:
          runtime.arrayView(arguments[1])
        else:
          values
    values.requireLength(size)
    if masked:
      mask.requireLength(size)
    runtime.chargeOperations(int64(size) * (if masked: 2 else: 1))
    var best = -1
    for i in 0 ..< size:
      if masked and not mask[i].asBool:
        continue
      if best < 0 or values[best] < values[i]:
        best = i
    toValue(best)

proc arithmetic(operation: ArrayOperation): ContextHostProc =
  ## Creates a bounded elementwise kernel or ordered dot product.
  result = proc(runtime: Runtime, arguments: openArray[Value]): Value =
    ## Reserves all work before touching the destination array.
    let
      binary = operation in {Add, Multiply}
      size = count(arguments[if binary: 3 else: 2])
      left = runtime.arrayView(arguments[0], operation == Fill)
      right =
        if operation in {Add, Multiply, Dot}:
          runtime.arrayView(arguments[1])
        else:
          left
      outputs =
        case operation
        of Add, Multiply:
          runtime.arrayView(arguments[2], writable = true)
        of Copy:
          runtime.arrayView(arguments[1], writable = true)
        of Fill, Dot:
          left
    left.requireLength(size)
    right.requireLength(size)
    outputs.requireLength(size)
    if operation == Fill and arguments[1].kind == StringValue:
      raise newException(BasicError, "dataFill requires a number")
    runtime.chargeOperations(int64(size) * (if operation == Dot: 2 else: 1))
    var total = toValue(0)
    for i in 0 ..< size:
      case operation
      of Add:
        outputs[i] = left[i] + right[i]
      of Multiply:
        outputs[i] = left[i] * right[i]
      of Copy:
        outputs[i] = left[i]
      of Fill:
        outputs[i] = arguments[1]
      of Dot:
        total = total + left[i] * right[i]
    total

proc addArrayFunctions*(host: var Host) =
  ## Registers generic numeric operations without prescribing a network.
  discard host.addFunction("linear", 6, linear)
  discard host.addFunction("relu", 2, relu)
  discard host.addFunction("argmax", 2, maximum(false))
  discard host.addFunction("argmaxMasked", 3, maximum(true))
  discard host.addFunction("dataAdd", 4, arithmetic(Add))
  discard host.addFunction("dataMultiply", 4, arithmetic(Multiply))
  discard host.addFunction("dataCopy", 3, arithmetic(Copy))
  discard host.addFunction("dataFill", 3, arithmetic(Fill))
  discard host.addFunction("dataDot", 3, arithmetic(Dot))
