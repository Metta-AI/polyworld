import std/os

import vmath
import gltf
import polyworld/characters

const
  TestDirectory = currentSourcePath().parentDir
  SamplePath = TestDirectory / "data/composed_static_scene.glb"

proc close(left, right: float32): bool =
  abs(left - right) < 0.0001'f32

echo "Testing composed static glTF scenes preserve authored node transforms"
block:
  let model = loadStaticSceneModel(SamplePath)
  doAssert model.file.root.nodes.len == 1
  doAssert model.file.root.nodes[0].nodes.len == 2
  doAssert model.file.root.nodes[0].nodes[0].name == "trunk"
  doAssert model.file.root.nodes[0].nodes[1].name == "crown"
  doAssert model.bounds.min.x.close(1'f32)
  doAssert model.bounds.min.y.close(0'f32)
  doAssert model.bounds.max.x.close(2.5'f32)
  doAssert model.bounds.max.y.close(2'f32)
  for node in model.file.root.walkNodes:
    if node.mesh != nil:
      for primitive in node.mesh.primitives:
        doAssert primitive.normals.len == primitive.points.len
        for normal in primitive.normals:
          doAssert length(normal - vec3(0, 0, 1)) < 0.0001

echo "Testing composed static glTF scenes receive one root placement"
block:
  let
    model = loadStaticSceneModel(SamplePath)
    transform = staticSceneTransform(
      vec3(10, 4, -3), sizeFactor = 2'f32)
    placedMinimum = transform * model.bounds.min
    placedMaximum = transform * model.bounds.max
  doAssert placedMinimum.x.close(12'f32)
  doAssert placedMinimum.y.close(4'f32)
  doAssert placedMinimum.z.close(-3'f32)
  doAssert placedMaximum.x.close(15'f32)
  doAssert placedMaximum.y.close(8'f32)
  doAssert placedMaximum.z.close(-3'f32)

echo "Static scene model tests passed"
