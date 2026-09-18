## Checks scorecard text with the font from the sibling asset repository.

import
  pixie, polyworld/assets,
  ../examples/heartleaf/[content, scorecard]

echo "Testing Heartleaf scorecard font bounds"
block:
  let font = readFont(DefaultFontPath)
  font.size = 15
  for first in VeggieNames:
    for second in VeggieNames:
      for third in VeggieNames:
        let text = first & " +3 / " & second & " +1 / " & third & " +1"
        doAssert font.layoutBounds(text).x <= ScoreColumnWidths[2]
  doAssert font.layoutBounds("27 veg x 8 guests = +216").x <=
    ScoreColumnWidths[1]

echo "Heartleaf scorecard font bounds passed"
