import
  std/os,
  ../tests/neuralfixtures

const Policies = currentSourcePath().parentDir.parentDir /
  "examples/gods_of_the_arena/neural/policies"

proc main() =
  ## Generates reproducible packages containing only sparse synthetic weights.
  let directory =
    if paramCount() == 0:
      "tmp/neural-examples"
    else:
      paramStr(1)
  createDir(directory)
  for author in ["richard", "david"]:
    let
      source = readFile(Policies / (author & ".bas"))
      model = if author == "richard": richardFixture() else: davidFixture()
      name = if author == "richard": "weights.bin" else: "model.bin"
    writeFile(directory / (author & ".zip"),
      zipFixture([("policy.bas", source), (name, model)], true))
    echo directory / (author & ".zip")

main()
