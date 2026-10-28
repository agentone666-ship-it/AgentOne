import assert from 'node:assert/strict';import{resolve}from'node:path';import{MCPClient}from'./mcp_client.mjs';
const root=resolve(process.argv[2]);const c=new MCPClient(resolve('plugins/agentone-memory/server.mjs'),root);
try{
 await c.initialize();const tools=(await c.request('tools/list')).tools.map(t=>t.name);assert.ok(tools.includes('list_conversations'));assert.ok(tools.includes('get_conversation_evidence'));assert.ok(!tools.includes('submit_conversation_summary'));
 const list=await c.call('list_conversations');assert.equal(list.total,1);const id=list.conversations[0].conversation_id;
 const evidence=await c.call('get_conversation_evidence',{conversation_id:id,limit:1});assert.equal(evidence.total_segments,2);assert.equal(evidence.next_offset,1);assert.equal(evidence.missing_audio_ms,0);
 const rest=await c.call('get_conversation_evidence',{conversation_id:id,offset:1,limit:1});assert.equal(rest.recordings.length,1);assert.match(rest.recordings[0].transcript.utterances[0].text,/只是提议/);
 console.log('Native real AAC → whole conversation → continuous playable M4A → paginated MCP evidence passed. Fixture transcripts are synthetic, not ASR or a live discussion. No product summary model/queue was introduced.');
}finally{await c.close()}
