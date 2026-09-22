import ../examples/gods_of_the_arena/scores

echo "Testing integer scores round down after the time penalty"
doAssert score(1000, 0) == 1000
doAssert score(1000, 1) == 999
doAssert score(1000, 7) == 999
doAssert score(1000, 8) == 998
doAssert score(1000, 720) == 900
doAssert score(1000, 721) == 899
doAssert score(1000, 1440) == 800
doAssert score(1000, 1440, 100) == 900
doAssert score(1000, 1440, 0) == 1000

echo "Testing zero floor, seat order, and wide score intermediates"
doAssert score(100, 721) == 0
doAssert score(4000, 28800) == 0
doAssert score(4001, 28800) == 1
doAssert score(2_147_483_647, 1440) == 2_147_483_447
doAssert scores(@[0, 100, 1000], 721) == @[0, 0, 899]
