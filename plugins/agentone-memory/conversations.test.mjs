import test from 'node:test';import assert from 'node:assert/strict';import {mkdtempSync,mkdirSync,writeFileSync,rmSync}from'node:fs';import{tmpdir}from'node:os';import{join}from'node:path';import{createHash}from'node:crypto';
import{MemoryStore}from'./store.mjs';import{ConversationStore}from'./conversations.mjs';
function fixture(){
 const root=mkdtempSync(join(tmpdir(),'agentone-conversation-test-'));const store=new MemoryStore(root),api=new ConversationStore(store);mkdirSync(join(root,'Audio'));
 const bytes=Buffer.from('Synthetic source bytes, not human speech'),sha=createHash('sha256').update(bytes).digest('hex'),base=Date.now()-600000;
 for(const[id,offset,text]of[['first',0,'先讨论需求，再评估方案。'],['second',60000,'只是提议，下周再确认是否执行。']]){
  writeFileSync(join(root,'Audio',id+'.m4a'),bytes);store.db.prepare('INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(id,'fixture','mixed',base+offset,base+offset+60000,'UTC',0,0,'synthetic',48000,2,'Audio/'+id+'.m4a',sha,'sealed',null,'{}',base);
  store.db.prepare('INSERT INTO transcripts VALUES (?,?,?,?,?,?,?)').run(id,1,text,JSON.stringify([{start_ms:0,end_ms:20000,text}]),'succeeded','synthetic-not-ASR',base);
 }
 const id='conversation-first',digest=createHash('sha256').update([String(base),String(base+120000),'ended','first:'+sha+':1','second:'+sha+':1'].join('\n')).digest('hex');
 store.db.prepare('INSERT INTO conversations VALUES (?,?,?,?,?,?,?,?,?,?,?,?)').run(id,base,base+120000,base+80000,'ended',digest,'转写片语','[0:00] 先讨论需求，再评估方案。\n[1:00] 只是提议，下周再确认是否执行。',2,0,0,base);
 for(const[s,ordinal]of[['first',0],['second',1]])store.db.prepare('INSERT INTO conversation_segments VALUES (?,?,?,?,?)').run(id,s,sha,1,ordinal);
 return{store,api,root,id,close(){store.close();rmSync(root,{recursive:true,force:true})}};
}
test('whole discussion evidence paginates across chunks and keeps original transcript wording',()=>{
 const f=fixture();try{assert.equal(f.api.list().total,1);assert.equal(f.api.list().conversations[0].state,'ended');const first=f.api.evidence({conversation_id:f.id,limit:1});assert.equal(first.next_offset,1);assert.equal(first.total_segments,2);assert.equal(first.recordings[0].conversation_offset_ms,0);const second=f.api.evidence({conversation_id:f.id,offset:1,limit:1});assert.equal(second.recordings[0].conversation_offset_ms,60000);assert.equal(second.next_offset,null);assert.match(second.recordings[0].transcript.utterances[0].text,/只是提议/);}finally{f.close()}
});
test('deleted or revised sources cannot serve an obsolete whole discussion',()=>{
 const f=fixture();try{f.store.db.prepare('UPDATE transcripts SET revision=2 WHERE segment_id=?').run('second');assert.throws(()=>f.api.evidence({conversation_id:f.id}),/sources changed/);assert.equal(f.api.list().total,0);f.store.db.prepare('UPDATE transcripts SET revision=1 WHERE segment_id=?').run('second');f.store.db.prepare("UPDATE segments SET state='deleted' WHERE id='second'").run();assert.equal(f.api.list().total,0);}finally{f.close()}
});
test('whole discussion search tolerates ASR spaces between Chinese words',()=>{
 const f=fixture();try{f.store.db.prepare('UPDATE conversations SET transcript_text=? WHERE id=?').run('每个人 都有 自己的 数字 员工',f.id);assert.equal(f.api.list({query:'数字员工'}).total,1);assert.equal(f.api.list({query:'不存在的内容'}).total,0);}finally{f.close()}
});
test('changed physical audio is rejected and no product summary queue is installed',()=>{
 const f=fixture();try{writeFileSync(join(f.root,'Audio/first.m4a'),'changed');assert.throws(()=>f.api.evidence({conversation_id:f.id}),/changed/);assert.equal(f.store.db.prepare("SELECT count(*) n FROM sqlite_master WHERE type='table' AND name IN ('conversation_jobs','conversation_summaries')").get().n,0);}finally{f.close()}
});
