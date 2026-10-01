import
  std/strutils,
  ../src/core/[bots, sim]

echo "Testing decisions beyond the previous instruction budget"
block:
  var game = newGame(Archer, Warrior, 7)
  let vm = loadBot("""
for i = 1 to 250000
  total = total + 1
next
end
""", game.currentPlayer.int32)
  doAssert vm.runDecision(game) == BotEndedTurn
  doAssert vm.runtime.instructionsUsed > 500_000
  doAssert vm.runtime.instructionsUsed <= 5_000_000

echo "Testing arrays beyond the previous memory budget"
block:
  var game = newGame(Archer, Warrior, 7)
  let vm = loadBot("""
dim values(4500000)
values(4500000) = 42
end
""", game.currentPlayer.int32)
  doAssert vm.runtime.memoryBytes > 64'i64 * 1024 * 1024
  doAssert vm.runtime.memoryBytes < 640'i64 * 1024 * 1024
  doAssert vm.runDecision(game) == BotEndedTurn
  doAssert vm.runtime.getArray("values", 4_500_000).asInt == 42

echo "Testing runaway decisions still stop at the new budget"
block:
  var game = newGame(Archer, Warrior, 7)
  let vm = loadBot("do\nloop\n", game.currentPlayer.int32)
  doAssert vm.runDecision(game) == BotFailed
  doAssert vm.lastError.contains("limit exceeded")
  doAssert vm.runtime.instructionsUsed > 4_999_900
  doAssert vm.runtime.instructionsUsed <= 5_000_000

echo "Testing allocations still stop at the new memory budget"
block:
  let source = "dim values(" & $(botLimits().maxArrayElements - 1) & ")"
  try:
    discard loadBot(source, 0)
    doAssert false, "An array filling the budget must leave room for VM state."
  except BasicError as error:
    doAssert error.msg.contains("memory limit")
