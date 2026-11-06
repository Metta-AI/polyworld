import vmath
import ../lobbies

for height in [622'f, 712'f, 900'f]:
  for named in [false, true]:
    let buttons = settingsFooter(vec2(100, 200), height, named)
    doAssert buttons.map.y + 44 <= buttons.advanced.y
    doAssert buttons.advanced.y + 44 <= 200 + height - 22
    doAssert buttons.map.x == 122
    doAssert buttons.advanced.x == 122
echo "Settings footer stays inside panel with and without game-name row"
