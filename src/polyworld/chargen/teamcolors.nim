## Team-color overrides for independently selectable character parts.
import parts

proc tintVanguardTeam*(preset: var Preset, rgb: array[3, float32]) =
  ## Tint only Vanguard's cape, plume and shield face, not armor or other parts.
  ## The per-slot materials are defined by the Vanguard part sidecars.
  for channel in rgb:
    if not (channel >= 0 and channel <= 1):
      raise newException(ChargenError, "Team RGB is outside zero to one.")
  for part in preset.parts.mitems:
    if (part.category == "Chest" and part.item == "Vanguard Knight body") or
        (part.category == "Headgear" and part.item == "Vanguard Knight helmet") or
        (part.category == "Left hand" and part.item == "Vanguard shield"):
      part.rgb = @[rgb[0], rgb[1], rgb[2]]
