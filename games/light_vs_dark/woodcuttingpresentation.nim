import content, sim

proc woodAxeVisible*(unit: Unit): bool =
  ## Retain the tool throughout a wood assignment, including its delivery.
  unit != nil and unit.kind == PeonUnit and unit.hp > 0 and
    unit.state in {UnitToTree, UnitChopping, UnitToDropWood, UnitDepositWood}
proc woodAnimationClip*(unit: Unit, fallback: string): string =
  ## Construction and combat keep their normal Interact animation.
  if unit.woodAxeVisible and unit.state == UnitChopping: "Sword_Attack"
  else: fallback
proc woodAnimationTime*(unit: Unit, fallback, alpha: float32): float32 =
  ## Restart the swing each chop session without changing simulation state.
  if unit.woodAxeVisible and unit.state == UnitChopping:
    (float32(clamp(ChopTicks - unit.stateTicks, 0, ChopTicks)) +
      clamp(alpha, 0'f, 1'f)) / float32(TickRate)
  else:
    fallback
