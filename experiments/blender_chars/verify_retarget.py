"""Compare exported arm motion to the original skin, independently of Blender."""

import json
import math
import sys
from pathlib import Path

from mathutils import Matrix, Vector

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from retarget import FrameRate, Source, Prefix, accessor, quaternion, readGlb, sample

Output = Path(__file__).resolve().parent / "assets"
Preview = Output.parents[2] / "tmp/blender_chars"


def bindMatrices(document, binary, meshName):
  """Read inverse bind matrices from the actual source and exported skins."""
  node = next(node for node in document["nodes"] if node.get("name") == meshName)
  skin = document["skins"][node["skin"]]
  matrices = accessor(document, binary, skin["inverseBindMatrices"])
  return {document["nodes"][joint]["name"]:
          Matrix([values[i:i + 4] for i in range(0, 16, 4)]).transposed()
          for joint, values in zip(skin["joints"], matrices)}


def evaluator(document, binary, clip):
  """Create a glTF sampler that accumulates each original node hierarchy."""
  nodes = document["nodes"]
  parents = {child: i for i, node in enumerate(nodes)
             for child in node.get("children", [])}
  tracks = {}
  for channel in clip["channels"]:
    path = channel["target"]["path"]
    if path not in ["rotation", "translation", "scale"]:
      continue
    sampler = clip["samplers"][channel["sampler"]]
    tracks[channel["target"]["node"], path] = (
      [key[0] for key in accessor(document, binary, sampler["input"])],
      accessor(document, binary, sampler["output"]),
      sampler.get("interpolation", "LINEAR")
    )

  def evaluate(time):
    """Resolve source motion at one exact time in glTF coordinates."""
    cache = {}

    def world(index):
      """Apply animation channels before composing the parent transform."""
      if index in cache:
        return cache[index]
      node = nodes[index]
      values = {}
      for path, default in [("translation", [0, 0, 0]),
                            ("rotation", [0, 0, 0, 1]),
                            ("scale", [1, 1, 1])]:
        track = tracks.get((index, path))
        values[path] = (sample(track, time, path) if track else
          (quaternion(node.get(path, default)) if path == "rotation"
           else Vector(node.get(path, default))))
      transform = Matrix.LocRotScale(values["translation"],
                                    values["rotation"], values["scale"])
      if index in parents:
        transform = world(parents[index]) @ transform
      cache[index] = transform
      return transform

    return {node.get("name", ""): world(i) for i, node in enumerate(nodes)}

  return evaluate


source, sourceBytes = readGlb(Source)
target, targetBytes = readGlb(Output / "character.glb")
sourceBinds = bindMatrices(source, sourceBytes, "Body_White_1")
targetBinds = bindMatrices(target, targetBytes, "Body")
targetBinds = {name: matrix for name, matrix in targetBinds.items()
               if name.endswith(("Shoulder", "Arm", "Hand"))}
animations = {clip["name"]: clip for clip in target["animations"]}
report = {"clips": {}, "comparison": "Arm skin rotation at every bake frame"}
for clip in source["animations"]:
  name = clip["name"]
  readSource = evaluator(source, sourceBytes, clip)
  readTarget = evaluator(target, targetBytes, animations[name])
  duration = max(accessor(source, sourceBytes, sampler["input"])[-1][0]
                 for sampler in clip["samplers"])
  errors = {name: 0 for name in targetBinds}
  for frame in range(round(duration * FrameRate) + 1):
    time = min(frame / FrameRate, duration)
    original = readSource(time)
    exported = readTarget(time)
    for bone, inverseBind in targetBinds.items():
      sourceName = Prefix + bone
      expected = (original[sourceName] @ sourceBinds[sourceName]).to_quaternion()
      actual = (exported[bone] @ inverseBind).to_quaternion()
      error = math.degrees(2 * math.acos(min(1, abs(expected.dot(actual)))))
      errors[bone] = max(errors[bone], error)
      assert error < .3, (name, bone, frame, error)
  report["clips"][name] = {bone: round(error, 4) for bone, error in errors.items()}
report["maxDegrees"] = max(error for clip in report["clips"].values()
                            for error in clip.values())
report["preservedClips"] = len(report["clips"])
(Preview / "retarget_verification.json").write_text(
  json.dumps(report, indent=2) + "\n")
print("RETARGET_VERIFIED", report["preservedClips"], "clips, maximum error",
      report["maxDegrees"], "degrees")
