import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {MemoryStore} from './store.mjs';
import {planRecall} from './recall.mjs';
import {seed} from '../../benchmarks/recall/seed.mjs';
const reference={reference_time:'2026-10-25T18:00:00+08:00',time_zone:'Asia/Shanghai'};
function fixture(){const root=mkdtempSync(join(tmpdir(),'event-recall-'));seed(root);const store=new MemoryStore(root);return {store,close(){store.close();rmSync(root,{recursive:true,force:true})}}}
test('relative local dates account for DST and explicit zone; bad intervals fail',()=>{
 const p=planRecall({query:'今天早上',reference_time:'2026-11-01T20:00:00Z',time_zone:'America/New_York'});
 assert.equal(p.time_window.from,'2026-11-01T11:00:00.000Z');
 assert.equal(p.time_window.to,'2026-11-01T17:00:00.000Z');
 assert.throws(()=>planRecall({query:'今天',reference_time:'not a date'}),/reference_time/);
 const f=fixture();try{assert.throws(()=>f.store.recall({query:'原型',from:'2026-10-25',to:'2026-10-24'}),/interval/)}finally{f.close()}
});
test('nearby page is a clue, not invented speech; deleted and hidden sources stay absent',()=>{
 const f=fixture();try{
  const result=f.store.recall({query:'今天早上青禾压测方案的录音',...reference});
  assert.equal(result.candidates[0].session_id,'event-anchor');
  assert.equal(result.candidates[0].matched.speaker_identity_confirmed,false);
  const bundle=f.store.bundle({segment_id:'event-anchor'});
  assert.equal(bundle.events[0].event_id,'doc-anchor');
  assert.ok(!bundle.recordings[0].transcript.utterances[0].text.includes('青禾'));
  assert.equal(f.store.recall({query:'绝密火星',...reference}).status,'not_found');
 }finally{f.close()}
});
test('neighbor cancellation wins; proposed work and unknown owner are not invented commitments',()=>{
 const f=fixture();try{
  const cancelled=f.store.bundle({segment_id:'cancel-a'}).handoff;
  assert.equal(cancelled.committed.length,0);assert.equal(cancelled.cancelled.length,1);
  assert.equal(cancelled.execution_performed,false);
  const proposal=f.store.bundle({segment_id:'proposal'}).handoff;
  assert.equal(proposal.proposed[0].owner,null);assert.equal(proposal.proposed[0].due_at,null);assert.equal(proposal.committed.length,0);
  assert.ok(proposal.proposed[0].citations[0].quote);
  assert.equal(f.store.bundle({segment_id:'injection'}).untrusted_data,true);
 }finally{f.close()}
});
test('out-of-band forged evidence is rejected and stale hashes never become a handoff',()=>{
 const f=fixture();try{
  const a=f.store.db.prepare("SELECT payload_json FROM analyses WHERE segment_id='proposal'").get();
  const payload=JSON.parse(a.payload_json);payload.claims[0].quote='已经交付全部系统';
  f.store.db.prepare("UPDATE analyses SET payload_json=? WHERE segment_id='proposal'").run(JSON.stringify(payload));
  assert.equal(f.store.bundle({segment_id:'proposal'}).handoff.proposed.length,0);
  f.store.db.prepare("UPDATE segments SET sha256=? WHERE id='proposal'").run('0'.repeat(64));
  assert.throws(()=>f.store.bundle({segment_id:'proposal'}),/changed/);
 }finally{f.close()}
});

test('host reasoning can supply semantic alternatives without embedding an agent runtime',()=>{
 const f=fixture();try {
  const args={query:'今天早上跟小李谈的支持断网还能用的方案',...reference};
  assert.notEqual(f.store.recall(args).candidates[0]?.session_id,'remote');
  assert.equal(f.store.recall({...args,query_expansions:['离线缓存']}).candidates[0].session_id,'remote');
  assert.equal(f.store.recall({query:'今早工位跟小陈说的事',...reference}).candidates[0].session_id,'design');
 }finally{f.close()}
});

test('event evidence is paginated, hidden-aware and verifies the shared native content hash',()=>{
 const f=fixture();try {
  const event=f.store.event({event_id:'doc-anchor',offset:0,limit:2});
  assert.equal(event.text.length,2);assert.equal(event.next_offset,2);
  assert.throws(()=>f.store.event({event_id:'hidden-web'}),/hidden/);
  f.store.db.prepare("UPDATE context_events SET text='changed' WHERE id='doc-anchor'").run();
  assert.throws(()=>f.store.event({event_id:'doc-anchor'}),/changed/);
 }finally{f.close()}
});

test('one continuous all-day capture session does not merge separate conversations through irrelevant intervening audio',()=>{
 const f=fixture();try {
  f.store.db.prepare("UPDATE segments SET session_id='all-day' WHERE id IN ('ambiguous-a','ambiguous-b')").run();
  for(let i=0;i<180;i++) {
   const start=Date.parse('2026-10-25T08:41:00+08:00')+i*60000;
   f.store.db.prepare("UPDATE segments SET session_id='all-day',started_ms=?,ended_ms=? WHERE id=?").run(start,start+60000,'noise-'+i);
  }
  const result=f.store.recall({query:'今天早上工位和小周说的事',...reference});
  assert.equal(result.status,'needs_clarification');
  assert.equal(new Set(result.candidates.map(x=>x.episode_id)).size,2);
 }finally{f.close()}
});
