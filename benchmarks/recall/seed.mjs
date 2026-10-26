import {mkdirSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {eventDigest} from '../../plugins/agentone-memory/recall.mjs';
import {MemoryStore} from '../../plugins/agentone-memory/store.mjs';
import {recordings,events} from './fixtures.mjs';

export function seed(root) {
 const store=new MemoryStore(root);mkdirSync(join(root,'Audio'),{recursive:true});
 for(const row of recordings) {
  const bytes=Buffer.from('SYNTHETIC RETRIEVAL PAYLOAD, NOT SPEECH: '+row.id),sha=createHash('sha256').update(bytes).digest('hex'),at=Date.parse(row.at);
  writeFileSync(join(root,'Audio',row.id+'.fixture'),bytes);
  store.db.prepare('INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(row.id,row.session,row.source??'microphone',at,at+60000,row.time_zone??'Asia/Shanghai',1,1,'host_clock',48000,1,`Audio/${row.id}.fixture`,sha,row.deleted?'deleted':'sealed',row.place??null,'{"synthetic":true}',at);
  if(row.text!==null) {
   store.db.prepare('INSERT INTO transcripts VALUES (?,?,?,?,?,?,?)').run(row.id,1,row.text,JSON.stringify([{start_ms:0,end_ms:55000,text:row.text,speaker_local_id:null}]),'succeeded','curated-synthetic-transcript',at);
   const claims=(row.claims??[]).map(x=>({...x,kind:'task_candidate',start_ms:0,end_ms:55000,certainty:'observed_statement',owner:x.owner??null,due_at:null,segment_id:row.id,source_sha256:sha,transcript_revision:1}));
   store.db.prepare('INSERT INTO analyses VALUES (?,?,?,?,?)').run(row.id,1,1,JSON.stringify({summary:row.text,tags:row.tags,claims}),at);
  }
 }
 const eventTable=store.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='context_events'").get();
 if(eventTable) for(const e of events) store.db.prepare(`INSERT INTO context_events(id,started_ms,ended_ms,kind,application,title,url,text,place,provenance,source_ref,source_sha256,hidden,created_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(e.id,Date.parse(e.at),Date.parse(e.end??e.at),'window_context',e.application,e.title,e.url??null,e.text,e.place??null,e.legacy?'legacy_diary':'native_event','synthetic://'+e.id,eventDigest({id:e.id,started_ms:Date.parse(e.at),ended_ms:Date.parse(e.end??e.at),kind:'window_context',application:e.application,title:e.title,url:e.url??null,text:e.text,place:e.place??null,provenance:e.legacy?'legacy_diary':'native_event',source_ref:'synthetic://'+e.id}),e.hidden?1:0,Date.parse(e.at));
 // Distractors share generic words but not the discriminating topics/people.
 for(let i=0;i<240;i++) {
  const at=Date.parse('2026-10-01T00:00:00Z')+i*7200000,id='noise-'+i;
  store.db.prepare('INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(id,'noise-session-'+i,'system_audio',at,at+60000,'Asia/Shanghai',1,1,'host_clock',48000,2,`Audio/noise.fixture`,'0'.repeat(64),'sealed',i%2?'工位':'会议室','{"synthetic":true}',at);
  store.db.prepare('INSERT INTO transcripts VALUES (?,?,?,?,?,?,?)').run(id,1,'今天讨论普通日常安排和测试录音。','[]','succeeded','synthetic-distractor',at);
 }
 store.close();
}
