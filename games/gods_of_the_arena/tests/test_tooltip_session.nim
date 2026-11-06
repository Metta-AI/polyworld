## Session integration: identity, current geometry, panel ownership and reset.
import vmath
import polyworld/gameuis
import ../tooltips

let size = vec2(800, 700)
let anchor = GameUiPanel(origin: vec2(360, 610), size: vec2(64))
let card = DetailTooltip(title: "First", description: "Details")
let a = TooltipTarget(id: "hero:1:ability:0", card: card, anchor: anchor, key: "Q")
var session: TooltipSession
session.updateTooltip([a], anchor.origin + vec2(1), size, 1.0)
doAssert not session.hover.visible
session.updateTooltip([a], anchor.origin + vec2(60), size, 1.5)
doAssert session.hover.visible
let panel = session.panel
session.updateTooltip([a], panel.origin + vec2(20), size, 5.0)
doAssert session.hover.visible
# Another anchor underneath the panel must not steal its hover.
let covered = TooltipTarget(id: "covered", card: DetailTooltip(title: "Wrong"),
  anchor: panel)
session.updateTooltip([a, covered], panel.origin + vec2(20), size, 6.0)
doAssert session.current.id == a.id
# Removal/change of selection must clear even if pointer stays on the panel.
session.updateTooltip([covered], panel.origin + vec2(20), size, 6.1)
doAssert not session.hover.visible
doAssert session.current.id == covered.id
session.updateTooltip([covered], panel.origin + vec2(20), size, 6.6)
doAssert session.hover.visible
session.clearTooltip()
doAssert not session.hover.visible and session.current.id.len == 0
# Empty/transition contexts cannot inherit a previous dwell.
session.updateTooltip([], anchor.origin, size, 7.0)
doAssert not session.hover.visible
echo "PASS session panel ownership, target removal and transition clear"

# Live cards refresh rank/item data without restarting a stable anchor's dwell.
var refreshed = a
refreshed.card.title = "Rank updated"
session.updateTooltip([a], anchor.origin + vec2(1), size, 10.0)
session.updateTooltip([refreshed], anchor.origin + vec2(20), size, 10.5)
doAssert session.hover.visible and session.current.card.title == "Rank updated"
# Both horizontal edges and top placement use the exact renderer rectangle.
for at in [vec2(0, 610), vec2(760, 610), vec2(360, 10)]:
  let bounds = tooltipPanel(card, GameUiPanel(origin: at, size: vec2(64)), size)
  doAssert bounds.origin.x >= 8 and bounds.origin.y >= 8
  doAssert bounds.origin.x + bounds.size.x <= size.x - 8
  doAssert bounds.origin.y + bounds.size.y <= size.y - 8
echo "PASS live content refresh and shared viewport-clamped geometry"

# Warm-up belongs to the HUD session, not to an ability/item's identity.
session.clearTooltip()
let b = TooltipTarget(id: "hero:1:item:0", key: "1",
  card: DetailTooltip(title: "Different item", description: "Item details",
    rows: @[("Cost", "125")]),
  anchor: GameUiPanel(origin: vec2(40, 610), size: vec2(64)))
let c = TooltipTarget(id: "hero:1:ability:2", card: card,
  anchor: GameUiPanel(origin: vec2(700, 610), size: vec2(64)))
session.updateTooltip([a, b, c], a.anchor.origin + vec2(1), size, 20.0)
doAssert not session.hover.visible
session.updateTooltip([a, b, c], a.anchor.origin + vec2(20), size, 20.49)
doAssert not session.hover.visible
session.updateTooltip([a, b, c], a.anchor.origin + vec2(20), size, 20.5)
doAssert session.hover.visible
let oldPanel = session.panel
session.updateTooltip([a, b, c], b.anchor.origin + vec2(20), size, 20.51)
doAssert session.hover.visible, "Warm ability-to-item switch must be instant"
doAssert session.current.id == b.id and session.current.card.title == b.card.title
doAssert session.panel == tooltipPanel(b.card, b.anchor, size)
doAssert session.tooltipContains(session.panel.origin + vec2(20))
doAssert not session.tooltipContains(oldPanel.origin + vec2(oldPanel.size.x - 1, 20)),
  "Switching targets must replace the old collision rectangle immediately"
session.updateTooltip([a, b, c], session.panel.origin + vec2(20), size, 100.0)
doAssert session.hover.visible and session.current.id == b.id
session.updateTooltip([a, b, c], vec2(799, 699), size, 100.1)
doAssert session.hover.visible
session.updateTooltip([a, b, c], vec2(799, 699), size, 100.46)
doAssert not session.hover.visible and session.current.id.len == 0
session.updateTooltip([a, b, c], c.anchor.origin + vec2(20), size, 101.0)
doAssert not session.hover.visible, "Expired warm-up must not leak into the next target"
session.updateTooltip([a, b, c], c.anchor.origin + vec2(20), size, 101.49)
doAssert not session.hover.visible
session.updateTooltip([a, b, c], c.anchor.origin + vec2(20), size, 101.5)
doAssert session.hover.visible
echo "PASS global warm-up, instant new content/geometry, panel retention and cold restart"

# A stale panel must release hit ownership before resolving the next anchor,
# even when no frame was sampled at the exact grace deadline.
let underneath = TooltipTarget(id: "underneath", card: card, anchor: session.panel)
session.updateTooltip([a, b, c, underneath], vec2(799, 699), size, 102.0)
session.updateTooltip([a, b, c, underneath], underneath.anchor.origin + vec2(20), size, 102.36)
doAssert not session.hover.visible
# Do not lose the first cold-hover frame to the expired panel's collision map.
doAssert session.current.id == underneath.id
session.updateTooltip([a, b, c, underneath], underneath.anchor.origin + vec2(20), size, 102.86)
doAssert session.hover.visible
echo "PASS expired panel releases ownership before choosing next cold anchor"

session.clearTooltip()
session.updateTooltip([a, b], a.anchor.origin + vec2(20), size, 110.0)
session.updateTooltip([a, b], b.anchor.origin + vec2(20), size, 110.4)
doAssert not session.hover.visible
session.updateTooltip([a, b], b.anchor.origin + vec2(20), size, 110.5)
doAssert not session.hover.visible, "Changing a pending target must not warm the session"
session.updateTooltip([a, b], b.anchor.origin + vec2(20), size, 110.89)
doAssert not session.hover.visible
session.updateTooltip([a, b], b.anchor.origin + vec2(20), size, 110.91)
doAssert session.hover.visible
# The brief departure grace permits crossing the gap to a different anchor.
session.updateTooltip([a, b], vec2(799, 699), size, 111.0)
session.updateTooltip([a, b], a.anchor.origin + vec2(20), size, 111.1)
doAssert session.hover.visible and session.current.id == a.id
echo "PASS pending target requires its own dwell and gap crossing stays warm"
