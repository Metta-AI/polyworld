## Pure presentation; never changes bodies, orders, collision or build progress.
import vmath
import content, sim

type ConstructionPresentation* = object
  active*: bool
  siteId*: int32
  tilePoint*: Vec2
  yaw*, floorLift*: float32
  animation*: AnimationSlot

proc constructionPresentation*(world: World, unit: Unit): ConstructionPresentation =
  ## An inactive result means the renderer must use its ordinary unit pose.
  result.siteId = NoEntity
  if unit == nil or unit.state != UnitBuilding: return
  let index = world.buildingIndex(unit.targetId)
  if index < 0: return
  let site = world.buildings[index]
  if site.state != BuildingUnderConstruction or site.builderId != unit.id:
    return
  let builder = world.activeBuilderFor(site)
  if builder < 0 or world.units[builder] != unit or
      not site.constructionInRange(unit):
    return
  # Authored construction shells are open-topped, with their front at +Z.
  # Keep the worker just forward of centre, facing into the work, clear of
  # perimeter walls. Use the already-loaded Peon Interact clip, not a new rig.
  result = ConstructionPresentation(
    active: true,
    siteId: site.id,
    tilePoint: vec2(site.origin.x.float32 + site.footprint.width.float32 * 0.5'f32,
      site.origin.y.float32 + site.footprint.depth.float32 * 0.62'f32),
    yaw: 3.14159265'f32,
    floorLift: (if site.kind == FarmBuilding: 0.09'f32 else: 0.12'f32),
    animation: AttackAnimation
  )
