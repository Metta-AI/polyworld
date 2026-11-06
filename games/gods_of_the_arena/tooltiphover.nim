## Game-local hover timing. Call once per frame with a monotonic seconds clock.
import vmath
import polyworld/gameuis

const
  TooltipDelay* = 0.5
  TooltipGrace* = 0.35

type TooltipHover* = object
  target*: string
  visible*: bool
  entered: float64
  leaving: bool
  leftAt: float64

proc expire*(hover: var TooltipHover, now: float64): bool =
  ## Retire expired panel ownership before resolving this frame's HUD hits.
  if hover.leaving and now - hover.leftAt >= TooltipGrace:
    hover = TooltipHover()
    result = true

proc update*(hover: var TooltipHover, target: string,
    anchor, panel: GameUiPanel, mouse: Vec2, now: float64): bool =
  # Warm-up is shared by all anchors in this GotA session. Only an expired
  # departure (or an explicit session reset) makes a visible session cold.
  discard hover.expire(now)
  if target.len > 0 and target != hover.target:
    hover = TooltipHover(target: target, entered: now, visible: hover.visible)
  if target.len > 0 and anchor.contains(mouse):
    hover.leaving = false
    hover.visible = hover.visible or now - hover.entered >= TooltipDelay
  elif hover.visible and panel.contains(mouse):
    hover.leaving = false
  elif hover.visible:
    if not hover.leaving:
      hover.leaving = true
      hover.leftAt = now
    if now - hover.leftAt >= TooltipGrace:
      hover = TooltipHover()
  else:
    hover = TooltipHover()
  hover.visible
