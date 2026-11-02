import
  windy,
  polyworld/inputs

echo "Testing mouse key aliases"
doAssert MouseLeftKey == KeyA
doAssert MouseRightKey == KeyD
doAssert MouseMiddleKey == KeyS

echo "Testing configurable two-slot bindings"
doAssert DefaultBindings[SelectInput] == [MouseLeft, KeyZ]
doAssert DefaultBindings[PanInput] == [MouseMiddle, KeyX]
doAssert DefaultBindings[OrderInput] == [MouseRight, KeyC]
doAssert DefaultBindings[StopInput].contains(KeyS)
doAssert DefaultBindings[CameraInput].contains(KeyV)
var bindings = DefaultBindings
bindings.bindInput(AbilityOneInput, 1, MouseButton4)
doAssert bindings.matches(AbilityOneInput, KeyQ)
doAssert bindings.matches(AbilityOneInput, MouseButton4)
bindings.bindInput(AbilityTwoInput, 0, KeyQ)
doAssert not bindings.matches(AbilityOneInput, KeyQ)
doAssert bindings.matches(AbilityTwoInput, KeyQ)
bindings.bindInput(AbilityTwoInput, 0, ButtonUnknown)
doAssert not bindings.matches(AbilityTwoInput, ButtonUnknown)
doAssert not bindings.matches(AbilityTwoInput, KeyQ)
inputBindings = bindings
bindingCapture = true
doAssert not AbilityOneInput.matches(MouseButton4)
bindingCapture = false
doAssert AbilityOneInput.matches(MouseButton4)
inputBindings = DefaultBindings
echo "Input binding tests passed"
