import
  bassy, benchy,
  ../examples/gods_of_the_arena/neural/[richard, david],
  neuralfixtures

let
  combat = loadRichard(richardFixture())
  residual = loadRichard(richardFixture(true))
  davidModel = loadDavid(davidFixture(1407, 512))
var
  combatData = newSeq[Fixed](25)
  residualData = newSeq[Fixed](31)
  davidData = newSeq[Fixed](1407)
  state: string
for value in combatData.mitems:
  value = fixed(100)
for value in residualData.mitems:
  value = fixed(100)
for value in davidData.mitems:
  value = 0.5'fx

timeIt "Richard combat 25/16/18":
  keep inferRichard(combat, combatData)
timeIt "Richard residual 31/8/19":
  keep inferRichard(residual, residualData)
timeIt "David recurrent 1407/512/92":
  let next = inferDavid(davidModel, state, davidData)
  state = next.state
  keep next.outputs
