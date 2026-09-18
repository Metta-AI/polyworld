"""Transfer the existing modular character clips to our Blender armature."""

import bisect
import json
import math
import re
import struct
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector

Source = Path(__file__).resolve().parents[3] / (
  "polyworld_data/characters/modular_chars/character.glb")
Avatar = Path.home() / (
  "Polyworld/Assets/Layer Lab/3D CharactersCasual/"
  "3D Characters - Hero Core Vol.3/FBX/Character/Character.fbx.meta")
Prefix = "QuickRigCharacter2_"
ToBlender = Matrix.Rotation(math.pi / 2, 4, "X")
FrameRate = 30


def quaternion(values):
  """Convert a glTF XYZW quaternion to Blender's WXYZ ordering."""
  x, y, z, w = values
  return Quaternion((w, x, y, z)).normalized()


def readGlb(path):
  """Read JSON and binary GLB chunks without importing source geometry."""
  data = path.read_bytes()
  size = struct.unpack_from("<I", data, 12)[0]
  document = json.loads(data[20:20 + size])
  start = 20 + size
  length, kind = struct.unpack_from("<II", data, start)
  assert kind == 0x004E4942
  return document, data[start + 8:start + 8 + length]


def accessor(document, binary, index):
  """Decode packed or strided floating-point animation keys."""
  entry = document["accessors"][index]
  assert entry["componentType"] == 5126
  width = {"SCALAR": 1, "VEC3": 3, "VEC4": 4, "MAT4": 16}[entry["type"]]
  view = document["bufferViews"][entry["bufferView"]]
  offset = view.get("byteOffset", 0) + entry.get("byteOffset", 0)
  stride = view.get("byteStride", width * 4)
  return [struct.unpack_from("<" + "f" * width, binary, offset + i * stride)
          for i in range(entry["count"])]


def avatarWorld(path):
  """Read Unity's calibrated T-pose, converting handedness into glTF space."""
  text = path.read_text().split("humanDescription:", 1)[1]
  text = text.split("skeleton:", 1)[1]
  entries = {}
  pattern = (r"- name: ([^\n]+)\s+parentName:([^\n]*)\n"
             r"\s+position: (\{[^}]+\})\s+rotation: (\{[^}]+\})")
  for match in re.finditer(pattern, text):
    name, parent, position, rotation = match.groups()
    if name in entries:
      continue
    p = [float(value) for value in re.findall(r":\s*([-+\d.eE]+)", position)]
    q = [float(value) for value in re.findall(r":\s*([-+\d.eE]+)", rotation)]
    entries[name] = (parent.strip(), Vector((-p[0], p[1], p[2])),
                     quaternion((q[0], -q[1], -q[2], q[3])))
  result = {}

  def world(name):
    """Accumulate a calibrated bone transform through its ancestors."""
    if name in result:
      return result[name]
    parent, position, rotation = entries[name]
    transform = Matrix.LocRotScale(position, rotation, Vector((1, 1, 1)))
    if parent in entries:
      transform = world(parent) @ transform
    result[name] = transform
    return transform

  for name in entries:
    world(name)
  return result


def targetTpose(rig):
  """Align the arm and leg axes to the shared humanoid reference."""
  result = {}
  for bone in rig.data.bones:
    rotation = bone.matrix_local.to_quaternion()
    direction = None
    if bone.name.endswith(("Arm", "ForeArm", "Hand")):
      direction = Vector((1 if bone.name.startswith("Left") else -1, 0, 0))
    elif bone.name.endswith(("UpLeg", "Leg")):
      direction = Vector((0, 0, -1))
    if direction is not None:
      restDirection = (bone.tail_local - bone.head_local).normalized()
      rotation = restDirection.rotation_difference(direction) @ rotation
      assert ((rotation @ Vector((0, 1, 0))) - direction).length < 1e-4
    result[bone.name] = rotation
  return result


def sample(track, time, path):
  """Sample linear vector or shortest-arc quaternion tracks at one time."""
  times, values, interpolation = track
  right = bisect.bisect_right(times, time)
  left = max(0, right - 1)
  right = min(right, len(times) - 1)
  first, second = values[left], values[right]
  blend = ((time - times[left]) / (times[right] - times[left])
           if right != left and interpolation != "STEP" else 0)
  if path == "rotation":
    return quaternion(first).slerp(quaternion(second), blend)
  return Vector(first).lerp(Vector(second), blend)


def retarget(rig):
  """Bake all existing animation clips and held poses onto the new rest rig."""
  rig.animation_data_create()
  document, binary = readGlb(Source)
  specs = json.loads(Source.with_name("manifest.json").read_text())["clips"]
  sourceTpose = avatarWorld(Avatar)
  targetPose = targetTpose(rig)
  nodes = document["nodes"]
  parents = {child: i for i, node in enumerate(nodes)
             for child in node.get("children", [])}
  indices = {node["name"]: i for i, node in enumerate(nodes)
             if node.get("name", "").startswith(Prefix)}
  hipsReference = (ToBlender @ sourceTpose[Prefix + "Hips"]).translation
  heightScale = rig.data.bones["Hips"].head_local.z / hipsReference.z
  sourceInverse = {bone.name: (ToBlender @ sourceTpose[Prefix + bone.name])
                   .to_quaternion().inverted() for bone in rig.data.bones}
  actions = []
  for animation in document["animations"]:
    name = animation["name"]
    old = bpy.data.actions.get(name)
    if old is not None:
      bpy.data.actions.remove(old)
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    rig.animation_data.action = action
    tracks = {}
    end = 0
    for channel in animation["channels"]:
      path = channel["target"]["path"]
      if path not in ["rotation", "translation", "scale"]:
        continue
      sampler = animation["samplers"][channel["sampler"]]
      interpolation = sampler.get("interpolation", "LINEAR")
      assert interpolation in ["LINEAR", "STEP"], interpolation
      times = [key[0] for key in accessor(document, binary, sampler["input"])]
      values = accessor(document, binary, sampler["output"])
      tracks[channel["target"]["node"], path] = (times, values, interpolation)
      end = max(end, times[-1])
    frames = max(1, round(end * FrameRate))
    previous = {}
    for frame in range(frames + 1):
      time = min(frame / FrameRate, end)
      cache = {}

      def world(index):
        """Evaluate source motion without changing its reference skeleton."""
        if index in cache:
          return cache[index]
        node = nodes[index]
        components = {}
        for path, fallback in [("translation", [0, 0, 0]),
                               ("rotation", [0, 0, 0, 1]),
                               ("scale", [1, 1, 1])]:
          track = tracks.get((index, path))
          components[path] = (sample(track, time, path) if track else
            (quaternion(node.get(path, fallback)) if path == "rotation"
             else Vector(node.get(path, fallback))))
        transform = Matrix.LocRotScale(components["translation"],
          components["rotation"], components["scale"])
        if index in parents:
          transform = world(parents[index]) @ transform
        cache[index] = transform
        return transform

      desired = {}
      for pose in rig.pose.bones:
        source = ToBlender @ world(indices[Prefix + pose.name])
        rotation = (source.to_quaternion() @ sourceInverse[pose.name]
                    @ targetPose[pose.name]).normalized()
        bone = pose.bone
        if pose.parent:
          parentRotation = desired[pose.parent.name]
          restLocal = (bone.parent.matrix_local.inverted() @ bone.matrix_local)
          local = restLocal.to_quaternion().inverted() @ (
            parentRotation.inverted() @ rotation)
          pose.location = (0, 0, 0)
        else:
          local = bone.matrix_local.to_quaternion().inverted() @ rotation
          offset = (source.translation - hipsReference) * heightScale
          pose.location = bone.matrix_local.to_quaternion().inverted() @ offset
        local.normalize()
        if pose.name in previous and previous[pose.name].dot(local) < 0:
          local.negate()
        previous[pose.name] = local.copy()
        pose.rotation_mode = "QUATERNION"
        pose.rotation_quaternion = local
        pose.scale = (1, 1, 1)
        pose.keyframe_insert("rotation_quaternion", frame=frame,
                             group=pose.name)
        pose.keyframe_insert("location", frame=frame, group=pose.name)
        desired[pose.name] = rotation
    actions.append(action)
    print("RETARGETED", name, "seconds", round(end, 3), flush=True)
  return actions, specs
