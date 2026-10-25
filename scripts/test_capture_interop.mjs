import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { MCPClient } from './mcp_client.mjs';

const root=process.argv[2];
assert.ok(root,'Pass the native synthetic audio harness directory');
const server=process.argv[3] ?? fileURLToPath(new URL('../plugins/agentone-memory/server.mjs',import.meta.url));
const client=new MCPClient(server,root);
try {
  await client.initialize();
  const status=await client.call('get_capture_status');
  assert.equal(status.capture.state,'not_started');
  assert.deepEqual(status.tracks.map(x=>x.source).sort(),['mixed']);
  assert.equal(status.tracks.reduce((sum,x)=>sum+x.segments,0),2);
  const fixtures=await client.call('search_memory',{limit:30});
  assert.equal(fixtures.results.length,2);
  assert.ok(fixtures.results.every(row=>row.session_id==='synthetic-mixed' && row.context.synthetic===true),'Interop harness must never run against real personal recordings');
  let transcribed=0;
  while(true) {
    const {jobs}=await client.call('claim_analysis_jobs',{owner:'synthetic-interop',stage:'transcribe',limit:3});
    if(!jobs.length) break;
    for(const job of jobs) {
      // The actual bytes are native AAC tones. This synthetic transcript tests
      // transport/queue persistence, not speech or model quality.
      const text='合成测试原型';
      await client.call('submit_memory_analysis',{job_id:job.job_id,lease_token:job.lease_token,source_sha256:job.source_sha256,
        result:{transcription:{text,engine:'synthetic-protocol-fixture-not-ASR',status:'succeeded',utterances:[{start_ms:0,end_ms:Math.min(500,job.duration_ms),text,speaker_local_id:null}]}}});
      transcribed++;
    }
  }
  assert.equal(transcribed,2);
  const {jobs}=await client.call('claim_analysis_jobs',{owner:'synthetic-interop',stage:'analyze',limit:3});
  const job=jobs[0];assert.ok(job.transcript);
  await client.call('submit_memory_analysis',{job_id:job.job_id,lease_token:job.lease_token,source_sha256:job.source_sha256,
    result:{analysis:{summary:'合成协议测试',tags:['合成测试'],claims:[{kind:'hypothesis',text:'合成原型测试',quote:'合成测试原型',start_ms:0,end_ms:500,certainty:'model_inference',owner:null,due_at:null}]}}});
  const found=await client.call('search_memory',{query:'原型'});
  assert.equal(found.total_matches,2);
  const evidence=await client.call('get_memory_evidence',{segment_id:job.segment_id});
  assert.equal(evidence.transcript.utterances[0].text,'合成测试原型');
  assert.equal(evidence.analyses[0].claims[0].source_sha256,job.source_sha256);
  const retained=await client.call('retain_memory',{kind:'open_loop',title:'合成协议长期记忆',text:'合成协议测试使用原型线索。',entities:['合成测试'],epistemic_status:'model_inference',valid_from:null,valid_until:null,supersedes:[],
    evidence:[{segment_id:job.segment_id,source_sha256:job.source_sha256,transcript_revision:1,start_ms:0,end_ms:500,quote:'合成测试原型'}]});
  assert.ok(retained.memory_id);
  assert.equal((await client.call('search_memory',{query:'长期记忆'})).long_term_matches,1);
  console.log('Native AAC → shared SQLite → real MCP subprocess → leased fixture transcription → sourced labels → historical lookup passed. No device recording, real ASR or model call was performed.');
} finally {await client.close()}
