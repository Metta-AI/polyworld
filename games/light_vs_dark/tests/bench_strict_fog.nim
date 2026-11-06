## Native-only isolated steady-state render A/B. Never changes production switches.
## Run from repository root; see docs/strict-fog-profile.md.
import std/[os, json, monotimes, times, macros]
import opengl, windy, vmath
import polyworld/[assets, quadterrain, shadows, toon, particles, particleshaders, pathing, visions]
import ../[assets, buildings, factions, maps, sim, content, groves, rendervisibility, strictfog]

const Warmup = 60
const Samples = 32
const Repeats = 3
let outputDir = getEnv("LVD_FOG_PROFILE_OUT", getTempDir() / "lvd-fog-profile")
createDir(outputDir)
let output = open(outputDir / "frames.jsonl", fmWrite)

let window = newWindow("LvD native strict fog benchmark", ivec2(800,500),
  visible=false, vsync=false, msaa=msaa4x)
window.makeContextCurrent()
loadExtensions()
var bits: GLint
glGetQueryiv(GL_TIME_ELAPSED, GL_QUERY_COUNTER_BITS, bits.addr)
let timerError = glGetError()
let gpuTimers = timerError == GL_NO_ERROR and bits > 0
output.writeLine($(%*{"type":"metadata", "renderer": $cast[cstring](glGetString(GL_RENDERER)),
  "version": $cast[cstring](glGetString(GL_VERSION)), "vendor": $cast[cstring](glGetString(GL_VENDOR)),
  "gpu_timer":gpuTimers, "timer_counter_bits":bits, "timer_probe_error":timerError.int,
  "warmup":Warmup,"samples":Samples,"repeats":Repeats,"msaa":4,
  "terrain_texture_size":LvdTerrainAssets.size,"shadow_size":SunShadowMapSize,
  "timer_method":"single GL_TIME_ELAPSED query over complete frame; 64-bit result retrieval",
  "pairing":"adjacent off/on frames; alternated by sample and repeat",
  "sync":"glFinish before first sample and after every frame; no swap/present",
  "scope":"steady-state ground+props+shadows+water+particles; no simulation, characters, UI or rebake"}))
initTerrain(NoTrees, GeneratedTerrain, NoRocks, LvdTerrainTiles, settings=LvdTerrainAssets)
setTileMaterial(RockTile.int,LvdRockSurface,LvdRockSurface,vec3(1),vec3(0.85),4)
setTileMaterial(StoneTile.int,LvdStoneSurface,LvdRockSurface,vec3(1),vec3(0.85),6)
initSunShadows(lightRadius=100)
sunShadowsEnabled=true
# Two native 4096 shadow maps as with an interpolated day clock.
sunShadowBlend=0.5
let run = newGame(generateMap(DefaultSeed), TickRate*180)
let half = run.world.map.side.float32/2
let toonContext = newToonContext()
setEnvironmentPalette(toonContext)
let grove = generateGrove(DefaultSeed,{LightTree,LightRock})
let buildingArt = loadBuildingArt(grove,factions=[Emerald,Emerald])
let allScenery = grovePlacements(run.world.treeWood,DefaultSeed,run.world.map.forestRocks)
var scenery: seq[GrovePlacement]
let viewMode = 1'i32
# Deterministic presentation fixture: western half current, eastern half explored.
# Set up once, before recording the authoritative read-only hash.
for y in 0..<run.world.map.side:
  for x in 0..<run.world.map.side:
    let i = run.world.map.tileIndex(x,y)
    run.world.explored[0][i]=1
    run.world.visibleStamp[0][i] = (if x < run.world.map.side div 2: run.world.visionGeneration[0] else: 0)
proc shownBuilding(b:Building):bool = run.world.renderBuildingVisible(viewMode,b)
proc buildingCentre(b:Building):Vec3 =
  let x=b.origin.x.float32+b.footprint.width.float32/2-half
  let z=b.origin.y.float32+b.footprint.depth.float32/2-half
  vec3(x,groundHeight(x,z)+groundOffset(x,z),z)
macro productionPlacement():untyped =
  for n in parseStmt(staticRead("../graphics.nim")):
    if n.kind==nnkProcDef and n[0].repr=="runGraphics*":
      for child in n[^1]:
        if child.kind==nnkProcDef and child[0].repr=="placeSceneProps":
          result=child
          result[4]=newEmptyNode()
          return
  error("Missing production placement")
productionPlacement()
let sight=run.world.renderVisibilityValues(viewMode,CurrentSightMask)
uploadTerrainVisibility(blurVisibility(run.world.renderVisibilityValues(viewMode,TerrainMemoryMask),
  run.world.map.side,run.world.map.side),run.world.map.side.int)
uploadAmbientOcclusion(@[255'u8,255,255,255],1,vec2(-half),vec2(half*2))
bakeTerrain(rebuildWalkability=false)
let stateBefore=run.stateHash()
var waterLayers=0
for layer in layers:
  if layer.water: inc waterLayers
output.writeLine($(%*{"type":"fixture","seed":DefaultSeed,"map_side":run.world.map.side,
  "map_hash": $run.world.map.hash,"state_hash": $stateBefore,"scenery_total":allScenery.len,
  "current_sight":"western half; eastern half explored","shadow_maps":2,
  "water_layers":waterLayers,"eye":[0,27,34],"target":[0,0,0],"fov_degrees":45}))
var fog=initStrictFog()
var effects=initParticleSystem()
for z in [-6'f32,0,6]:
  effects.emitParticleBurst(FireBurst,vec3(-8,groundHeight(-8,z)+2,z))
effects.advanceParticles(0.2)
let eye=vec3(0,27,34)
let view=lookAt(eye,vec3(0),vec3(0,1,0))
let forward=normalize(-eye)
let right=normalize(cross(forward,vec3(0,1,0)))
let up=normalize(cross(right,forward))
var target, colorBuffer, depthBuffer:GLuint
glGenFramebuffers(1,target.addr)
glGenRenderbuffers(1,colorBuffer.addr)
glGenRenderbuffers(1,depthBuffer.addr)
var queries:array[4,GLuint]
if gpuTimers: glGenQueries(4,queries[0].addr)
proc nowMs():float64 = getMonoTime().ticks.float64/1_000_000
proc targetSize(size:IVec2) =
  glBindFramebuffer(GL_FRAMEBUFFER,target)
  glBindRenderbuffer(GL_RENDERBUFFER,colorBuffer)
  glRenderbufferStorageMultisample(GL_RENDERBUFFER,4,GL_RGBA8,size.x,size.y)
  glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_RENDERBUFFER,colorBuffer)
  glBindRenderbuffer(GL_RENDERBUFFER,depthBuffer)
  glRenderbufferStorageMultisample(GL_RENDERBUFFER,4,GL_DEPTH_COMPONENT24,size.x,size.y)
  glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_RENDERBUFFER,depthBuffer)
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE
  var actual:GLint
  glGetIntegerv(GL_SAMPLES,actual.addr)
  doAssert actual==4
proc frame(strict:bool,size:IVec2):JsonNode =
  let vp=perspective(45'f32*PI.float32/180,size.x.float32/size.y.float32,0.1'f32,300'f32)*view
  var cpu:array[4,float64]
  template stage(index:int,body:untyped) =
    block:
      let started=nowMs()
      body
      cpu[index]=nowMs()-started
  let started=nowMs()
  if gpuTimers: glBeginQuery(GL_TIME_ELAPSED,queries[0])
  stage(0):
    glDepthMask(GL_TRUE)
    sunDepthPasses(size): drawTerrainSunDepth()
    glBindFramebuffer(GL_FRAMEBUFFER,target)
    glViewport(0,0,size.x,size.y)
    glEnable(GL_MULTISAMPLE)
    glClearColor(0.05,0.06,0.09,1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    toonContext.drawBackground()
  stage(1):
    if strict:
      fog.beginStrictGround(size)
      glDepthMask(GL_TRUE)
      glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
      toonContext.drawBackground()
      let enabled=sunShadowsEnabled
      sunShadowsEnabled=false
      drawTerrain(vp,false,drawProps=false)
      sunShadowsEnabled=enabled
      drawWater(vp,eye,opacity=0.5'f32,highlightOpacity=0'f32)
      fog.captureStrictGround(size,inverse(vp),sight,run.world.map.side.int)
      glDepthMask(GL_TRUE)
      glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
      toonContext.drawBackground()
  stage(2):
    drawTerrain(vp,false)
    drawWater(vp,eye,opacity=0.5'f32,highlightOpacity=0'f32)
    effects.drawParticles(vp,right,up,forward,sight,run.world.map.side.int,vec2(-half),visibilityPadding=5)
  stage(3):
    if strict: fog.restoreHiddenGround()
  if gpuTimers: glEndQuery(GL_TIME_ELAPSED)
  let submitted=nowMs()
  glFinish()
  let completed=nowMs()
  doAssert glGetError()==GL_NO_ERROR
  result = %*{"cpu_submit_ms":submitted-started,"finish_wait_ms":completed-submitted,
    "complete_ms":completed-started,"cpu_stages_ms":cpu}
  if gpuTimers:
    var ns:GLuint64
    glGetQueryObjectui64v(queries[0],GL_QUERY_RESULT,ns.addr)
    result["gpu_ms"] = %(ns.float64/1_000_000)

for density in ["sparse","dense"]:
  scenery.setLen(0)
  for i,p in allScenery:
    if density=="dense" or i mod 16==0: scenery.add p
  placeSceneProps()
  bakeProps()
  var submittedProps=0
  for p in scenery:
    if run.world.renderTileVisible(viewMode,int32(p.tile mod run.world.map.side.int),int32(p.tile div run.world.map.side.int)):
      inc submittedProps
  var submittedBuildings=0
  for b in run.world.buildings:
    if shownBuilding(b): inc submittedBuildings
  echo density," scenery=",scenery.len," submitted=",submittedProps," buildings=",submittedBuildings
  for width in [800,1600]:
    let size=ivec2(width.int32,(width*5 div 8).int32)
    targetSize(size)
    for repeat in 0..<Repeats:
      # Warm both variants, then pair adjacent frames and alternate pair order.
      # This reduces DVFS/drift bias relative to long off/on blocks.
      for _ in 0..<Warmup:
        discard frame(false,size)
        discard frame(true,size)
      glFinish()
      for sample in 0..<Samples:
        for order in 0..1:
          let strict=(order+repeat+sample) mod 2==1
          var row=frame(strict,size)
          row["type"] = %"frame"
          row["density"] = %density
          row["width"] = %width
          row["height"] = %size.y
          row["strict"] = %strict
          row["repeat"] = %repeat
          row["sample"] = %sample
          row["scenery_submitted"] = %submittedProps
          row["buildings_submitted"] = %submittedBuildings
          output.writeLine($row)
      output.flushFile()
      echo density," ",width," repeat=",repeat," paired capture complete"
doAssert run.stateHash()==stateBefore,"Renderer changed authoritative state"
output.writeLine($(%*{"type":"verified","state_hash": $stateBefore,"gl_error":0}))
fog.closeStrictFog()
effects.closeParticles()
if gpuTimers: glDeleteQueries(4,queries[0].addr)
glDeleteFramebuffers(1,target.addr)
glDeleteRenderbuffers(1,colorBuffer.addr)
glDeleteRenderbuffers(1,depthBuffer.addr)
window.close()
output.close()
echo "Saved ",outputDir / "frames.jsonl"
