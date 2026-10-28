import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import { mkdtempSync,mkdirSync,readFileSync,writeFileSync,rmSync,symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { MemoryStore } from './store.mjs';
import { MCPClient } from '../../scripts/mcp_client.mjs';

function fixture() {
  const root=mkdtempSync(join(tmpdir(),'agentone-mcp-test-'));
  const store=new MemoryStore(root);
  const bytes=Buffer.from('SYNTHETIC AUDIO BYTES; NOT A REAL RECORDING');
  mkdirSync(join(root,'Audio'));
  const sha=createHash('sha256').update(bytes).digest('hex');
  for(const [id,time,place] of [['old-segment',Date.parse('2026-01-20T16:00:00Z'),'旧工位'],['new-segment',Date.parse('2026-10-25T16:00:00Z'),'工位']]) {
    writeFileSync(join(root,'Audio',id+'.m4a'),bytes);
    store.db.prepare('INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(id,'fixture-session','microphone',time,time+60_000,'America/Los_Angeles',1,1,'host_clock',48_000,1,`Audio/${id}.m4a`,sha,'sealed',place,'{"synthetic":true}',time);
    store.db.prepare("INSERT INTO jobs (id,segment_id,stage,source_hash,state,created_ms,updated_ms) VALUES (?,?,'transcribe',?,'pending',?,?)").run(id+'-job',id,sha,time,time);
  }
  return {root,store,sha,close(){store.close();rmSync(root,{recursive:true,force:true})}};
}
function transcription(text='先制作原型，再讨论交付。') {
  return {transcription:{text,engine:'synthetic-test-host',status:'succeeded',utterances:[{start_ms:10_000,end_ms:20_000,text,speaker_local_id:null}]}};
}
function analyze() {
  return {analysis:{summary:'讨论原型',tags:['产品讨论','原型'],claims:[{kind:'task_candidate',text:'制作原型',quote:'先制作原型',start_ms:10_000,end_ms:20_000,certainty:'observed_statement',owner:null,due_at:null,action_state:'proposed'}]}};
}
function submit(store,job,result) {return store.submit({job_id:job.job_id,lease_token:job.lease_token,source_sha256:job.source_sha256,result})}

test('leases are atomic across two processes/connections; stale and expired results cannot write',()=>{
  const f=fixture();const other=new MemoryStore(f.root);
  try {
    const first=f.store.claim({owner:'host-A',stage:'transcribe',limit:1}).jobs[0];
    const second=other.claim({owner:'host-B',stage:'transcribe',limit:3}).jobs;
    assert.equal(second.length,1);assert.notEqual(second[0].segment_id,first.segment_id);
    assert.throws(()=>f.store.submit({job_id:first.job_id,lease_token:'wrong',source_sha256:f.sha,result:transcription()}),/Lease/);
    f.store.db.prepare('UPDATE jobs SET lease_until_ms=0 WHERE id=?').run(first.job_id);
    assert.throws(()=>submit(f.store,first,transcription()),/Lease/);
    const retried=other.claim({owner:'host-B',stage:'transcribe',limit:1}).jobs[0];
    assert.notEqual(retried.lease_token,first.lease_token);
    submit(other,retried,transcription());
    assert.throws(()=>submit(f.store,first,transcription()),/Lease/);
  } finally {other.close();f.close()}
});

test('transcription to sourced labeling is durable, idempotent and searchable across months',()=>{
  const f=fixture();
  try {
    for(const job of f.store.claim({owner:'host',stage:'transcribe',limit:3}).jobs) {
      assert.equal(submit(f.store,job,transcription()).accepted,true);
      assert.equal(submit(f.store,job,transcription()).idempotent,true);
    }
    for(const job of f.store.claim({owner:'host',stage:'analyze',limit:3}).jobs) submit(f.store,job,analyze());
    const all=f.store.search({query:'原型',place_hint:'工位'});
    assert.equal(all.total_matches,2);
    assert.equal(f.store.search({query:'不存在的说法',query_expansions:['制作 原型']}).total_matches,2);
    assert.equal(f.store.search({query:'原型',from:'2026-01-01T00:00:00Z',to:'2026-02-01T00:00:00Z'}).total_matches,1);
    assert.equal(f.store.search({query:'原型',place_filter:'旧工位'}).total_matches,1);
    const evidence=f.store.evidence({segment_id:'old-segment',start_ms:9000,end_ms:21000});
    assert.equal(evidence.transcript.utterances.length,1);
    assert.equal(evidence.analyses[0].claims[0].owner,null);
    assert.equal(evidence.analyses[0].claims[0].source_sha256,f.sha);
    assert.throws(()=>f.store.evidence({segment_id:'old-segment',end_ms:90000}),/outside/);
  } finally {f.close()}
});

test('unsupported quotes, forged offsets and changed audio never become long-term facts',()=>{
  const f=fixture();
  try {
    const job=f.store.claim({owner:'host',stage:'transcribe',limit:1}).jobs[0];
    submit(f.store,job,transcription());
    const analysisJob=f.store.claim({owner:'host',stage:'analyze',limit:1}).jobs[0];
    const forged=analyze();forged.analysis.claims[0].quote='已经发送邮件';
    assert.throws(()=>submit(f.store,analysisJob,forged),/not supported/);
    const wrongTime=analyze();wrongTime.analysis.claims[0].start_ms=30000;wrongTime.analysis.claims[0].end_ms=40000;
    assert.throws(()=>submit(f.store,analysisJob,wrongTime),/not supported/);
    writeFileSync(join(f.root,'Audio',job.segment_id+'.m4a'),'changed');
    assert.throws(()=>submit(f.store,analysisJob,analyze()),/changed/);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) n FROM analyses').get().n,0);
  } finally {f.close()}
});

test('raw export requires an explicit native setting and rejects path/symlink escapes',()=>{
  const f=fixture();
  try {
    assert.throws(()=>f.store.audio('old-segment'),/disabled/);
    f.store.db.prepare("INSERT INTO meta VALUES ('allow_audio_export','1')").run();
    assert.ok(f.store.audio('old-segment').blob);
    writeFileSync(join(f.root,'outside'),'not an audio source');
    symlinkSync(join(f.root,'outside'),join(f.root,'Audio','escape.m4a'));
    f.store.db.prepare("UPDATE segments SET relative_path='Audio/escape.m4a' WHERE id='old-segment'").run();
    assert.throws(()=>f.store.audio('old-segment'),/escapes/);
  } finally {f.close()}
});

test('deleted sources disappear and cannot be resurrected by an in-flight worker',()=>{
  const f=fixture();
  try {
    const job=f.store.claim({owner:'host',stage:'transcribe',limit:1}).jobs[0];
    f.store.db.prepare("UPDATE segments SET state='deleted' WHERE id=?").run(job.segment_id);
    assert.throws(()=>submit(f.store,job,transcription()),/deleted/);
    assert.throws(()=>f.store.evidence({segment_id:job.segment_id}),/deleted/);
    assert.equal(f.store.search({}).total_matches,1);
  } finally {f.close()}
});

test('capture heartbeat freshness distinguishes stopped capture from a live recorder',()=>{
  const f=fixture();
  try {
    assert.equal(f.store.status().capture.state,'not_started');
    f.store.db.prepare("INSERT INTO capture_state VALUES (1,'recording','fixture',0)").run();
    assert.equal(f.store.status().capture.state,'offline');
    f.store.db.prepare('UPDATE capture_state SET heartbeat_ms=?').run(Date.now());
    assert.equal(f.store.status().capture.state,'recording');
    f.store.db.prepare("UPDATE capture_state SET state='listening',heartbeat_ms=0").run();
    assert.equal(f.store.status().capture.state,'offline');
    f.store.db.prepare('UPDATE capture_state SET heartbeat_ms=?').run(Date.now());
    assert.equal(f.store.status().capture.state,'listening');
  } finally {f.close()}
});

test('durable consolidations retain evidence, supersession and separate validity/learning time',()=>{
  const f=fixture();
  try {
    for(const job of f.store.claim({owner:'host',stage:'transcribe',limit:3}).jobs) submit(f.store,job,transcription());
    const base={kind:'project_summary',title:'记忆插件改版',text:'先制作原型再决定交付。',entities:['AgentOne','原型'],epistemic_status:'supported_summary',valid_from:'2026-01-20T16:00:00Z',valid_until:null,supersedes:[],
      evidence:[{segment_id:'old-segment',source_sha256:f.sha,transcript_revision:1,start_ms:10000,end_ms:20000,quote:'先制作原型'}]};
    const original=f.store.retain(base);
    assert.equal(f.store.retain({...base,title:base.title}).idempotent,true);
    const revised=f.store.retain({...base,text:'新的理解：两个时期都提到了原型，应保留各自的来源。',valid_from:'2026-10-25T16:00:00Z',supersedes:[original.memory_id],evidence:[...base.evidence,{...base.evidence[0],segment_id:'new-segment'}]});
    const current=f.store.search({query:'记忆插件'});
    assert.equal(current.long_term_matches,1);
    assert.equal(current.memories[0].memory_id,revised.memory_id);
    assert.equal(current.memories[0].evidence.length,2);
    assert.notEqual(current.memories[0].learned_at,current.memories[0].valid_from);
    assert.equal(f.store.search({query:'记忆插件',include_superseded:true}).long_term_matches,2);
    assert.equal(f.store.search({query:'不相干',query_expansions:['原型']}).long_term_matches,1);
    const fabricated=structuredClone(base);fabricated.evidence[0].quote='已发邮件';
    assert.throws(()=>f.store.retain(fabricated),/unsupported/);
    f.store.db.prepare("UPDATE segments SET state='deleted' WHERE id='new-segment'").run();
    assert.equal(f.store.search({query:'记忆插件'}).long_term_matches,0);
    assert.throws(()=>f.store.retain({...base,title:'新记忆',evidence:[{...base.evidence[0],segment_id:'new-segment'}]}),/deleted/);
  } finally {f.close()}
});

test('real MCP stdio process implements initialization, schemas, errors and recovery',async()=>{
  const f=fixture();
  const child=spawn(process.execPath,[fileURLToPath(new URL('./server.mjs',import.meta.url)),'--home',f.root],{stdio:['pipe','pipe','pipe']});
  const replies=new Map();let nextID=0;let stderr='';
  child.stderr.on('data',b=>{stderr+=b});
  const lines=createInterface({input:child.stdout});
  lines.on('line',line=>{const reply=JSON.parse(line);const waiting=replies.get(reply.id);if(waiting){replies.delete(reply.id);clearTimeout(waiting.timer);waiting.resolve(reply)}});
  const call=(method,params={})=>new Promise((resolve,reject)=>{
    const id=++nextID;const timer=setTimeout(()=>reject(new Error(`MCP timeout; ${stderr}`)),5000);
    replies.set(id,{resolve,timer});child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');
  });
  try {
    assert.equal((await call('initialize',{protocolVersion:'2025-06-18'})).result.serverInfo.name,'agentone-memory');
    assert.equal((await call('tools/list')).result.tools.length,11);
    const invalid=await call('tools/call',{name:'search_memory',arguments:{limit:1.5}});
    assert.equal(invalid.error.code,-32602);
    const injected=await call('tools/call',{name:'submit_memory_analysis',arguments:{job_id:'x',lease_token:'x',source_sha256:f.sha,result:{analysis:{...analyze().analysis,extra:'not allowed'}}}});
    assert.equal(injected.error.code,-32602);
    const result=await call('tools/call',{name:'search_memory',arguments:{}});
    assert.equal(result.result.structuredContent.total_matches,2);
    const raw=await call('resources/read',{uri:'agentone://audio/old-segment'});
    assert.match(raw.error.message,/disabled/);
    child.stdin.write('{not JSON}\n');
    assert.deepEqual((await call('ping')).result,{});
    assert.equal((await call('unknown')).error.code,-32601);
  } finally {lines.close();child.kill();f.close()}
});

test('two actual MCP processes racing for the same queue never receive the same lease',async()=>{
  const f=fixture();
  const server=fileURLToPath(new URL('./server.mjs',import.meta.url));
  const a=new MCPClient(server,f.root),b=new MCPClient(server,f.root);
  try {
    await Promise.all([a.initialize(),b.initialize()]);
    const results=await Promise.all([a.call('claim_analysis_jobs',{owner:'A',stage:'transcribe',limit:3}),b.call('claim_analysis_jobs',{owner:'B',stage:'transcribe',limit:3})]);
    const ids=results.flatMap(r=>r.jobs.map(j=>j.job_id));
    assert.equal(ids.length,2);assert.equal(new Set(ids).size,2);
  } finally {await Promise.all([a.close(),b.close()]);f.close()}
});

test('v1 upgrade retains audio, transcript, jobs and foreign keys while allowing one mixed source',()=>{
 const root=mkdtempSync(join(tmpdir(),'agentone-v1-'));
 try {
  const old=new DatabaseSync(join(root,'memory.sqlite'));
  const schema=readFileSync(new URL('./schema.sql',import.meta.url),'utf8').replace("('schema_version', '2')","('schema_version', '1')").replace("'mixed','system_audio'","'system_audio'");
  old.exec(schema);
  old.exec("INSERT INTO segments VALUES ('old','session','microphone',1,1000,'UTC',1,1,'host_clock',48000,1,'Audio/old.m4a','hash','sealed',NULL,'{}',1); INSERT INTO transcripts VALUES ('old',1,'legacy evidence','[]','succeeded','fixture',1); INSERT INTO jobs (id,segment_id,stage,source_hash,state,created_ms,updated_ms) VALUES ('job','old','analyze','hash','pending',1,1)");old.close();
  const store=new MemoryStore(root);
  assert.equal(store.db.prepare("SELECT value FROM meta WHERE key='schema_version'").get().value,'2');
  assert.equal(store.db.prepare("SELECT source FROM segments WHERE id='old'").get().source,'microphone');
  assert.equal(store.db.prepare("SELECT text FROM transcripts WHERE segment_id='old'").get().text,'legacy evidence');
  assert.equal(store.db.prepare('SELECT COUNT(*) n FROM jobs').get().n,1);
  assert.deepEqual(store.db.prepare('PRAGMA foreign_key_check').all(),[]);
  assert.equal(store.db.prepare('PRAGMA foreign_keys').get().foreign_keys,1);
  store.db.exec("INSERT INTO segments VALUES ('new','session','mixed',1000,2000,'UTC',1,1,'host_clock',48000,1,'Audio/new.m4a','newhash','sealed',NULL,'{}',1)");
  assert.equal(store.search({source:'mixed'}).results.length,1);store.close();
 }finally{rmSync(root,{recursive:true,force:true})}
});

test('failed v1 relationship validation rolls the schema upgrade back instead of committing partial data',()=>{
 const root=mkdtempSync(join(tmpdir(),'agentone-invalid-v1-'));
 try {
  const old=new DatabaseSync(join(root,'memory.sqlite'));
  old.exec(readFileSync(new URL('./schema.sql',import.meta.url),'utf8').replace("('schema_version', '2')","('schema_version', '1')").replace("'mixed','system_audio'","'system_audio'"));
  old.exec("PRAGMA foreign_keys=OFF; INSERT INTO transcripts VALUES ('missing',1,'orphan','[]','succeeded','fixture',1)");old.close();
  assert.throws(()=>new MemoryStore(root),/CHECK constraint/);
  const unchanged=new DatabaseSync(join(root,'memory.sqlite'));
  assert.equal(unchanged.prepare("SELECT value FROM meta WHERE key='schema_version'").get().value,'1');
  assert.equal(unchanged.prepare('SELECT COUNT(*) n FROM transcripts').get().n,1);
  assert.ok(!unchanged.prepare("SELECT sql FROM sqlite_master WHERE name='segments'").get().sql.includes("'mixed'"));
  unchanged.close();
 }finally{rmSync(root,{recursive:true,force:true})}
});

test('real host handshake is visible while native self-check never pretends to connect an Agent',async()=>{
  const f=fixture();const server=fileURLToPath(new URL('./server.mjs',import.meta.url));const client=new MCPClient(server,f.root);
  try {
    const before=Date.now();
    await client.request('initialize',{protocolVersion:'2025-06-18',clientInfo:{name:'example\n-agent',version:'1.0'}});
    const first=JSON.parse(f.store.db.prepare("SELECT value FROM meta WHERE key='last_agent_connection'").get().value);
    assert.equal(first.name,'example-agent');assert.equal(first.transport,'stdio');assert.ok(first.connected_ms>=before && first.connected_ms<=Date.now());
    await client.request('initialize',{protocolVersion:'2025-06-18',clientInfo:{name:'agentone-connection-check',version:'1'}});
    const after=JSON.parse(f.store.db.prepare("SELECT value FROM meta WHERE key='last_agent_connection'").get().value);
    assert.deepEqual(after,first);
  } finally {await client.close();f.close()}
});

test('local preview labels remain qualified and measured place keeps its provenance',()=>{
  const f=fixture();
  try {
    const job=f.store.claim({owner:'fixture',stage:'transcribe',limit:1}).jobs[0];submit(f.store,job,transcription());
    const id=job.segment_id,preview={label:'工作讨论',status:'model_inference',source_sha256:f.sha,transcript_revision:1};
    f.store.db.prepare('INSERT INTO meta VALUES (?,?)').run(`local_label:${id}:1`,JSON.stringify(preview));
    f.store.db.prepare("UPDATE segments SET context_json='{\"place_source\":\"core_location\"}' WHERE id=?").run(id);
    const result=f.store.search({query:'工作讨论'}).results[0];
    assert.equal(result.segment_id,id);assert.equal(result.place.source,'core_location');assert.equal(result.local_label.status,'model_inference');
    assert.equal(f.store.evidence({segment_id:id}).local_label.label,'工作讨论');
    assert.equal(f.store.db.prepare("SELECT state FROM jobs WHERE segment_id=? AND stage='analyze'").get(id).state,'pending');
  }finally{f.close()}
});
