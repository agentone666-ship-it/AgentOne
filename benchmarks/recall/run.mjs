import {mkdtempSync,mkdirSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {MemoryStore} from '../../plugins/agentone-memory/store.mjs';
import {MCPClient} from '../../scripts/mcp_client.mjs';
import {reference,recordings,events,cases} from './fixtures.mjs';

export function seed(root) {
 const store=new MemoryStore(root);mkdirSync(join(root,'Audio'),{recursive:true});
 for(const row of recordings) {
  const bytes=Buffer.from('SYNTHETIC RETRIEVAL PAYLOAD, NOT SPEECH: '+row.id),sha=createHash('sha256').update(bytes).digest('hex'),at=Date.parse(row.at);
  writeFileSync(join(root,'Audio',row.id+'.fixture'),bytes);
  store.db.prepare('INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(row.id,row.session,row.source??'microphone',at,at+60000,'Asia/Shanghai',1,1,'host_clock',48000,1,`Audio/${row.id}.fixture`,sha,row.deleted?'deleted':'sealed',row.place??null,'{"synthetic":true}',at);
  if(row.text!==null) {
   store.db.prepare('INSERT INTO transcripts VALUES (?,?,?,?,?,?,?)').run(row.id,1,row.text,JSON.stringify([{start_ms:0,end_ms:55000,text:row.text,speaker_local_id:null}]),'succeeded','curated-synthetic-transcript',at);
   const claims=(row.claims??[]).map(x=>({...x,kind:'task_candidate',start_ms:0,end_ms:55000,certainty:'observed_statement',owner:x.owner??null,due_at:null,segment_id:row.id,source_sha256:sha,transcript_revision:1}));
   store.db.prepare('INSERT INTO analyses VALUES (?,?,?,?,?)').run(row.id,1,1,JSON.stringify({summary:row.text,tags:row.tags,claims}),at);
  }
 }
 const eventTable=store.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='context_events'").get();
 if(eventTable) for(const e of events) store.db.prepare(`INSERT INTO context_events(id,started_ms,ended_ms,kind,application,title,url,text,place,provenance,source_ref,source_sha256,hidden,created_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(e.id,Date.parse(e.at),Date.parse(e.end??e.at),'window_context',e.application,e.title,e.url??null,e.text,e.place??null,e.legacy?'legacy_diary':'native_event','synthetic://'+e.id,createHash('sha256').update(e.text).digest('hex'),e.hidden?1:0,Date.parse(e.at));
 // Distractors share generic words but not the discriminating topics/people.
 for(let i=0;i<240;i++) {
  const at=Date.parse('2026-10-01T00:00:00Z')+i*7200000,id='noise-'+i;
  store.db.prepare('INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(id,'noise-session-'+i,'system_audio',at,at+60000,'Asia/Shanghai',1,1,'host_clock',48000,2,`Audio/noise.fixture`,'0'.repeat(64),'sealed',i%2?'工位':'会议室','{"synthetic":true}',at);
  store.db.prepare('INSERT INTO transcripts VALUES (?,?,?,?,?,?,?)').run(id,1,'今天讨论普通日常安排和测试录音。','[]','succeeded','synthetic-distractor',at);
 }
 store.close();
}

const mode=process.argv.includes('--baseline')?'baseline':'candidate';
const outFlag=process.argv.indexOf('--output'),out=outFlag>=0?resolve(process.argv[outFlag+1]):null;
const root=mkdtempSync(join(tmpdir(),'agentone-recall-benchmark-'));seed(root);
const client=new MCPClient(resolve('plugins/agentone-memory/server.mjs'),root);
const rows=[];
try {
 await client.initialize();
 for(const c of cases) {
  const start=performance.now();let result;
  if(mode==='baseline') {
   const r=await client.call('search_memory',{query:c.query,limit:5});
   result={candidates:r.results.map(x=>({session_id:x.session_id,segment_id:x.segment_id})),status:r.results.length?'found':'not_found',events:[]};
  } else result=await client.call('recall_context',{query:c.query,...reference,...Object.fromEntries(['time_zone','reference_time'].filter(k=>c[k]).map(k=>[k,c[k]])),limit:5});
  const sessions=[...new Set((result.candidates??[]).map(x=>x.session_id))];
  let bundle=null;
  if(mode!=='baseline'&&sessions.length&&c.sessions.includes(sessions[0])) bundle=await client.call('get_context_bundle',{segment_id:result.candidates[0].segment_id});
  const hit=c.sessions.length?c.sessions.includes(sessions[0]):sessions.length===0;
  const recall=c.sessions.length?c.sessions.filter(x=>sessions.includes(x)).length/c.sessions.length:1;
  const eventHit=!c.event||[...(result.events??[]),...(bundle?.events??[])].some(x=>x.event_id===c.event);
  const handoff=bundle?.handoff;
  const actionPass=(!c.task||handoff?.committed.some(x=>x.text===c.task))&&(!c.cancelled||handoff?.cancelled.some(x=>x.text===c.cancelled)&&!handoff?.committed.some(x=>x.text===c.cancelled))&&(!c.proposal||handoff?.proposed.some(x=>x.text===c.proposal)&&!handoff?.committed.some(x=>x.text===c.proposal));
  const statusPass=result.status===c.status;
  rows.push({id:c.id,split:c.split,expected_status:c.status,status:result.status,status_pass:statusPass,expected_audio:c.sessions.length>0,needs_event:!!c.event,needs_action:!!(c.task||c.cancelled||c.proposal),top1:hit,recall_at_5:recall,event_link:eventHit,action_contract:!!actionPass,pass:hit&&recall===1&&statusPass&&eventHit&&actionPass,latency_ms:Math.round((performance.now()-start)*100)/100,sessions});
 }
 const rate=(rs,key)=>rs.length ? rs.filter(x=>x[key]).length+'/'+rs.length : 'n/a';
 const rates=rs=>({positive_top1:rate(rs.filter(x=>x.expected_audio),'top1'),positive_recall_at_5:rs.filter(x=>x.expected_audio).reduce((sum,x)=>sum+x.recall_at_5,0)/Math.max(1,rs.filter(x=>x.expected_audio).length),status_accuracy:rate(rs,'status_pass'),scenario_pass:rate(rs,'pass'),event_link:rate(rs.filter(x=>x.needs_event),'event_link'),action_contract:rate(rs.filter(x=>x.needs_action),'action_contract')});
 const latencies=rows.map(x=>x.latency_ms).sort((a,b)=>a-b);
 const report={benchmark:'agentone-recall-v1',mode,scope:'Synthetic transcript retrieval + evidence/handoff contracts through a real MCP subprocess. Not ASR, speech quality, LLM reasoning or real-world execution.',recordings:recordings.length+240,cases:rows.length,metrics:rates(rows),dev:rates(rows.filter(x=>x.split==='dev')),transfer:rates(rows.filter(x=>x.split==='transfer')),latency_p95_ms:latencies[Math.ceil(latencies.length*.95)-1],rows};
 if(out) writeFileSync(out,JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({...report,rows:undefined},null,2));
 if(mode==='candidate'&&process.argv.includes('--check')&&rows.some(x=>!x.pass)) process.exitCode=1;
} finally {await client.close();rmSync(root,{recursive:true,force:true})}
