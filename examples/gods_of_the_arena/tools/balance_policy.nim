import
  std/os,
  balance_policies

proc main() =
  ## Writes a corrected local policy for one exact experimental content file.
  if paramCount() != 3:
    quit("Expected original policy, content.nim, and output policy paths", 1)
  let output = absolutePath(paramStr(3))
  doAssert output != absolutePath(paramStr(1)), "Keep the original policy"
  doAssert not fileExists(output), "Do not overwrite a frozen policy"
  let policy = supportPolicy(readFile(paramStr(1)), readFile(paramStr(2)))
  createDir(output.parentDir)
  writeFile(output, policy)
  echo "Corrected policy: ", output

main()
