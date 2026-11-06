'use strict';
// Extension of the real two-human canvas harness. Observation only; no commands
// are injected and no gameplay state is written. Run LVD_QA_BUILDING=1 with it.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {createRequire} = require('node:module');
const {spawnSync} = require('node:child_process');
const {authoritativeReceipt} = require('./browser_lvd_social.cjs');
const scratch = process.env.LVD_QA_DEPS || '/Users/me/.hermes/cache/scratch/lvd-browser-qa';
const {PNG} = createRequire(path.join(scratch, 'package.json'))('pngjs');

function yellow(file, box) {
  const p=PNG.sync.read(fs.readFileSync(file));
  let n=0,sx=0,sy=0,minX=p.width,minY=p.height,maxX=-1,maxY=-1;
  for(let y=box.y;y<box.y+box.height;y++)for(let x=box.x;x<box.x+box.width;x++){
    const i=(y*p.width+x)*4, [r,g,b]=p.data.subarray(i,i+3);
    if(r>200 && g>180 && b<100){n++;sx+=x;sy+=y;minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);}
  }
  return {pixels:n,x:n?sx/n:null,y:n?sy/n:null,minX,minY,maxX,maxY};
}
function crop(file, box, dest, scale=3) {
  const input=PNG.sync.read(fs.readFileSync(file));
  const p=new PNG({width:box.width*scale,height:box.height*scale});
  for(let y=0;y<p.height;y++)for(let x=0;x<p.width;x++){
    const src=((box.y+Math.floor(y/scale))*input.width+box.x+Math.floor(x/scale))*4;
    input.data.copy(p.data,(y*p.width+x)*4,src,src+4);
  }
  fs.writeFileSync(dest,PNG.sync.write(p));return dest;
}
// macOS Vision OCR reads framebuffer screenshots only. Compile this test helper
// into scratch, never the repository/build tree. No production instrumentation.
function prepareOcr(out) {
  const source=path.join(out,'screen-ocr.swift'), binary=path.join(out,'screen-ocr');
  fs.writeFileSync(source,`import Foundation
import Vision
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(url: url, options: [:])
try handler.perform([request])
let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let bytes = try JSONSerialization.data(withJSONObject: strings)
print(String(data: bytes, encoding: .utf8)!)
`);
  const compile=spawnSync('swiftc',[source,'-o',binary],{encoding:'utf8',timeout:60000});
  assert.equal(compile.status,0,'screenshot OCR compiler: '+compile.stderr);
  return file=>{
    const result=spawnSync(binary,[file],{encoding:'utf8',timeout:10000});
    assert.equal(result.status,0,'screenshot OCR: '+result.stderr);
    return JSON.parse(result.stdout);
  };
}
function assertOverlap(move,build) {
  assert.equal(move.action[0],1,'prior ordinary ActionMove');
  assert.equal(build.action[0],4,'ActionBuild');
  assert.equal(build.action[2],move.action[2],'build uses same worker moved into open ground');
  assert.equal(build.action[3],1,'FarmBuilding enum');
  const [x,y]=move.action.slice(3,5), [bx,by]=build.action.slice(4,6);
  assert.ok(x>=bx && x<bx+2 && y>=by && y<by+2,
    `assigned worker target (${x},${y}) must be inside farm footprint (${bx},${by}) 2x2`);
}
function activeTab(file) {
  // The active label/icon is gold, inactive labels blue-gray. Source ui.nim
  // CommandTabH/CommandTabLift and fresh 1514x970 Auto HUD scale 0.5.
  const build=yellow(file,{x:1340,y:858,width:54,height:16}).pixels;
  const units=yellow(file,{x:1396,y:858,width:53,height:16}).pixels;
  assert.ok(Math.max(build,units)>8,'active command tab gold text must render');
  return {tab:build>units?'Build':'Units',build,units};
}
async function runBuilding({peers,report,wait,click,shot,last,step}) {
  const peer=peers[0], page=peer.page, out=report.out;
  const building=report.building={passed:false,events:[],screenshots:[],
    visualReviewRequired:['construction interior and working pose (PNG sequence)','completed Farm appearance'],
    mineEntry:{tested:false},layout:{ground:{x:610,y:560},mine:{x:70,y:425}},
    proof:'authoritative two-peer payloads + framebuffer OCR food capacity + same-tick hashes'};
  const ocr=prepareOcr(out);
  const screenshot=async name=>{await shot(peer,name);const f=path.join(out,peer.role+'-'+name+'.png');building.screenshots.push(f);return f;};
  const readFood=async name=>{
    const file=await screenshot(name);
    const words=ocr(crop(file,{x:765,y:0,width:135,height:40},path.join(out,name+'-food.png'),4));
    const ratio=words.join(' ').replace(/\s/g,'').match(/5\/[59]/)?.[0];
    building.foodReadings??=[];building.foodReadings.push({name,words,ratio});
    return ratio;
  };
  const frame=()=>page.evaluate(()=>window.__lvdFrames.at(-1)?.tick || 0);
  async function submitted(offset,label,kind) {
    await wait(label+' SubmitCommand',()=>peer.messages.slice(offset).some(m=>m.direction==='out'&&m.kind==='SubmitCommand'),6000);
    const commands=peer.messages.slice(offset).filter(m=>m.direction==='out'&&m.kind==='SubmitCommand');
    assert.equal(new Set(commands.map(c=>c.sequence)).size,1,label+' exactly one command');
    const command=commands[0];assert.equal(command.action?.[0],kind,label+' action');
    assert.equal(command.seat,0);assert.equal(command.match,last(peer,'BeginMatch').match);
    const owner=last(peer,'Welcome').participant;
    await wait(label+' on both authoritative streams',()=>peers.every(p=>authoritativeReceipt(p,owner,command)));
    const receipts=peers.map(p=>authoritativeReceipt(p,owner,command));
    assert.equal(receipts[0].tick,receipts[1].tick);
    await wait(label+' applied',async()=>{
      const ticks=await Promise.all(peers.map(p=>p.page.evaluate(()=>window.__lvdFrames.at(-1)?.tick||0)));
      return ticks.every(t=>t>=receipts[0].tick);
    });
    const event={label,command,authoritativeTick:receipts[0].tick};building.events.push(event);return command;
  }
  async function checkpoint(after,label) {
    let found;
    await wait(label,()=>{
      const match=last(peer,'BeginMatch').match;
      const hs=peers[0].messages.filter(m=>m.direction==='out'&&m.kind==='ReportHash'&&m.match===match&&m.tick>after);
      const gs=peers[1].messages.filter(m=>m.direction==='out'&&m.kind==='ReportHash'&&m.match===match&&m.tick>after);
      for(const h of hs){const g=gs.find(g=>g.tick===h.tick);if(g){assert.equal(h.hash,g.hash,label);found={match,tick:h.tick,hash:h.hash};}}
      return found;
    },20000);return found;
  }
  await page.bringToFront();await page.mouse.move(757,650);
  await page.keyboard.press('t',{delay:140});await page.waitForTimeout(250);
  building.unitsTab=activeTab(await screenshot('building-T-units'));
  assert.equal(building.unitsTab.tab,'Units','T must select Units');
  // Expire the first sequence without Escape (Escape can open the match menu).
  await page.waitForTimeout(1400);await page.keyboard.press('b',{delay:140});
  await page.waitForTimeout(250);
  building.buildTab=activeTab(await screenshot('building-B-build'));
  assert.equal(building.buildTab.tab,'Build','B must select Build');
  await page.waitForTimeout(1400);
  assert.equal(await readFood('building-before'),'5/5','fresh two-human food capacity');
  // Previous harness movement leaves this worker selected. Move it well clear
  // of its spawn crowd; use that SAME ground click for the eventual blueprint.
  let offset=peer.messages.length;
  await click(page,610,560,'right');
  const move=await submitted(offset,'open-ground worker move',1);
  await page.waitForTimeout(3500);
  const roi={x:360,y:300,width:420,height:380};
  const first=yellow(await screenshot('building-worker-open'),roi);
  await page.waitForTimeout(800);
  const settled=yellow(await screenshot('building-worker-settled'),roi);
  assert.ok(first.pixels>50 && settled.pixels>50,'selected worker is visible on open ground');
  assert.ok(Math.hypot(first.x-settled.x,first.y-settled.y)<8,'worker must settle before overlapping placement');
  building.worker={move:move.action,first,settled};
  offset=peer.messages.length;
  await page.keyboard.press('b',{delay:140});await page.keyboard.press('f',{delay:140});
  await page.mouse.move(610,560);await page.waitForTimeout(250);
  await screenshot('building-BF-over-worker-blueprint');
  assert.equal(peer.messages.slice(offset).filter(m=>m.direction==='out'&&m.kind==='SubmitCommand').length,0,'arming BF must not issue gameplay');
  await click(page,610,560,'left');
  const build=await submitted(offset,'LEFT-click farm over assigned peon',4);
  assertOverlap(move,build);building.overlap={moveTile:move.action.slice(3,5),farmOrigin:build.action.slice(4,6),footprint:[2,2]};
  // Construction lasts 240 authoritative ticks. Save early repeated frames for
  // inside-builder pose review; never replace this with sent-command evidence.
  const buildTick=building.events.at(-1).authoritativeTick;
  building.construction=[];
  for(let i=0;i<5;i++){
    const tick=await frame();const file=await screenshot('building-construction-'+i);
    building.construction.push({tick,file,outline:yellow(file,roi)});
    await page.waitForTimeout(500);
  }
  assert.ok(building.construction.some(s=>s.tick>buildTick&&s.tick<buildTick+240),'capture an unfinished construction frame');
  let food;
  await wait('Farm completes: HUD FOOD 5/9 (source counts only BuildingComplete)',async()=>{
    food=await readFood('building-completion-check-'+building.foodReadings.length);return food==='5/9';
  },30000);
  building.completed={food,tick:await frame(),source:'sim.nim recounts food only from BuildingComplete; content.nim Farm provides 4, takes 240 ticks'};
  assert.ok(building.completed.tick>=buildTick+240,'completion cannot precede farm build duration');
  await screenshot('building-completed');
  building.completionCheckpoint=await checkpoint(building.completed.tick,'post-completion matching peer hashes');
  step('Farm: LEFT click over moved assigned peon, authoritative Build on both peers, FOOD 5/5 → 5/9, post-completion shared hash');

  if(process.env.LVD_QA_MINE==='1') {
    building.mineEntry={tested:true,passed:false,visualReviewRequired:true};
    // Pick another untouched spawn worker, order harvest FIRST, then arm BF
    // while it walks. Blueprint activation must not replace its harvest order.
    await click(page,828,447);offset=peer.messages.length;
    await click(page,70,425,'right');
    const harvest=await submitted(offset,'mine harvest before blueprint',3);
    await page.keyboard.press('b',{delay:140});await page.keyboard.press('f',{delay:140});
    await page.mouse.move(610,650);await screenshot('mine-approach-blueprint');
    const mineRoi={x:0,y:200,width:500,height:450};
    let sawApproach=false,absent=0;
    await wait('selected miner enters mine and disappears',async()=>{
      const file=await screenshot('mine-tracking-'+building.screenshots.length), outline=yellow(file,mineRoi);
      if(outline.pixels>50){sawApproach=true;absent=0;}else if(sawApproach)absent++;
      return sawApproach&&absent>=2;
    },25000);
    building.mineEntry.harvest=harvest;
    const noBuildOffset=peer.messages.length;
    await screenshot('mine-entered-blueprint-cancelled');
    await click(page,610,650,'left');await page.waitForTimeout(500);
    assert.equal(peer.messages.slice(noBuildOffset).filter(m=>m.direction==='out'&&m.kind==='SubmitCommand'&&m.action?.[0]===4).length,0,'mine entry must cancel blueprint, not place at next left click');
    await screenshot('mine-post-entry-leftclick');
    building.mineEntry.passed=true;
    building.mineEntry.note='Mine entry inferred from authoritative harvest then outlined miner arrival/disappearance; inspect ghost-cancel PNGs. No direct state export.';
  }else building.mineEntry.reason='Not exercised: opt in with LVD_QA_MINE=1; screenshot-only mine location needs inspection on current map.';
  building.passed=true;
}
module.exports={runBuilding,assertOverlap,activeTab,yellow,crop};
if(require.main===module){
  process.env.LVD_QA_BUILDING='1';
  require('./browser_lvd_multiplayer.cjs');
}
