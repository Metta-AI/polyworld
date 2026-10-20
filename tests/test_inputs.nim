import
  windy,
  polyworld/inputs

echo "Testing mouse key aliases"
doAssert MouseLeftKey == KeyA
doAssert MouseRightKey == KeyD
doAssert MouseMiddleKey == KeyS

echo "Testing human hotkeys never turn into mouse clicks or camera drags"
for (button, alias) in [(MouseLeft, KeyA), (MouseRight, KeyD), (MouseMiddle, KeyS)]:
  let keyOnly = ButtonView({alias})
  doAssert mouseButton(keyOnly, button)
  doAssert not mouseButton(keyOnly, button, aliases = false)
  doAssert mouseButton(ButtonView({button}), button, aliases = false)
  doAssert not mouseButton(ButtonView({}), button, aliases = false)
