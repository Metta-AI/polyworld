"""Retarget Quaternius Standard humanoid clips onto the Chargen armature."""

from pathlib import Path

import bpy
from mathutils import Matrix, Vector

from retarget import FrameRate, ToBlender, accessor, quaternion, readGlb, sample, targetTpose

Source = Path(__file__).resolve().parents[3] / (
  'polyworld_data/animations/quaternius/universal_standard/'
  'Unreal-Godot/UAL1_Standard.glb')
Bones = {
  'Hips': 'pelvis', 'Spine': 'spine_01', 'Spine1': 'spine_02',
  'Spine2': 'spine_03', 'Neck': 'neck_01', 'Head': 'Head',
  'LeftShoulder': 'clavicle_l', 'LeftArm': 'upperarm_l',
  'LeftForeArm': 'lowerarm_l', 'LeftHand': 'hand_l',
  'RightShoulder': 'clavicle_r', 'RightArm': 'upperarm_r',
  'RightForeArm': 'lowerarm_r', 'RightHand': 'hand_r',
  'LeftUpLeg': 'thigh_l', 'LeftLeg': 'calf_l',
  'LeftFoot': 'foot_l', 'LeftToeBase': 'ball_l',
  'RightUpLeg': 'thigh_r', 'RightLeg': 'calf_r',
  'RightFoot': 'foot_r', 'RightToeBase': 'ball_r',
}
Following = {
  'Jump_Start': 'Jump_Loop', 'Jump_Land': 'Idle_Loop',
  'Sitting_Enter': 'Sitting_Idle_Loop', 'Sitting_Exit': 'Idle_Loop',
  'Spell_Simple_Enter': 'Spell_Simple_Idle_Loop',
  'Spell_Simple_Shoot': 'Spell_Simple_Idle_Loop',
  'Spell_Simple_Exit': 'Idle_Loop',
}
Held = {'A_TPose', 'Death01', 'Pistol_Aim_Down', 'Pistol_Aim_Neutral',
        'Pistol_Aim_Up'}


def evaluator(document, binary, animation):
  """Sample source world transforms, including its animated root bone."""
  nodes = document['nodes']
  parents = {child: i for i, node in enumerate(nodes)
             for child in node.get('children', [])}
  tracks = {}
  duration = 0
  for channel in animation['channels']:
    path = channel['target']['path']
    if path not in ['rotation', 'translation', 'scale']:
      continue
    sampler = animation['samplers'][channel['sampler']]
    interpolation = sampler.get('interpolation', 'LINEAR')
    if interpolation not in ['LINEAR', 'STEP']:
      raise ValueError('Unsupported animation interpolation: ' + interpolation)
    times = [value[0] for value in accessor(document, binary, sampler['input'])]
    tracks[channel['target']['node'], path] = (
      times, accessor(document, binary, sampler['output']), interpolation)
    duration = max(duration, times[-1])

  def evaluate(time):
    """Resolve the complete source hierarchy at one timestamp."""
    cache = {}

    def world(index):
      """Compose parent and local transforms without changing the source rig."""
      if index in cache:
        return cache[index]
      node = nodes[index]
      values = {}
      for path, fallback in [('translation', [0, 0, 0]),
                             ('rotation', [0, 0, 0, 1]),
                             ('scale', [1, 1, 1])]:
        track = tracks.get((index, path))
        values[path] = (sample(track, time, path) if track else
          (quaternion(node.get(path, fallback)) if path == 'rotation'
           else Vector(node.get(path, fallback))))
      transform = Matrix.LocRotScale(values['translation'], values['rotation'],
                                     values['scale'])
      if index in parents:
        transform = world(parents[index]) @ transform
      cache[index] = transform
      return transform

    return {node.get('name', ''): ToBlender @ world(i)
            for i, node in enumerate(nodes) if 'mesh' not in node}

  return evaluate, duration


def retargetUniversal(rig):
  """Bake authored motion with a calibrated T-pose and fixed limb lengths."""
  document, binary = readGlb(Source)
  reference = next(clip for clip in document['animations']
                   if clip['name'] == 'A_TPose')
  sourcePose = evaluator(document, binary, reference)[0](0)
  targetPose = targetTpose(rig)
  if set(Bones) != set(bone.name for bone in rig.data.bones):
    raise ValueError('Universal mapping does not cover the Chargen rig.')
  sourceInverse = {name: sourcePose[source].to_quaternion().inverted()
                   for name, source in Bones.items()}
  hipsReference = sourcePose['pelvis'].translation
  heightScale = rig.data.bones['Hips'].head_local.z / hipsReference.z
  actions, specs = [], []
  rig.animation_data_create()
  for animation in document['animations']:
    name = animation['name']
    old = bpy.data.actions.get(name)
    if old is not None:
      bpy.data.actions.remove(old)
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    rig.animation_data.action = action
    evaluate, duration = evaluator(document, binary, animation)
    frames = max(1, round(duration * FrameRate))
    previous = {}
    for frame in range(frames + 1):
      source = evaluate(min(frame / FrameRate, duration))
      desired = {}
      for pose in rig.pose.bones:
        transform = source[Bones[pose.name]]
        rotation = (transform.to_quaternion() @ sourceInverse[pose.name]
                    @ targetPose[pose.name]).normalized()
        bone = pose.bone
        if pose.parent:
          restLocal = bone.parent.matrix_local.inverted() @ bone.matrix_local
          local = restLocal.to_quaternion().inverted() @ (
            desired[pose.parent.name].inverted() @ rotation)
          pose.location = (0, 0, 0)
        else:
          local = bone.matrix_local.to_quaternion().inverted() @ rotation
          offset = (transform.translation - hipsReference) * heightScale
          pose.location = bone.matrix_local.to_quaternion().inverted() @ offset
        local.normalize()
        if pose.name in previous and previous[pose.name].dot(local) < 0:
          local.negate()
        previous[pose.name] = local.copy()
        pose.rotation_mode = 'QUATERNION'
        pose.rotation_quaternion = local
        pose.scale = (1, 1, 1)
        pose.keyframe_insert('rotation_quaternion', frame=frame, group=pose.name)
        pose.keyframe_insert('location', frame=frame, group=pose.name)
        desired[pose.name] = rotation
    actions.append(action)
    specs.append({
      'name': name, 'source': Source.name, 'kind': 'universal',
      'duration': round(duration, 6),
      'loop': name.endswith('_Loop') or name == 'Sword_Idle',
      'hold': name in Held, 'next': Following.get(name, ''),
      'rootMotion': False,
    })
    print('UNIVERSAL_RETARGETED', name, round(duration, 3), flush=True)
  return actions, specs
