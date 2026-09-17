import
  std/[math, os, tables],
  chroma, gltf, jsony, silky, vmath,
  parts

type
  BoneSpec = object
    name, parent: string
    head, tail: array[3, float32]

  RigSpec = object
    skeleton: seq[BoneSpec]

  Bone* = object
    name*: string
    parent*: int
    node*: Node
    inverseBind*: Mat4
    restHead*, restTail*: Vec3

  Surface = object
    node: Node
    primitive: Primitive
    colors: seq[ColorRGBX]
    unlit: bool
    tint: Color

  WeightPreview* = object
    bones*: seq[Bone]
    surfaces: seq[Surface]
    active: bool
    selected: int

proc boneIndex*(preview: WeightPreview, name: string): int =
  ## Finds a named bone without relying on the skin's joint ordering.
  for i, bone in preview.bones:
    if bone.name == name:
      return i
  -1

proc initWeightPreview*(root: Node, directory: string): WeightPreview =
  ## Captures source colors and reads the exported Blender bone endpoints.
  var spec: RigSpec
  try:
    spec = readFile(directory / "model.json").fromJson(RigSpec)
  except IOError, JsonError:
    raise newException(
      BlenderCharsError, "Cannot read skeleton: " & getCurrentExceptionMsg()
    )
  var joints: Table[string, tuple[node: Node, inverseBind: Mat4]]
  for node in root.walkNodes:
    if node.skin == nil or node.mesh == nil:
      continue
    for i, joint in node.skin.joints:
      joints[joint.name] = (joint, node.skin.inverseBindMatrices[i])
    for primitive in node.mesh.primitives:
      result.surfaces.add Surface(
        node: node,
        primitive: primitive,
        colors: primitive.colors,
        unlit: primitive.material.unlit,
        tint: primitive.material.baseColorFactor
      )
  for bone in spec.skeleton:
    if bone.name notin joints:
      raise newException(BlenderCharsError, "Missing bone: " & bone.name)
    let joint = joints[bone.name]
    result.bones.add Bone(
      name: bone.name,
      parent: -1,
      node: joint.node,
      inverseBind: joint.inverseBind,
      restHead: vec3(bone.head[0], bone.head[1], bone.head[2]),
      restTail: vec3(bone.tail[0], bone.tail[1], bone.tail[2])
    )
  for i, bone in spec.skeleton:
    result.bones[i].parent = result.boneIndex(bone.parent)
  if result.bones.len == 0:
    raise newException(BlenderCharsError, "The model has no skeleton metadata.")
  result.selected = -1

proc influence*(node: Node, primitive: Primitive, vertex: int,
                bone: string): float32 =
  ## Sums the actual exported glTF skin weights for a named bone.
  if node.skin == nil or vertex >= primitive.jointWeights.len:
    return 0
  for i in 0 ..< 4:
    let joint = primitive.jointIds[vertex][i].int
    if joint < node.skin.joints.len and node.skin.joints[joint].name == bone:
      result += primitive.jointWeights[vertex][i]

proc weightColor*(weight: float32): ColorRGBX =
  ## Maps zero to blue, intermediate weights to cyan/yellow, and one to red.
  const Stops = [
    color(0.025, 0.055, 0.45, 1), color(0, 0.70, 1, 1),
    color(0.05, 0.90, 0.22, 1), color(1, 0.88, 0.015, 1),
    color(0.95, 0.025, 0.015, 1)
  ]
  let
    scaled = clamp(weight, 0, 1) * 4
    index = min(scaled.int, 3)
    blend = scaled - index.float32
  mix(Stops[index], Stops[index + 1], blend).rgbx

proc updateWeights*(preview: var WeightPreview, active: bool, selected: int) =
  ## Applies reversible vertex colors without modifying geometry or weights.
  assert selected >= 0 and selected < preview.bones.len
  if active != preview.active or (active and selected != preview.selected):
    for surface in preview.surfaces:
      let primitive = surface.primitive
      if active:
        var colors = newSeq[ColorRGBX](primitive.points.len)
        for i in 0 ..< colors.len:
          colors[i] = weightColor(surface.node.influence(
            primitive, i, preview.bones[selected].name
          ))
        primitive.colors = colors
      else:
        primitive.colors = surface.colors
        primitive.material.baseColorFactor = surface.tint
      primitive.material.unlit = active or surface.unlit
      inc primitive.geometryVersion
    preview.active = active
    preview.selected = selected
  if active:
    for surface in preview.surfaces:
      surface.primitive.material.baseColorFactor = color(1, 1, 1, 1)

proc endpoints*(bone: Bone): tuple[head, tail: Vec3] =
  ## Deforms the authored Blender endpoints with the runtime joint matrix.
  let transform = bone.node.mat * bone.inverseBind
  ((transform * vec4(bone.restHead, 1)).xyz,
   (transform * vec4(bone.restTail, 1)).xyz)

proc jointGap*(preview: WeightPreview, selected: int): float32 =
  ## Measures parent-tail to child-head distance in the current animation.
  let bone = preview.bones[selected]
  if bone.parent < 0:
    return 0
  let
    parent = preview.bones[bone.parent].endpoints()
    child = bone.endpoints()
  length(parent.tail - child.head)

proc jointBend*(preview: WeightPreview, selected: int): float32 =
  ## Measures the angle between a bone and its parent in degrees.
  let bone = preview.bones[selected]
  if bone.parent < 0:
    return 0
  let
    parent = preview.bones[bone.parent].endpoints()
    child = bone.endpoints()
    first = normalize(parent.tail - parent.head)
    second = normalize(child.tail - child.head)
  arccos(clamp(dot(first, second), -1, 1)) * 180 / PI.float32

proc project(point: Vec3, matrix: Mat4, size: Vec2): Vec2 =
  ## Projects a world-space bone endpoint onto the viewer canvas.
  let clip = matrix * vec4(point, 1)
  if clip.w <= 0:
    return vec2(-10000, -10000)
  vec2((clip.x / clip.w + 1) * size.x / 2,
       (1 - clip.y / clip.w) * size.y / 2)

proc line(sk: Silky, first, last: Vec2, width: float32, tint: ColorRGBX) =
  ## Draws a solid screen-space segment through the white atlas tile.
  let
    delta = last - first
    length = length(delta)
  if length < 0.01:
    return
  let
    normal = vec2(-delta.y, delta.x) * (width / length / 2)
    tile = sk.atlas.entries[WhiteTileKey]
    uv = vec2(tile.x.float32, tile.y.float32) +
      vec2(tile.width.float32, tile.height.float32) / 2
  sk.drawTriangle([first + normal, first - normal, last - normal],
                  [uv, uv, uv], [tint, tint, tint])
  sk.drawTriangle([first + normal, last - normal, last + normal],
                  [uv, uv, uv], [tint, tint, tint])

proc drawSkeleton*(preview: WeightPreview, sk: Silky, matrix: Mat4,
                   size: Vec2, selected: int, labels: bool) =
  ## Draws bone endpoints above the mesh, highlighting the selected bone.
  for i, bone in preview.bones:
    let
      ends = bone.endpoints()
      first = project(ends.head, matrix, size)
      last = project(ends.tail, matrix, size)
      tint =
        if i == selected:
          rgbx(255, 221, 80, 255)
        else:
          rgbx(188, 229, 246, 255)
    sk.line(first, last, 7, rgbx(10, 18, 32, 255))
    sk.line(first, last, 3, tint)
    sk.drawRect(first - vec2(4), vec2(8), rgbx(10, 18, 32, 255))
    sk.drawRect(first - vec2(2), vec2(4), tint)
    sk.drawRect(last - vec2(2), vec2(4), tint)
    if labels or i == selected:
      let at = (first + last) / 2 + vec2(8, -20)
      discard sk.drawText(sk.textStyle, bone.name, at + vec2(1),
                          rgbx(5, 8, 15, 255))
      discard sk.drawText(sk.textStyle, bone.name, at, tint)

proc drawLegend*(sk: Silky, center: Vec2, name: string) =
  ## Labels the weight scale without covering either control panel.
  let start = center - vec2(160, 0)
  sk.drawRect(start - vec2(12, 12), vec2(344, 94), rgbx(15, 20, 29, 245))
  discard sk.drawText(sk.textStyle, name & " influence", start,
                      rgbx(235, 241, 249, 255))
  for i in 0 ..< 160:
    sk.drawRect(start + vec2(i.float32 * 2, 28), vec2(2, 12),
                weightColor(i.float32 / 159))
  discard sk.drawText(sk.textStyle, "0%", start + vec2(0, 48),
                      rgbx(235, 241, 249, 255))
  discard sk.drawText(sk.textStyle, "50%", start + vec2(142, 48),
                      rgbx(235, 241, 249, 255))
  discard sk.drawText(sk.textStyle, "100%", start + vec2(279, 48),
                      rgbx(235, 241, 249, 255))
