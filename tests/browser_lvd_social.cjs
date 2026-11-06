'use strict';
// Browser acceptance helpers only: decode observations, never inject game state.
const assert = require('node:assert/strict');

function decodePayload(payload) {
  const b = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'hex');
  assert.ok(b.length >= 4, 'LvD payload needs a category');
  if (b.readInt32LE(0) === 0) {
    assert.ok(b.length >= 16, 'truncated Chat header');
    const length = b.readUInt32LE(12);
    assert.ok(length <= 1024, 'Chat exceeds MaxChatBytes');
    assert.equal(b.length, 16 + length, 'Chat length/trailing bytes');
    const text = new TextDecoder('utf-8', {fatal:true}).decode(b.subarray(16));
    return {payload:b.toString('hex'), chat:{sender:b.readInt32LE(4), target:b.readInt32LE(8), text}};
  }
  assert.equal(b.length, 36, 'LvD ReplayAction is nine int32 fields');
  return {payload:b.toString('hex'), action:Array.from({length:9}, (_,i)=>b.readInt32LE(i*4))};
}

function socialLayout(width = 1514, height = 970, scale = 0.5) {
  // ui.nim drawHumanCommunication, chrome.nim gameUiScale (Auto at this viewport).
  const w = width/scale, h = height/scale;
  const panelWidth = Math.min(660, w-24);
  const rows = Math.max(1, Math.min(6, Math.trunc((h-148)/92)));
  const panelHeight = 100 + rows*92;
  const x = (w-panelWidth)/2, y = Math.max(12, (h-panelHeight)/2);
  const point = (x,y)=>({x:x*scale,y:y*scale});
  return {viewport:{width,height}, scale,
    diplomacy:point(102,217), firstAction:point(x+12+80,y+44+46+14),
    close:point(x+panelWidth-46,y+20),
    feed:{x:12*scale,y:238*scale,width:440*scale,height:80*scale},
    panel:{x:x*scale,y:y*scale,width:panelWidth*scale,height:panelHeight*scale}};
}

function authoritativeReceipt(peer, owner, command) {
  const receipts = peer.messages.filter(m=>m.direction==='in' && m.kind==='TickPacket' && m.match===command.match)
    .flatMap(m=>m.commands.filter(c=>c.participant===owner && c.seat===command.seat && c.sequence===command.sequence)
      .map(c=>({match:m.match,tick:m.tick,...c})));
  for (const receipt of receipts) assert.equal(receipt.payload,command.payload,'authoritative bytes differ from human submission');
  // Catchup can repeat a packet; a command may not move to another tick.
  if (receipts.length) assert.ok(receipts.every(r=>r.tick===receipts[0].tick),'command applied at multiple ticks');
  return receipts[0];
}

async function runSocial({peers,report,wait,click,shot,last,step}) {
  const [host,guest] = peers;
  const startOffsets = peers.map(p=>p.messages.length);
  const coordinates = socialLayout();
  const social = report.social = {coordinates,events:[],passed:false,
    visualEvidence:'PNG feed/panel captures; labels and rendered glyphs require image review, not OCR assertions'};
  step('Social coordinates (CSS pixels; fresh Auto HUD, deviceScaleFactor=1): '+JSON.stringify(coordinates));
  for (const peer of peers) {
    const state = last(peer,'RoomState');
    assert.equal(state.seats.length,2,'social acceptance must contain only the two humans');
    state.seats.forEach((seat,index)=>{
      assert.equal(seat.name,'Human','bots are not social senders');
      assert.equal(seat.owner,last(peers[index],'Welcome').participant);
      assert.equal(state.participants.find(p=>p.id===seat.owner)?.name,'QA '+peers[index].role);
    });
  }
  async function afterCommand(peer,command,label) {
    const owner = last(peer,'Welcome').participant;
    await wait(label+' identical authoritative payload on both peers',()=>peers.every(p=>authoritativeReceipt(p,owner,command)),15000);
    const receipts = peers.map(p=>authoritativeReceipt(p,owner,command));
    assert.equal(receipts[0].tick,receipts[1].tick,'authoritative command tick must agree');
    const tick = receipts[0].tick;
    await wait(label+' applied by both browsers',async()=>{
      const applied = await Promise.all(peers.map(p=>p.page.evaluate(()=>window.__lvdFrames.at(-1)?.tick || 0)));
      return applied.every(t=>t>=tick);
    },15000);
    let checkpoint;
    await wait(label+' matching post-action hashes',()=>{
      const hs=host.messages.filter(m=>m.direction==='out'&&m.kind==='ReportHash'&&m.match===command.match&&m.tick>tick);
      const gs=guest.messages.filter(m=>m.direction==='out'&&m.kind==='ReportHash'&&m.match===command.match&&m.tick>tick);
      for(const h of hs){const g=gs.find(g=>g.tick===h.tick);if(g){assert.equal(h.hash,g.hash,label+' hash disagreement');checkpoint={match:h.match,tick:h.tick,hash:h.hash};}}
      return checkpoint;
    },20000);
    const event={label,sender:peer.role,participant:owner,seat:command.seat,sequence:command.sequence,
      payload:command.payload,...decodePayload(command.payload),authoritativeTick:tick,checkpoint};
    social.events.push(event);
    step(label+': identical authoritative bytes on both peers at tick '+tick+'; shared hash at '+checkpoint.tick);
    return event;
  }
  async function submitted(peer,offset,label) {
    await wait(label+' SubmitCommand',()=>peer.messages.slice(offset).some(m=>m.direction==='out'&&m.kind==='SubmitCommand'));
    const sent=peer.messages.slice(offset).filter(m=>m.direction==='out'&&m.kind==='SubmitCommand');
    // Retransmission of one sequence is fine; extra gameplay commands are not.
    assert.equal(new Set(sent.map(m=>m.sequence)).size,1,label+' must submit only one human command');
    const command=sent[0];
    assert.equal(command.seat,peers.indexOf(peer));
    assert.equal(command.match,last(peer,'BeginMatch').match);
    return command;
  }
  for(const peer of peers) {
    const message='hello from QA '+peer.role;
    await peer.page.bringToFront();
    await peer.page.mouse.move(757,650); // Stay away from edge scrolling and UI.
    const offset=peer.messages.length;
    await peer.page.keyboard.press('Enter',{delay:140});
    await peer.page.waitForTimeout(150);
    await peer.page.keyboard.type(message,{delay:70});
    await shot(peer,'chat-draft');
    await peer.page.keyboard.press('Enter',{delay:140});
    const command=await submitted(peer,offset,peer.role+' chat');
    assert.deepEqual(command.chat,{sender:peers.indexOf(peer),target:-2,text:message},'exact binary Chat sender/broadcast/text');
    await afterCommand(peer,command,peer.role+' chat');
    for(const viewer of peers) await shot(viewer,'chat-from-'+peer.role);
  }
  for(const peer of peers) {
    await click(peer.page,coordinates.diplomacy.x,coordinates.diplomacy.y);
    await shot(peer,'diplomacy-at-war');
  }
  async function action(peer,opcode,offerId,label) {
    const offset=peer.messages.length;
    await click(peer.page,coordinates.firstAction.x,coordinates.firstAction.y);
    const command=await submitted(peer,offset,label);
    assert.ok(command.action,label+' requires a ReplayAction, not chat');
    assert.equal(command.action[0],9,'ActionDiplomacy');
    assert.equal(command.action[1],peers.indexOf(peer),'diplomacy player');
    assert.equal(command.action[3],1-peers.indexOf(peer),'diplomacy other human');
    assert.equal(command.action[4],opcode,'diplomacy enum');
    assert.equal(command.action[5],offerId,'exact current offer ID (not stale/guessed UI acceptance)');
    await afterCommand(peer,command,label);
    for(const viewer of peers) await shot(viewer,label);
  }
  // Exactly two humans, no prior diplomacy: nextOfferId starts at 1. No bots or
  // direct commands can consume IDs. The UI must supply the matching ID itself.
  await action(host,2,0,'peace-offered');
  await action(guest,4,1,'peace-accepted');
  // The original sender still has its resend cooldown. The peace RECIPIENT
  // proposes alliance instead, exercising the other direction without waiting.
  await action(guest,3,0,'alliance-offered');
  await action(host,4,2,'alliance-accepted');
  for(const peer of peers) {
    await click(peer.page,coordinates.close.x,coordinates.close.y);
    await shot(peer,'social-complete-feed');
  }
  assert.equal(social.events.length,6,'two chats plus offer/accept peace and alliance');
  for(const [index,peer] of peers.entries()) {
    const actual = new Set(peer.messages.slice(startOffsets[index])
      .filter(m=>m.direction==='out'&&m.kind==='SubmitCommand').map(m=>m.sequence));
    const expected = new Set(social.events.filter(e=>e.sender===peer.role).map(e=>e.sequence));
    assert.deepEqual(actual,expected,peer.role+': typing/panel clicks must not leak extra gameplay submissions');
  }
  social.passed=true;
}

module.exports = {decodePayload,socialLayout,authoritativeReceipt,runSocial};
