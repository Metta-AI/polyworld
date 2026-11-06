## Actual mine art + production harvest anchor + real mining in a native FBO.
import std/[macros, os]
import opengl, windy, vmath, pixie
import polyworld/[assets, groves, quadterrain, shadows, toon, worldbars]
import ../[content, maps, sim, buildings, factions, harvestpresentation]
let window = newWindow("Mine entrance VFX",ivec2(640),visible=false,vsync=false)
window.makeContextCurrent()
loadExtensions()
var fbo, texture, depth: GLuint
glGenFramebuffers(1,fbo.addr)
glBindFramebuffer(GL_FRAMEBUFFER,fbo)
glGenTextures(1,texture.addr)
glBindTexture(GL_TEXTURE_2D,texture)
glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8.GLint,640,640,0,GL_RGBA,GL_UNSIGNED_BYTE,nil)
glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0)
glGenRenderbuffers(1,depth.addr)
glBindRenderbuffer(GL_RENDERBUFFER,depth)
glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH_COMPONENT24,640,640)
glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_RENDERBUFFER,depth)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE
initTerrain(treeStyle=NoTrees,rockStyle=NoRocks,terrainStyle=GeneratedTerrain,settings=TerrainAssets(size:256))
initSunShadows()
sunShadowsEnabled=false
let grove = generateGrove(DefaultSeed,{LightTree,LightRock})
let buildingArt = loadBuildingArt(grove,factions=[Emerald,Emerald])
let context = newToonContext()
setEnvironmentPalette(context)
let run = newGame(generateMap(DefaultSeed),TickRate*180)
let w = run.world
proc mapHalf(): float32 = w.map.side.float32/2
proc surfaceHeight(x,z:float32):float32 = 0
proc buildingCentre(b:Building):Vec3 =
  vec3(b.origin.x.float32+b.footprint.width.float32/2-mapHalf(),0,
    b.origin.y.float32+b.footprint.depth.float32/2-mapHalf())
macro productionAnchor(): untyped =
  for node in parseStmt(staticRead("../graphics.nim")):
    if node.kind==nnkProcDef and node[0].repr=="runGraphics*":
      for child in node[^1]:
        if child.kind==nnkProcDef and child[0].repr=="harvestAnchor": return child
  error("Missing production anchor")
productionAnchor()
let worker=w.units[0]
var target = -1'i32
var best=int32.high
for b in w.buildings:
  if b.kind==GoldMineBuilding:
    let d=tileDistance(worker.tile,b.origin)
    if d<best: best=d; target=b.id
doAssert w.applyHarvest(worker.owner,worker.id,target,0)
for _ in 0..<TickRate*60:
  w.tickWorld(nil)
  if worker.state==UnitInMine: break
doAssert worker.state==UnitInMine
var fx:HarvestPresentation
fx.updateHarvest(w,0.01,-1)
for _ in 0..<2: fx.updateHarvest(w,0.08,-1)
doAssert fx.siteCount==1
let centre=harvestAnchor(fx.sites[0])
let mine=w.buildings[w.buildingIndex(target)]
var bars=initWorldBarRenderer()
proc draw(effects:bool, viewer = -1'i32):Image =
  glBindFramebuffer(GL_FRAMEBUFFER,fbo)
  glViewport(0,0,640,640)
  glDepthMask(GL_TRUE)
  glClearColor(0.08,0.1,0.12,1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  let view=lookAt(centre+vec3(0,3,4),centre,vec3(0,1,0))
  let projection=ortho(-2.5'f32,2.5'f32,-2.5'f32,2.5'f32,0.1'f32,50'f32)
  for part in buildingArt.buildingParts(mine,buildingCentre(mine)):
    part.pack.drawProp(part.name,part.position,part.rotation,part.scale,projection*view)
  bars.clear()
  if effects: bars.addHarvestBillboards(fx,w,viewer,harvestAnchor)
  bars.draw(projection*view,vec3(1,0,0),vec3(0,0.8,-0.6))
  result=newImage(640,640)
  glReadPixels(0,0,640,640,GL_RGBA,GL_UNSIGNED_BYTE,result.data[0].addr)
  result.flipVertical()
proc changed(a,b:Image):int =
  for i in 0..<a.data.len:
    if a.data[i]!=b.data[i]: inc result
let before=run.stateHash()
let blank=draw(false)
let active=draw(true)
let count=changed(blank,active)
echo "Actual mine entrance depth-tested spark pixels=",count
doAssert count>0
active.writeFile(getEnv("LVD_HARVEST_FIXTURE", getTempDir())/"MineSparks-scene.png")
for cell in w.visibleStamp[0].mitems: cell=0
for seen in w.explored[0].mitems: seen=1
doAssert changed(blank,draw(true,0))==0
# Render itself never advances authoritative mining.
doAssert run.stateHash()==before
bars.closeWorldBarRenderer()
window.close()
