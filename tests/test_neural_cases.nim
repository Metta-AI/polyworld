## Shared neural-package corruption suite, Nim half.
##
##   python3 tests/neural_cases.py tmp/neural_cases
##   nim r tests/test_neural_cases.nim tmp/neural_cases
##
## Validates every package the Python half wrote with the Nim loader and
## requires the same verdict (accepted or rejected) for each one.

import
  std/[json, os, strutils],
  polyworld/neural_host,
  neural_toy

let dir = if paramCount() >= 1: paramStr(1) else: "tmp/neural_cases"
let verdicts = parseJson(readFile(dir / "verdicts.json"))
var failures: seq[string]
for file, verdict in verdicts:
  let name = verdict["name"].getStr
  var accepted = false
  var reason = ""
  try:
    discard parsePackage(readFile(dir / file), toyContract())
    accepted = true
  except ValueError as error:
    reason = error.msg
  let python = verdict["accepted"]
  let agree = python.kind == JBool and python.getBool == accepted
  echo (if agree: "PASS " else: "FAIL "), name, ": nim ",
    (if accepted: "accepted" else: "rejected (" & reason & ")"),
    ", python ", (if python.kind == JBool and python.getBool: "accepted"
      else: "rejected (" & verdict["reason"].getStr & ")")
  if not agree:
    failures.add name
echo verdicts.len, " cases, ", failures.len, " disagreements ", failures.join(", ")
doAssert verdicts.len >= 40, "the Python half wrote too few cases"
doAssert failures.len == 0
