## Game-owned order colors; never change the shared games' gold click effect.
import chroma, vmath
import polyworld/[clickmarks, fxmeshes]

proc orderFeedbackColor*(attack: bool): ColorRGBX =
  ## Same semantic tint for the curve, its destination slots and committed marks.
  if attack: rgbx(255, 72, 65, 210)
  else: rgbx(80, 245, 145, 210)

proc orderMarkSettings*(attack: bool): FxSettings =
  result = clickMarkSettings()
  let color = orderFeedbackColor(attack)
  let tint = vec3(color.r.float32, color.g.float32, color.b.float32) / 255'f32
  result.startColor = vec4(tint, 0.95)
  result.endColor = vec4(tint * 0.85'f32, 0)
  result.edgeColor = vec4(tint, 1)
