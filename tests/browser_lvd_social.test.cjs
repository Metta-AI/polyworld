'use strict';
// Offline harness contract checks, NOT multiplayer or rendered acceptance evidence.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {decodePayload,socialLayout,authoritativeReceipt}=require('./browser_lvd_social.cjs');
function chat(sender,text){
  const body=Buffer.from(text,'utf8'),b=Buffer.alloc(16+body.length);
  b.writeInt32LE(sender,4);b.writeInt32LE(-2,8);b.writeUInt32LE(body.length,12);body.copy(b,16);return b;
}
test('Chat uses byte-counted UTF-8, not int32 action decoding',()=>{
  for(const text of ['hello from QA host','hello from QA guest','hello é 🐦']){
    const b=chat(1,text);
    assert.deepEqual(decodePayload(b),{payload:b.toString('hex'),chat:{sender:1,target:-2,text}});
  }
});
test('reject truncated, oversized, trailing and invalid UTF-8 Chat',()=>{
  const b=chat(0,'x');
  assert.throws(()=>decodePayload(b.subarray(0,15)));
  assert.throws(()=>decodePayload(b.subarray(0,16)));
  assert.throws(()=>decodePayload(Buffer.concat([b,Buffer.from([0])])));
  assert.throws(()=>decodePayload(chat(0,'x'.repeat(1025))));
  b[16]=255;assert.throws(()=>decodePayload(b));
});
test('move and diplomacy retain the nine signed action fields',()=>{
  for(const a of [[1,0,1000000000,16,28,0,0,0,0],[9,1,-1,0,4,1,0,0,0]]){
    const b=Buffer.alloc(36);a.forEach((n,i)=>b.writeInt32LE(n,i*4));
    assert.deepEqual(decodePayload(b).action,a);
    assert.throws(()=>decodePayload(b.subarray(0,35)));
  }
});
test('receipt requires matching match, participant, seat, sequence and exact bytes',()=>{
  const c={match:3,seat:0,sequence:'7',payload:chat(0,'hello').toString('hex')};
  const packet={direction:'in',kind:'TickPacket',match:3,tick:80,commands:[{participant:42,seat:0,sequence:'7',payload:c.payload}]};
  assert.equal(authoritativeReceipt({messages:[packet]},42,c).tick,80);
  for(const bad of [{match:4},{seat:1},{sequence:'8'}]) assert.equal(authoritativeReceipt({messages:[packet]},42,{...c,...bad}),undefined);
  assert.equal(authoritativeReceipt({messages:[packet]},99,c),undefined);
  assert.throws(()=>authoritativeReceipt({messages:[packet]},42,{...c,payload:'00'}));
  assert.equal(authoritativeReceipt({messages:[packet,packet]},42,c).tick,80);
  assert.throws(()=>authoritativeReceipt({messages:[packet,{...packet,tick:81}]},42,c));
});
test('fixed fresh Auto-HUD coordinates use layout space times 0.5',()=>{
  const p=socialLayout();
  assert.deepEqual(p.diplomacy,{x:51,y:108.5});
  assert.deepEqual(p.firstAction,{x:638,y:374});
  assert.deepEqual(p.close,{x:899,y:332});
  assert.deepEqual(p.panel,{x:592,y:322,width:330,height:326});
});
