"""Check every exported Universal frame against the authored source motion."""

import json
import math
import sys
from pathlib import Path

import bpy

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Library = Root.parent / 'polyworld_data/characters/chargen'
Preview = Root / 'tmp/chargen'
sys.path.insert(0, str(Experiment))
sys.dont_write_bytecode = True
from retarget import FrameRate, readGlb, targetTpose
from universal import Bones, Source, evaluator

bpy.ops.wm.open_mainfile(filepath=str(Library / 'source/character.blend'))
rig = bpy.data.objects['CharacterRig']
source, sourceBytes = readGlb(Source)
target, targetBytes = readGlb(Preview / 'character.glb')
animations = {clip['name']: clip for clip in target['animations']}
reference = next(clip for clip in source['animations'] if clip['name'] == 'A_TPose')
sourcePose = evaluator(source, sourceBytes, reference)[0](0)
targetPose = targetTpose(rig)
hipsReference = sourcePose['pelvis'].translation
heightScale = rig.data.bones['Hips'].head_local.z / hipsReference.z
report = {'source': str(Source), 'clips': {}, 'maxDegrees': 0, 'maxHipError': 0}
assert len(source['animations']) == 43
for clip in source['animations']:
  name = clip['name']
  readSource, duration = evaluator(source, sourceBytes, clip)
  readTarget, exportedDuration = evaluator(target, targetBytes, animations[name])
  assert abs(duration - exportedDuration) < 1e-5, name
  error, hipError = 0, 0
  for frame in range(round(duration * FrameRate) + 1):
    time = min(frame / FrameRate, duration)
    original, exported = readSource(time), readTarget(time)
    for bone, sourceBone in Bones.items():
      expected = (original[sourceBone].to_quaternion() @
        sourcePose[sourceBone].to_quaternion().inverted() @ targetPose[bone]).normalized()
      actual = exported[bone].to_quaternion().normalized()
      difference = math.degrees(2 * math.acos(min(1, abs(expected.dot(actual)))))
      error = max(error, difference)
      assert difference < .2, (name, bone, frame, difference)
      if rig.data.bones[bone].parent:
        parent = rig.data.bones[bone].parent.name
        actualLength = (exported[bone].translation - exported[parent].translation).length
        restLength = (rig.data.bones[bone].head_local - rig.data.bones[parent].head_local).length
        assert abs(actualLength - restLength) < 1e-4, (name, bone, 'Limb stretched')
    expectedHip = rig.data.bones['Hips'].head_local + (
      original['pelvis'].translation - hipsReference) * heightScale
    hipError = max(hipError, (exported['Hips'].translation - expectedHip).length)
  assert hipError < 1e-4, (name, hipError)
  report['clips'][name] = {'degrees': error, 'hipError': hipError, 'duration': duration}
  report['maxDegrees'] = max(report['maxDegrees'], error)
  report['maxHipError'] = max(report['maxHipError'], hipError)
  print('CHECKED', name, round(error, 4), flush=True)
(Preview / 'universal_verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('UNIVERSAL_VERIFIED', len(report['clips']), 'clips, max rotation error',
      report['maxDegrees'], 'max hip error', report['maxHipError'], flush=True)
