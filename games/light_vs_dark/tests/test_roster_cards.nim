import std/unittest
import bumpy, silky, vmath
import ../[lobbies, factions]

suite "LvD roster card layout and faction colors":
  test "player cards use the same dimensions as GotA seats":
    let layout = LobbyLayout(left: vec2(32, 150), leftWidth: 930)
    check rosterCardSize(layout) == vec2(435, 78)
    check rosterCardPosition(layout, 1, 0) == rosterCardPosition(layout, 0, 0) + vec2(455, 0)
    for index in 0 ..< 64:
      check rosterCardPosition(layout, index, 0) ==
        layout.left + vec2((20 + (index mod 2) * 455).float32, (132 + (index div 2) * 88).float32)
    check rosterCardPosition(layout, 63, 0) == layout.left + vec2(475, 2860)

  test "scroll reaches the last seat without overlapping fixed controls":
    for panelHeight in [622.0'f, 712.0'f, 820.0'f]:
      let layout = LobbyLayout(left: vec2(32, 150), leftWidth: 930,
        panelHeight: panelHeight)
      let viewport = rosterViewport(layout)
      check viewport.xy == rosterCardPosition(layout, 0)
      check viewport.y + viewport.h < rosterControlsPosition(layout).y
      for count in [1, 2, 3, 10, 63, 64]:
        let scroll = rosterScrollPosition(layout, count, 10000)
        let last = rosterCardPosition(layout, count - 1, scroll)
        check last.y >= viewport.y
        check last.y + rosterCardSize(layout).y <= viewport.y + viewport.h
        check rosterScrollPosition(layout, count, -100) == 0
      check rosterScrollPosition(layout, 2, 10000) == 0
      check rosterContentHeight(0) == 0
      check rosterContentHeight(63) == rosterContentHeight(64)
      let middleScroll = rosterScrollPosition(layout, 64, 88)
      check rosterCardPosition(layout, 2, middleScroll) == viewport.xy
      check rosterOwnsScroll(layout, 64, viewport.xy + vec2(10))
      check not rosterOwnsScroll(layout, 2, viewport.xy + vec2(10))
      check not rosterOwnsScroll(layout, 64, rosterControlsPosition(layout) + vec2(10))

  test "roster clip excludes hidden seats and leaves controls outside":
    let layout = LobbyLayout(left: vec2(32, 150), leftWidth: 930, panelHeight: 712)
    let sk = Silky()
    sk.pushClipRect(rect(0, 0, 1514, 970))
    sk.pushRosterClip(layout)
    check overlaps(rosterCardPosition(layout, 0) + vec2(10), sk.clipRect)
    check not overlaps(rosterCardPosition(layout, 63) + vec2(10), sk.clipRect)
    check not overlaps(rosterControlsPosition(layout) + vec2(10), sk.clipRect)
    # A partially visible row must not receive input below the viewport,
    # including the Add player button underneath its un-clipped rectangle.
    let controls = rosterControlsPosition(layout) + vec2(10)
    check overlaps(controls, rect(rosterCardPosition(layout, 8), rosterCardSize(layout)))
    check not overlaps(controls, sk.clipRect)
    let last = rosterCardPosition(layout, 63, rosterScrollPosition(layout, 64, 10000))
    check overlaps(last + vec2(10), sk.clipRect)
    check overlaps(last + rosterCardSize(layout) - vec2(1), sk.clipRect)
    sk.popClipRect()
    check overlaps(rosterControlsPosition(layout) + vec2(10), sk.clipRect)
    sk.popClipRect()

  test "card colors match the seeded in-game faction order":
    for seed in [0'i32, 47, 2026]:
      let order = factionOrder(seed.int64)
      for player in 0 ..< 64:
        check rosterColor(seed, player) == FactionColors[order[Faction(player mod FactionFiles.len)]]
