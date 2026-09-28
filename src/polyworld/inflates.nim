# Adapted from Zippy, MIT License, Copyright (c) 2020 Ryan Oldenburg.
# Copyright (c) 2020 Ryan Oldenburg
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Bounded decoding derived from David Bloomin's Polyworld neural fork.

import zippy/[bitstreams, common, internal]

export ZippyError

when defined(clang):
  func bitreverse16(v: uint16): uint16 {.importc: "__builtin_bitreverse16", nodecl.}
  proc reverseBits(v: uint16): uint16 {.inline.} =
    ## Reverses Huffman bits with the compiler intrinsic.
    bitreverse16(v)
else:
  import std/bitops

const
  FastBits = 9
  FastMask = (1 shl FastBits) - 1

type Huffman = object
  firstCode, firstSymbol: array[16, uint16]
  maxCodes: array[17, uint32]
  values: array[288, uint16]
  fast: array[1 shl FastBits, uint16]

proc checkedBits(b: var BitStreamReader, count: int,
    refill: static[bool] = true): uint16 =
  ## Rejects truncated bits before the reader can refill an invalid buffer.
  if b.bitsBuffered < 0:
    failEndOfBuffer()
  result = b.readBits(count, refill)
  if b.bitsBuffered < 0:
    failEndOfBuffer()

proc initHuffman(codeLengths: openArray[uint8]): Huffman =
  ## Builds bounded canonical Huffman lookup tables.
  ## See https://raw.githubusercontent.com/madler/zlib/master/doc/algorithm.txt

  var histogram: array[17, uint16]
  for i in 0 ..< codeLengths.len:
    inc histogram[codeLengths[i]]
  histogram[0] = 0

  for i in 1 ..< 16:
    if histogram[i] > (1.uint16 shl i):
      failUncompress()

  var
    code: uint32
    k: uint16
    nextCode: array[16, uint32]
  for i in 1 ..< 16:
    nextCode[i] = code
    result.firstCode[i] = code.uint16
    result.firstSymbol[i] = k
    code = code + histogram[i]
    if histogram[i] > 0.uint16 and code - 1 >= (1.uint32 shl i):
      failUncompress()
    result.maxCodes[i] = (code shl (16 - i))
    code = code shl 1
    k += histogram[i]

  result.maxCodes[16] = 1 shl 16

  for i, len in codeLengths:
    if len > 0.uint8:
      let symbolId =
        nextCode[len] - result.firstCode[len] + result.firstSymbol[len]
      result.values[symbolId] = i.uint16
      if len <= FastBits:
        let fast = (len.uint16 shl FastBits) or i.uint16
        var k = reverseBits(nextCode[len].uint16) shr (16.uint16 - len)
        while k < (1 shl FastBits):
          result.fast[k] = fast
          k += (1.uint16 shl len)
      inc nextCode[len]

proc decodeSymbolSlow(b: var BitStreamReader, h: Huffman): uint16 =
  ## Decodes a symbol outside the short-code lookup table.
  let
    k = reverseBits(b.bitBuffer.uint16)
    maxCodeLength = h.maxCodes.len.uint16
  var codeLength = FastBits.uint16 + 1
  while codeLength < maxCodeLength:
    if k.uint32 < h.maxCodes[codeLength]:
      break
    inc codeLength

  if codeLength >= 16.uint16:
    # Bad code length. Instead of raising an exception here though,
    # let the checks handling this return value call failUncompress().
    # For some reason failUncompress() here has significant performance impact
    # on M1 arm64.
    return uint16.high

  let symbolId = int(k shr (16.uint16 - codeLength)) -
    int(h.firstCode[codeLength]) + int(h.firstSymbol[codeLength])
  if symbolId < 0 or symbolId >= h.values.len:
    failUncompress()
  result = h.values[symbolId]
  b.bitBuffer = b.bitBuffer shr codeLength
  b.bitsBuffered -= codeLength.int

proc decodeSymbol(b: var BitStreamReader, h: Huffman): uint16 {.inline.} =
  ## This function is the most important for inflate performance.
  let fast = h.fast[b.bitBuffer and FastMask]
  if fast > 0.uint16:
    let codeLength = fast shr FastBits
    result = fast and FastMask
    b.bitBuffer = b.bitBuffer shr codeLength
    b.bitsBuffered -= codeLength.int
  else:
    result = b.decodeSymbolSlow(h)

template failLimit() =
  ## Rejects expansion beyond the declared entry length.
  raise newException(ZippyError, "inflated data exceeds its limit")

proc inflateBlock(
  dst: var string,
  b: var BitStreamReader,
  op: var int,
  fixedCodes: bool,
  limit: int
) =
  ## Expands a Huffman block while bounding every output write.
  var literalsHuffman, distancesHuffman: Huffman
  if fixedCodes:
    literalsHuffman = initHuffman(fixedLitLenCodeLengths)
    distancesHuffman = initHuffman(fixedDistanceCodeLengths)
  else:
    let
      hlit = b.checkedBits(5).int + 257
      hdist = b.checkedBits(5).int + 1
      hclen = b.checkedBits(4).int + 4

    if hlit > maxLitLenCodes:
      failUncompress()

    if hdist > maxDistanceCodes:
      failUncompress()

    var clcls: array[19, uint8]
    for i in 0 ..< hclen:
      clcls[clclOrder[i]] = b.checkedBits(3).uint8

    let clclsHuffman = initHuffman(clcls)

    # From RFC 1951, all code lengths form a single sequence of HLIT + HDIST.
    # This means the maximum unpacked length is 31 + 31 + 257 + 1 = 320.

    var
      unpacked: array[320, uint8]
      i: int
    while i != hlit + hdist:
      if b.bitsBuffered < 15:
        b.fillBitBuffer()
      let symbol = decodeSymbol(b, clclsHuffman)
      if b.bitsBuffered < 0:
        failEndOfBuffer()
      if symbol <= 15:
        unpacked[i] = symbol.uint8
        inc i
      elif symbol == 16:
        if i == 0:
          failUncompress()
        let
          prev = unpacked[i - 1]
          repeatCount = b.checkedBits(2).int + 3
        if i + repeatCount > unpacked.len:
          failUncompress()
        for _ in 0 ..< repeatCount:
          unpacked[i] = prev
          inc i
      elif symbol == 17:
        let repeatZeroCount = b.checkedBits(3).int + 3
        i += repeatZeroCount
      elif symbol == 18:
        let repeatZeroCount = b.checkedBits(7).int + 11
        i += repeatZeroCount
      else:
        raise newException(ZippyError, "Invalid symbol")

      if i > hlit + hdist:
        failUncompress()

    literalsHuffman = initHuffman(unpacked.toOpenArray(0, hlit - 1))
    distancesHuffman = initHuffman(unpacked.toOpenArray(hlit, hlit + hdist - 1))

  while true:
    when defined(arm64) and defined(macosx):
      b.fillBitBuffer()
      var symbol: uint16
      while true:
        symbol = decodeSymbol(b, literalsHuffman)
        if symbol <= 255 and b.bitsBuffered >= 15:
          if op >= limit:
            failLimit()
          if op >= dst.len:
            dst.setLen(min(max(op * 2, 2), limit))
          dst[op] = symbol.char
          inc op
        else:
          break
    else:
      if b.bitsBuffered < 15:
        b.fillBitBuffer()
      let symbol = decodeSymbol(b, literalsHuffman)
    if b.bitsBuffered < 0:
      failEndOfBuffer()
    if symbol <= 255:
      if op >= limit:
        failLimit()
      if op >= dst.len:
        dst.setLen(min(max(op * 2, 2), limit))
      dst[op] = symbol.char
      inc op
    elif symbol == 256:
      break
    else:
      b.fillBitBuffer()

      let lengthIdx = (symbol - 257).int
      if lengthIdx >= baseLengths.len:
        failUncompress()

      let copyLength = (
        baseLengths[lengthIdx] +
        b.checkedBits(baseLengthsExtraBits[lengthIdx].int, false) # Up to 5 bits.
      ).int

      let distanceIdx = decodeSymbol(b, distancesHuffman) # Up to 15 bits.
      if b.bitsBuffered < 0:
        failEndOfBuffer()
      if distanceIdx >= baseDistances.len.uint16:
        failUncompress()

      when sizeof(b.bitBuffer) == 4:
        if b.bitsBuffered < 13:
          b.fillBitBuffer()

      let distance = (
        baseDistances[distanceIdx] +
        b.checkedBits(baseDistanceExtraBits[distanceIdx].int, false) # Up to 13 bits.
      ).int

      if distance > op:
        failUncompress()

      if op + copyLength > limit:
        failLimit()

      if op + copyLength > dst.len:
        dst.setLen(min(limit, max(op + copyLength, dst.len * 2)))
      for i in 0 ..< copyLength:
        dst[op + i] = dst[op + i - distance]
      op += copyLength

proc inflateNoCompression(
  dst: var string,
  b: var BitStreamReader,
  op: var int,
  limit: int
) =
  ## Copies a stored block after checking its length and complement.
  b.skipRemainingBitsInCurrentByte()
  let
    len = b.checkedBits(16).int
    nlen = b.checkedBits(16).int
  if len + nlen != 65535:
    failUncompress()
  if op + len > limit:
    failLimit()
  if len > 0:
    dst.setLen(op + len) # Make room for the copied bytes.
    b.readBytes(dst[op].addr, len)
  op += len

proc inflateInto(dst: var string, src: ptr UncheckedArray[uint8], len, pos,
    limit: int) =
  ## Decodes successive raw DEFLATE blocks into bounded storage.
  var
    b = BitStreamReader(src: src, len: len, pos: pos)
    op: int
    finalBlock: bool
  while not finalBlock:
    let
      bfinal = b.checkedBits(1)
      btype = b.checkedBits(2)

    if bfinal != 0.uint16:
      finalBlock = true

    case btype:
    of 0: # No compression.
      inflateNoCompression(dst, b, op, limit)
    of 1: # Compressed with fixed Huffman codes.
      inflateBlock(dst, b, op, true, limit)
    of 2: # Compressed with dynamic Huffman codes.
      inflateBlock(dst, b, op, false, limit)
    else:
      raise newException(ZippyError, "Invalid block header")

  if b.bitsBuffered < 0 or (b.pos * 8 - b.bitsBuffered + 7) div 8 != len:
    failUncompress()
  dst.setLen(op)

proc inflateBounded*(src: string, limit: int): string =
  ## Decodes raw DEFLATE `src`; raises ZippyError on corrupt data or when
  ## the output would exceed `limit` bytes.
  if src.len == 0:
    raise newException(ZippyError, "empty deflate stream")
  if limit < 0:
    raise newException(ZippyError, "negative inflate limit")
  inflateInto(
    result,
    cast[ptr UncheckedArray[uint8]](src[0].unsafeAddr),
    src.len,
    0,
    limit
  )
